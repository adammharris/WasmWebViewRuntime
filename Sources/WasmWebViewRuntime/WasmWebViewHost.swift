import Foundation
import WasmRuntimeCore
import WebKit

/// The web view the JIT backend runs inside, and everything needed to get a
/// program's bytes in and its results out.
///
/// One web view serves every run. Guests are isolated from each other by being
/// in separate workers, which also means a pipeline's stages are genuinely
/// concurrent here — the same property `WasmConcurrencyTests` pins for the
/// interpreter.
///
/// Three channels cross the boundary, and which one carries what is the whole
/// design:
///
/// - **Bulk, host to guest** goes over a `WKURLSchemeHandler`. Modules and
///   directory snapshots are megabytes, and a scheme handler moves raw bytes
///   where `evaluateJavaScript` would need them base64'd into a JavaScript
///   string literal.
/// - **Blocking, guest to host** goes over the same scheme handler, hit by a
///   *synchronous* `XMLHttpRequest` from the worker. This is what makes WASI's
///   synchronous `fd_read` work without `SharedArrayBuffer`, which a WKWebView
///   cannot have. See `wish-worker.js`.
/// - **Everything else** is `WKScriptMessageHandler` — output, exit status, and
///   the filesystem diff, base64'd because a script message body is JSON.
@MainActor
public final class WasmWebViewHost: NSObject {
    /// The scheme the runtime page and all its traffic live on. Must not be a
    /// scheme WebKit already knows, and the page itself has to be loaded from
    /// it — a document on `file://` cannot fetch from a custom scheme.
    private static let scheme = "wish-wasm"
    private static let origin = "wish-wasm://runtime"

    /// The view has to be in the view hierarchy.
    ///
    /// iOS 16 and later terminate the web content process of a `WKWebView`
    /// that is not in a window, and throttle JavaScript in one that is not
    /// visible. Hidden-but-attached is the arrangement that survives; see
    /// `WasmWebViewCanvas` for the zero-sized view that does the attaching.
    public private(set) lazy var view: WKWebView = makeWebView()

    /// Nothing to configure. Every knob this backend has is per-run and
    /// arrives on the `WasmProgram`.
    override public init() {
        super.init()
    }

    private var runs: [String: RunState] = [:]
    private var activeTasks: Set<ObjectIdentifier> = []
    private var nextRun = 0

    /// Requests being answered from off the main actor, held here because a
    /// `WKURLSchemeTask` cannot cross an isolation boundary.
    private var deferred: [Int: any WKURLSchemeTask] = [:]
    private var nextTicket = 0

    private enum Readiness {
        case idle
        case loading([CheckedContinuation<Void, any Error>])
        case ready
    }

    private var readiness = Readiness.idle

    /// Phase timings from the most recent run, for benchmarks to report.
    ///
    /// Diagnostic only — nothing reads this to make a decision, and with
    /// concurrent runs "most recent" means whichever finished last. Locked
    /// rather than `nonisolated(unsafe)` because a torn dictionary is a crash
    /// and a benchmark is not worth one.
    public nonisolated static let lastTiming = TimingBox()

    /// What the page reported it can do. Recorded rather than assumed — the
    /// interesting entries are all expected to be false today and are the
    /// signal to take a faster path if a future OS turns one on.
    public private(set) var capabilities: [String: Bool] = [:]

    // MARK: - Running

