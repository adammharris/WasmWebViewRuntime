import Foundation

/// Which engine a wasm guest runs on.
///
/// These were once presented as an even trade — an interpreter pays per
/// instruction and nothing per syscall, a JIT behind a process boundary pays
/// the reverse — with the guess that syscall-heavy tools would prefer the
/// interpreter. Measurement did not support it. Copying a 46 MB preopen into
/// the web view costs 58 ms against 858 ms of guest execution; for the transfer
/// to be the deciding cost, the JIT would have to finish in single-digit
/// milliseconds, which is a program that touches an enormous tree and computes
/// nothing. No real package is shaped like that.
///
/// What separates them in practice is less flattering to the interpreter:
///
/// - It runs in this process, so a trap in a host call takes the application
///   down with it rather than a tab.
/// - It implements `wasi_snapshot_preview1` only, so a module built against
///   `wasi_unstable` — anything compiled with wasienv, including Lua — cannot
///   even instantiate.
/// - It cannot JIT and never will here: iOS denies this process the right to
///   mark memory executable, which is the entire reason the web view backend
///   exists.
///
/// It is kept because it is the only engine that runs without a view in the
/// hierarchy, which the installer's `--list` probe and the test suite both
/// need, and because a pure-Swift interpreter is steppable when something is
/// wrong. Those are development properties, not a performance choice.
public enum WasmBackend: String, Codable, CaseIterable, Identifiable, Sendable {
    /// A pure-Swift interpreter, in this process. Wish's is WasmKit; the
    /// package does not ship one, it only names the choice.
    case interpreter

    /// `WebKitWasmRuntime` — WebKit's wasm JIT, in the WebContent process.
    case webView = "webview"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .interpreter: "Interpreter"
        case .webView: "Web View (JIT)"
        }
    }

    /// One line under the picker.
    ///
    /// This used to describe a trade — cheap syscalls against fast compute —
    /// and sent people to the interpreter for file-heavy work on the strength
    /// of it. The measurement says that case is not reachable, and the
    /// interpreter's real distinguishing properties are that some modules will
    /// not load on it and a misbehaving one can end the app. Saying "cheap per
    /// syscall" invited users to pick it for a benefit they cannot observe and
    /// costs they can.
    public var summary: String {
        switch self {
        case .interpreter:
            "Runs in-process, for debugging. Slower on compute, cannot load "
                + "modules built against older WASI, and a misbehaving guest "
                + "can take the app down with it."
        case .webView:
            "Runs on WebKit's JIT, in its own process. Faster, and a guest "
                + "that misbehaves cannot bring the app down."
        }
    }
}

/// The selected backend, readable from any isolation domain.
///
/// A box rather than a property on whatever owns the settings UI, because a
/// wasm guest can be started from any task — a pipeline stage runs off the main
/// actor — and a settings screen is `@MainActor`. This is the part the shell
/// reads; the sheet is the part that writes it, and the two never meet.
public final class WasmBackendPreference: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: WasmBackend
    private let defaults: UserDefaults?

    private static let key = "wasm.backend"

    /// Defaults to the web view. The interpreter cannot run Lua at all, ends
    /// the process on an interactive guest that polls, and is an order of
    /// magnitude slower on anything that computes — a default nobody would
    /// choose knowing that. Only fresh installs are affected: a stored choice
    /// still wins.
    public init(_ initial: WasmBackend = .webView, defaults: UserDefaults? = nil) {
        storage = defaults
            .flatMap { $0.string(forKey: Self.key) }
            .flatMap(WasmBackend.init(rawValue:)) ?? initial
        self.defaults = defaults
    }

    public var current: WasmBackend {
        get { lock.withLock { storage } }
        set {
            lock.withLock { storage = newValue }
            defaults?.set(newValue.rawValue, forKey: Self.key)
        }
    }
}

/// Routes each run to whichever backend is selected right now.
///
/// The selection is read once, at the top of `run`, and not again. A command
/// already executing when the user changes the setting finishes on the engine
/// it started on — the alternative is a half-migrated guest, which is not a
/// thing that exists.
///
/// Both backends are constructed up front rather than on demand, which is only
/// reasonable because neither costs anything until it is used: WasmKit's is an
/// empty module cache, and `WebKitWasmRuntime` does not build its web view
/// until the first run.
public struct SelectedWasmRuntime: WasmRuntime {
    public let preference: WasmBackendPreference
    public let interpreter: any WasmRuntime
    public let webView: any WasmRuntime

    public init(
        preference: WasmBackendPreference,
        interpreter: any WasmRuntime,
        webView: any WasmRuntime
    ) {
        self.preference = preference
        self.interpreter = interpreter
        self.webView = webView
    }

    public func run(_ program: WasmProgram, stdio: WasmStdio) async throws -> Int32 {
        // A package that declares a backend overrules the setting rather than
        // failing against it. The declaration exists because the package does
        // not *work* otherwise — Lua cannot instantiate on the interpreter at
        // all — so honouring the preference here would mean honouring it into
        // a guaranteed error. The user's choice is about everything that has a
        // choice to make.
        switch program.requiredBackend ?? preference.current {
        case .interpreter:
            try await interpreter.run(program, stdio: stdio)
        case .webView:
            try await webView.run(program, stdio: stdio)
        }
    }
}