    public func run(_ program: WasmProgram, stdio: WasmStdio) async throws -> Int32 {
        try await ensureReady()

        let moduleData = try Self.moduleData(at: program.moduleURL)
        let preopens = WasmPreopen.all(for: program)

        nextRun += 1
        let id = "r\(nextRun)"
        let state = RunState(
            preopens: preopens,
            overlay: program.overlay,
            moduleData: moduleData,
            onOutput: stdio.onOutput
        )
        runs[id] = state

        // Bytes are appended off the main actor and handed over on it. The
        // wake-up only crosses back when the guest is actually parked in a
        // read, which for a program that never touches stdin is never.
        let pump = Task.detached { [weak self] in
            for await byte in stdio.input {
                if state.stdin.append(byte) {
                    await self?.deliverStdin(to: id)
                }
            }
            if state.stdin.finish() {
                await self?.deliverStdin(to: id)
            }
        }

        defer {
            pump.cancel()
            runs[id] = nil
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.continuation = continuation
                start(id: id, program: program, preopens: preopens, stdio: stdio)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id) }
        }
    }

    private func start(
        id: String, program: WasmProgram, preopens: [WasmPreopen], stdio: WasmStdio
    ) {
        let spec: [String: Any] = [
            "run": id,
            "moduleURL": "\(Self.origin)/run/\(id)/module",
            "moduleSignature": Self.signature(of: program.moduleURL),
            "syncURL": "\(Self.origin)/run/\(id)",
            "argv0": program.argv0,
            "arguments": program.arguments,
            "environment": Self.environment,
            // fd 0, 1, 2. The guest asks `isatty` about each separately, and
            // the answers genuinely differ: `python | cat` has a terminal on
            // stdin and a pipe on stdout.
            "tty": [stdio.stdinIsTerminal, stdio.stdoutIsTerminal, stdio.stderrIsTerminal],
            "preopens": preopens.enumerated().map { index, preopen in
                [
                    "index": index,
                    "guestPath": preopen.guestPath,
                    "readOnly": preopen.readOnly,
                    // A read-only mount is cached in the page under this key,
                    // which is what keeps an 18 MB standard library a
                    // once-per-install cost instead of a once-per-command one.
                    "signature": preopen.readOnly
                        ? WasmSnapshot.signature(of: preopen.hostURL) : "",
                    "url": "\(Self.origin)/run/\(id)/preopen/\(index)",
                ]
            },
        ]

        guard let json = try? JSONSerialization.data(withJSONObject: spec),
              let text = String(data: json, encoding: .utf8)
        else {
            finish(id, with: .failure(WasmRuntimeError.trapped("could not encode the run")))
            return
        }

        // `start` is async, and a promise is not something `evaluateJavaScript`
        // can hand back — it fails the whole call with "unsupported type"
        // rather than ignoring the value. The trailing `void 0` is what makes
        // this fire-and-forget; the run reports itself through the message
        // handler, not through here.
        view.evaluateJavaScript("WishWasm.start(\(text)); void 0;") { [weak self] _, error in
            guard let error else { return }
            MainActor.assumeIsolated {
                self?.finish(
                    id,
                    with: .failure(
                        WasmRuntimeError.trapped("web view refused the run: \(error)")))
            }
        }
    }

    private func cancel(_ id: String) {
        guard runs[id] != nil else { return }
        view.evaluateJavaScript("WishWasm.cancel('\(id)'); void 0;")
        finish(id, with: .failure(CancellationError()))
    }

    private func finish(_ id: String, with result: Result<Int32, any Error>) {
        guard let state = runs.removeValue(forKey: id) else { return }
        state.resume(result)
    }

    // MARK: - stdin

    /// Hands over whatever has arrived to a guest parked in a read.
    ///
    /// Only ever called when `StdinBuffer` says someone is waiting, and the
    /// pairing of `take` with storing the task happens without an intervening
    /// suspension — so a byte arriving between the two cannot be dropped.
    private func deliverStdin(to id: String) {
        guard let state = runs[id], let task = state.pendingStdin else { return }
        guard let data = state.stdin.take() else { return }
        state.pendingStdin = nil
        respond(to: task, data: data, mimeType: "application/octet-stream")
    }

    // MARK: - Lifecycle

    private func ensureReady() async throws {
        switch readiness {
        case .ready:
            return

        case .loading:
            try await withCheckedThrowingContinuation { continuation in
                guard case var .loading(waiters) = readiness else {
                    continuation.resume()
                    return
                }
                waiters.append(continuation)
                readiness = .loading(waiters)
            }

        case .idle:
            readiness = .loading([])
            _ = view
            guard Self.resource("wish-runtime", "html") != nil,
                  let page = URL(string: "\(Self.origin)/index.html")
            else {
                readiness = .idle
                throw WasmRuntimeError.trapped("the web view runtime is missing from the bundle")
            }
            // Loaded through the scheme handler rather than from the bundle's
            // `file://` URL, even though the bytes are identical. A document's
            // own scheme is what decides whether it may fetch from a custom
            // one, so a page on `file://` cannot reach a single thing this
            // backend serves — the module, the worker, or any snapshot.
            view.load(URLRequest(url: page))

            // A web content process that dies during load leaves nothing to
            // report it, so the wait is bounded rather than open-ended.
            let timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                self?.failReadiness(
                    WasmRuntimeError.trapped("the web view runtime did not start"))
            }
            defer { timeout.cancel() }

            try await withCheckedThrowingContinuation { continuation in
                guard case var .loading(waiters) = readiness else {
                    continuation.resume()
                    return
                }
                waiters.append(continuation)
                readiness = .loading(waiters)
            }
        }
    }

    private func becameReady() {
        guard case let .loading(waiters) = readiness else { return }
        readiness = .ready
        for waiter in waiters { waiter.resume() }
    }

    private func failReadiness(_ error: any Error) {
        guard case let .loading(waiters) = readiness else { return }
        readiness = .idle
        for waiter in waiters { waiter.resume(throwing: error) }
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(self, forURLScheme: Self.scheme)
        configuration.userContentController.add(self, name: "wish")
        // Nothing here is a document the user reads, and a run that outlives
        // the app's foreground is a run that was going to be killed anyway.
        configuration.suppressesIncrementalRendering = true

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.isUserInteractionEnabled = false
        view.isOpaque = false
        view.backgroundColor = .clear
        // Deliberately not `isHidden`: see `WasmWebViewCanvas`.
        return view
    }

    /// The page and the worker, out of the package's own resource bundle.
    ///
    /// `Bundle(for:)` used to be enough, when these were app resources sitting
    /// at the top of the app bundle. A SwiftPM target's resources are not
    /// there: they are in a nested `.bundle` that only `Bundle.module` knows
    /// how to find, and `Package.swift` declares them with `copy`, which puts
    /// the directory in unflattened — hence the subdirectory. See the manifest
    /// for why that directory is not called `Resources`.
    private static func resource(_ name: String, _ extension: String) -> URL? {
        Bundle.module.url(
            forResource: name, withExtension: `extension`, subdirectory: "Runtime")
    }

    private static func moduleData(at url: URL) throws -> Data {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw WasmRuntimeError.notAModule(url)
        }
        guard data.count >= 4, Array(data.prefix(4)) == [0x00, 0x61, 0x73, 0x6D] else {
            throw WasmRuntimeError.notAModule(url)
        }
        return data
    }

    /// Identity of a file on disk, for the page's compiled-module cache. Same
    /// size-and-mtime bet `ModuleCache` makes on the interpreter side.
    private static func signature(of url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        var hasher = Hasher()
        hasher.combine(url.path)
        hasher.combine(values?.fileSize ?? -1)
        hasher.combine(values?.contentModificationDate ?? .distantPast)
        return String(UInt(bitPattern: hasher.finalize()), radix: 36)
    }

    /// Matches the interpreter backend's environment exactly. A guest that
    /// behaves differently between backends because of `$TERM` would be a bug
    /// nobody would think to look for here — `WasmBackendParityTests` is what
    /// keeps the two lists honest now that they are in different modules.
    private static let environment: [String: String] = [
        "HOME": "/",
        "PWD": "/",
        "PATH": "/",
        "TERM": "xterm-ghostty",
        "TERM_PROGRAM": "Wish",
        "LANG": "en_US.UTF-8",
    ]
}

// MARK: - Serving the runtime and its payloads

/// The delegate methods below are `public` only because Swift requires it of a
/// public class satisfying a public Objective-C protocol. They are WebKit's to
/// call and nobody else's — being able to see them from outside the module is
/// an artefact of the language rule, not an invitation.
extension WasmWebViewHost: WKURLSchemeHandler {
    public func webView(_: WKWebView, start task: any WKURLSchemeTask) {
        activeTasks.insert(ObjectIdentifier(task))
        let path = task.request.url?.path ?? ""
        let components = path.split(separator: "/").map(String.init)

        switch components.first {
        case "index.html", nil:
            serveResource("wish-runtime", "html", "text/html", to: task)

        case "worker.js":
            serveResource("wish-worker", "js", "text/javascript", to: task)

        case "run":
            serveRun(components: components, query: task.request.url?.query, to: task)

        default:
            fail(task, WasmRuntimeError.trapped("no such runtime resource: \(path)"))
        }
    }

    public func webView(_: WKWebView, stop task: any WKURLSchemeTask) {
        activeTasks.remove(ObjectIdentifier(task))
        for state in runs.values where state.pendingStdin === task {
            state.pendingStdin = nil
        }
        deferred = deferred.filter { $0.value !== task }
    }

    private func serveResource(
        _ name: String, _ extension: String, _ mimeType: String, to task: any WKURLSchemeTask
    ) {
        guard let url = Self.resource(name, `extension`),
              let data = try? Data(contentsOf: url)
        else {
            fail(task, WasmRuntimeError.trapped("\(name).\(`extension`) is missing from the bundle"))
            return
        }
        respond(to: task, data: data, mimeType: mimeType)
    }

    /// `/run/<id>/module`, `/preopen/<n>`, `/stdin`, and `/sleep`.
    private func serveRun(components: [String], query: String?, to task: any WKURLSchemeTask) {
        guard components.count >= 3, let state = runs[components[1]] else {
            fail(task, WasmRuntimeError.trapped("no such run"))
            return
        }
        let id = components[1]

        switch components[2] {
        case "module":
            respond(to: task, data: state.moduleData, mimeType: "application/wasm")

        case "preopen":
            guard let index = components.count > 3 ? Int(components[3]) : nil,
                  state.preopens.indices.contains(index)
            else {
                fail(task, WasmRuntimeError.trapped("no such preopen"))
                return
            }

            // `/preopen/<n>/file?path=…` is a body the snapshot left behind,
            // asked for by a guest that turned out to read it. Blocking, like
            // `/stdin`: a synchronous XHR is parked on the other end.
            if components.count > 4, components[4] == "file" {
                serveFile(in: state.preopens[index], query: query, to: task)
                return
            }
            // Packing walks and reads a whole directory tree, which is not
            // something to do on the main thread while a terminal is trying to
            // draw. The guest is blocked on this fetch either way.
            //
            // The task itself stays on the main actor and is reached again by
            // ticket: `WKURLSchemeTask` is not `Sendable`, and the compiler is
            // right that handing one to a detached task would be a race.
            let url = state.preopens[index].hostURL
            // The overlay belongs to the working directory, which is preopen 0.
            let overlay = index == 0 ? state.overlay : []
            let ticket = nextTicket
            nextTicket += 1
            deferred[ticket] = task
            Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    let data = try WasmSnapshot.pack(url, overlay: overlay)
                    await self?.completePack(ticket: ticket, run: id, data: data, failure: nil)
                } catch {
                    await self?.completePack(
                        ticket: ticket, run: id, data: nil,
                        failure: error.localizedDescription)
                }
            }

        case "stdin":
            // The one genuinely blocking endpoint: a synchronous XHR is parked
            // on the other end of it, which is what gives the guest a real
            // blocking `fd_read` without a `SharedArrayBuffer`.
            if let data = state.stdin.take() {
                respond(to: task, data: data, mimeType: "application/octet-stream")
            } else {
                state.pendingStdin = task
            }

        case "sleep":
            let nanos =
                query?
                    .split(separator: "&")
                    .first(where: { $0.hasPrefix("ns=") })
                    .flatMap { UInt64($0.dropFirst(3)) } ?? 0
            Task { [weak self] in
                try? await Task.sleep(for: .nanoseconds(min(nanos, 60_000_000_000)))
                self?.respond(to: task, data: Data(), mimeType: "application/octet-stream")
            }

        default:
            fail(task, WasmRuntimeError.trapped("no such run endpoint"))
        }
    }

    /// One file out of a preopen, for a guest reading a body the snapshot did
    /// not carry.
    ///
    /// The path was last touched by guest code, so it goes through `GuestPath`
    /// against the preopen root — the same component-array rule a write-back
    /// gets, and for the same reason: `../../bin/coreutils.wasm` has to name
    /// something inside the preopen or nothing at all. Nothing new is reachable
    /// either way, because the snapshot already told the guest this tree exists;
    /// what this endpoint decides is only whether the bytes arrive now or did
    /// earlier.
    private func serveFile(
        in preopen: WasmPreopen, query: String?, to task: any WKURLSchemeTask
    ) {
        let raw = query?
            .split(separator: "&")
            .first { $0.hasPrefix("path=") }
            .map { String($0.dropFirst("path=".count)) }
        guard let path = raw?.removingPercentEncoding else {
            fail(task, WasmRuntimeError.trapped("no such file in the preopen"))
            return
        }
        let components = GuestPath.components(of: path, relativeTo: [], home: [])
        guard !components.isEmpty else {
            fail(task, WasmRuntimeError.trapped("no such file in the preopen"))
            return
        }
        let url = GuestPath.url(for: components, root: preopen.hostURL)

        // Off the main actor for the same reason packing is: this is file IO
        // proportional to what the guest asked for, and the terminal is still
        // drawing. The guest is blocked on the request either way.
        let ticket = nextTicket
        nextTicket += 1
        deferred[ticket] = task
        Task.detached(priority: .userInitiated) { [weak self] in
            let data = try? Data(contentsOf: url, options: .mappedIfSafe)
            await self?.completeFile(ticket: ticket, data: data, path: path)
        }
    }

    /// Answers the parked request. A file that cannot be read fails the request
    /// rather than the run — the guest turns that into an IO error on the read,
    /// which is what a guest asking for a file that went away should see.
    private func completeFile(ticket: Int, data: Data?, path: String) {
        guard let task = deferred.removeValue(forKey: ticket) else { return }
        if let data {
            respond(to: task, data: data, mimeType: "application/octet-stream")
        } else {
            fail(task, WasmRuntimeError.trapped("could not read \(path)"))
        }
    }

    private func completePack(ticket: Int, run: String, data: Data?, failure: String?) {
        guard let task = deferred.removeValue(forKey: ticket) else { return }
        if let data {
            respond(to: task, data: data, mimeType: "application/octet-stream")
        } else {
            let error = WasmRuntimeError.trapped(failure ?? "could not read the directory")
            fail(task, error)
            // The guest is stuck on a fetch that will never arrive, so the run
            // has to be ended from here rather than waited out.
            finish(run, with: .failure(error))
        }
    }

    /// Every reply funnels through here because a `WKURLSchemeTask` that has
    /// already been stopped raises an Objective-C exception when written to,
    /// and an exception through Swift frames is not catchable — it is a crash.
    fileprivate func respond(to task: any WKURLSchemeTask, data: Data, mimeType: String) {
        guard activeTasks.remove(ObjectIdentifier(task)) != nil else { return }
        let response = HTTPURLResponse(
            url: task.request.url ?? URL(string: Self.origin)!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": mimeType,
                "Content-Length": String(data.count),
                "Cache-Control": "no-store",
                // Permissive on purpose. The obvious thing to send here is
                // COOP `same-origin` plus COEP `require-corp`, which is what
                // buys `SharedArrayBuffer` — except WebKit does not apply
                // those to a document loaded through a scheme handler, so the
                // page never becomes cross-origin isolated and the only thing
                // COEP achieves is to reject every subresource this page
                // loads: a document served from a custom scheme has an origin
                // that `same-origin` CORP does not match, so the module, the
                // worker, and every snapshot fail with "Load failed".
                //
                // Blocking reads go through a synchronous XHR instead, so
                // there is nothing left to gain by asking. See `wish-worker.js`.
                "Cross-Origin-Resource-Policy": "cross-origin",
            ]
        )!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private func fail(_ task: any WKURLSchemeTask, _ error: any Error) {
        guard activeTasks.remove(ObjectIdentifier(task)) != nil else { return }
        task.didFailWithError(error)
    }
}

// MARK: - Messages from the page

extension WasmWebViewHost: WKScriptMessageHandler {
    public func userContentController(
        _: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String
        else { return }

        if type == "ready" {
            capabilities = body.compactMapValues { $0 as? Bool }
            WasmLog.runtime.debug(
                "wasm web view ready capabilities=\(self.capabilities)")
            becameReady()
            return
        }

        guard let id = body["run"] as? String, let state = runs[id] else { return }

        switch type {
        case "output":
            guard let text = body["data"] as? String,
                  let data = Data(base64Encoded: text)
            else { return }
            state.onOutput(data)

        case "diff":
            // Timed because a 45 MB build cache crosses as base64 in 4 MB
            // chunks, and "the diff is cheap to compute" says nothing about
            // what it costs to carry.
            let began = ContinuousClock.now
            if let text = body["data"] as? String, let data = Data(base64Encoded: text) {
                state.diff.append(data)
            }
            state.transferNanos += (ContinuousClock.now - began).nanoseconds

        case "exit":
            let status = Int32(body["status"] as? Int ?? 0)
            Self.lastTiming.set("transfer", Int(state.transferNanos / 1_000_000))
            Self.lastTiming.set("diffMB", state.diff.count >> 20)
            if let timing = body["timing"] as? [String: Any] {
                // The whole cost of this backend is moving bytes rather than
                // running them, so where a run spent its time is the number
                // that decides what to optimise next.
                let parts = timing.keys.sorted().map { "\($0)=\(timing[$0] ?? "")" }
                WasmLog.runtime.debug("wasm run \(id) \(parts.joined(separator: " "))")
                Self.lastTiming.merge(timing.compactMapValues { $0 as? Int })
            }
            runs[id] = nil
            applyDiff(state, status: status)

        case "failed":
            let message = body["message"] as? String ?? "unknown failure"
            finish(id, with: .failure(WasmRuntimeError.trapped(message)))

        default:
            break
        }
    }

    /// Replays the guest's writes onto the sandbox, then reports the exit.
    ///
    /// Off the main actor because it is file IO proportional to what the guest
    /// produced, and the run is over — nothing is waiting on the main thread
    /// except the terminal, which should stay responsive while a build's output
    /// lands.
    private func applyDiff(_ state: RunState, status: Int32) {
        let diff = state.diff
        let preopens = state.preopens
        let overlay = Set(state.overlay.map(\.guestPath))
        let onOutput = state.onOutput

        Task.detached(priority: .userInitiated) {
            if !diff.isEmpty {
                do {
                    let began = ContinuousClock.now
                    let parsed = try WasmWriteback.parse(diff)
                    let problems = WasmWriteback.apply(
                        parsed, to: preopens, overlay: overlay)
                    Self.lastTiming.set(
                        "write", Int((ContinuousClock.now - began).nanoseconds / 1_000_000))
                    // Loud, because a command that reported success while
                    // silently failing to write its output is the worst
                    // possible outcome for a backend whose whole job is
                    // moving files.
                    for problem in problems.prefix(10) {
                        onOutput(Data("wish: could not write back \(problem)\r\n".utf8))
                    }
                } catch {
                    onOutput(
                        Data("wish: \(error.localizedDescription)\r\n".utf8))
                }
            }
            state.resume(.success(status))
        }
    }
}

// MARK: - Process lifetime

extension WasmWebViewHost: WKNavigationDelegate {
    /// The web content process is jetsammed on its own budget, separate from
    /// the app's. A guest that asked for more memory than iOS would give it
    /// takes the page down with it, and every run has to be told.
    public func webViewWebContentProcessDidTerminate(_: WKWebView) {
        let error = WasmRuntimeError.trapped(
            "the web view ran out of memory — try the interpreter backend")
        // `Array` because `finish` removes from `runs`, and mutating a
        // dictionary while walking its keys view is not a thing to do.
        for id in Array(runs.keys) { finish(id, with: .failure(error)) }
        // `failReadiness` is what returns to `.idle`, and it only resumes
        // waiters while still `.loading` — setting it here first would strand
        // anyone waiting on a load that died mid-flight.
        failReadiness(error)
        // The view survives its web content process; the next run loads the
        // page again and WebKit relaunches.
        deferred.removeAll()
    }

    public func webView(_: WKWebView, didFail _: WKNavigation!, withError error: any Error) {
        failReadiness(error)
    }

    public func webView(
        _: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: any Error
    ) {
        failReadiness(error)
    }
}

// MARK: - Per-run state

/// Bookkeeping for one guest. Main-actor-isolated apart from `stdin`, which is
/// written by the pump task and read by the scheme handler.
@MainActor
private final class RunState {
    let preopens: [WasmPreopen]
    let overlay: [WasmOverlay]
    let moduleData: Data
    let onOutput: @Sendable (Data) -> Void
    let stdin = StdinBuffer()

    var diff = Data()
    /// How long the diff took to cross, base64 and all.
    var transferNanos: Int64 = 0
    var pendingStdin: (any WKURLSchemeTask)?
    var continuation: CheckedContinuation<Int32, any Error>?

    init(
        preopens: [WasmPreopen],
        overlay: [WasmOverlay],
        moduleData: Data,
        onOutput: @escaping @Sendable (Data) -> Void
    ) {
        self.preopens = preopens
        self.overlay = overlay
        self.moduleData = moduleData
        self.onOutput = onOutput
    }

    /// Resumes exactly once. A run can be finished by its exit message, by
    /// cancellation, and by the web process dying, and two of those racing is
    /// normal rather than exceptional.
    nonisolated func resume(_ result: Result<Int32, any Error>) {
        Task { @MainActor in
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(with: result)
        }
    }
}

/// Bytes on their way to a guest, and whether anyone is waiting for them.
///
/// The handoff has one rule: `take` returning nil marks a waiter, and the
/// caller must store the parked request before it suspends. Both happen inside
/// one main-actor step, so a byte arriving in between cannot find an empty
/// mailbox and go back to sleep.
private final class StdinBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var finished = false
    private var waiting = false

    /// Whatever has arrived; empty for end-of-input; nil to park.
    func take() -> Data? {
        lock.withLock {
            if !data.isEmpty {
                defer { data = Data() }
                waiting = false
                return data
            }
            if finished { return Data() }
            waiting = true
            return nil
        }
    }

    /// Returns whether a parked reader should be woken.
    func append(_ byte: UInt8) -> Bool {
        lock.withLock {
            data.append(byte)
            defer { waiting = false }
            return waiting
        }
    }

    func finish() -> Bool {
        lock.withLock {
            finished = true
            defer { waiting = false }
            return waiting
        }
    }
}

extension Duration {
    /// Whole nanoseconds, for the millisecond arithmetic the timings do.
    fileprivate var nanoseconds: Int64 {
        Int64(components.seconds) * 1_000_000_000
            + Int64(components.attoseconds / 1_000_000_000)
    }
}


/// Phase timings, readable from a test on whatever thread it happens to be on.
public final class TimingBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Int] = [:]

    public var values: [String: Int] { lock.withLock { storage } }

    func set(_ key: String, _ value: Int) {
        lock.withLock { storage[key] = value }
    }

    func merge(_ other: [String: Int]) {
        lock.withLock { storage.merge(other) { _, new in new } }
    }
}
