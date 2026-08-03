import Foundation

/// A directory the guest sees in addition to its working directory.
///
/// Resolved to a real URL by the time it gets here — the `{pkg}`/`{state}`
/// tokens a package manifest is written in are a packaging concern and do not
/// survive into the runtime.
public struct WasmMount: Sendable {
    /// Absolute path inside the guest, e.g. `/lib`.
    public let guestPath: String
    public let hostURL: URL
    /// Advisory under an in-process interpreter, which hands the guest a real
    /// directory and lets WASI police it; enforced by the web view backend,
    /// which builds the tree itself and drops write-backs aimed at a read-only
    /// mount. The embedder decides what to mark — Wish reads it off a package
    /// manifest.
    public let readOnly: Bool

    public init(guestPath: String, hostURL: URL, readOnly: Bool) {
        self.guestPath = guestPath
        self.hostURL = hostURL
        self.readOnly = readOnly
    }
}

/// A package file the guest finds inside its working directory, and the host
/// never does.
///
/// The guest sees it, `ls` does not, and the write-back drops anything aimed at
/// it. The reason it exists at all is that a mount can only be opened by name,
/// and some tools have to name a file on a command line, where paths resolve
/// against the working directory.
///
/// Only the web view backend can do this: it builds the guest's filesystem in
/// memory, so a file can be in it without being anywhere. An in-process
/// interpreter hands out a real directory and says so rather than pretending —
/// see `WasmRuntimeError.needsWebView`.
public struct WasmOverlay: Sendable {
    /// Relative to the working directory, e.g. `.wish/libcompiler_rt.a`.
    public let guestPath: String
    public let hostURL: URL

    public init(guestPath: String, hostURL: URL) {
        self.guestPath = guestPath
        self.hostURL = hostURL
    }
}

/// A WebAssembly program the shell can execute, already resolved to a file.
public struct WasmProgram: Sendable {
    /// The `.wasm` file to execute.
    public let moduleURL: URL

    /// What to pass as `argv[0]`.
    ///
    /// Multicall modules dispatch on this: one `coreutils.wasm` answers to
    /// `ls`, `cat`, and 72 other names depending on what lands here. uutils
    /// takes the basename and strips a `.wasm` suffix, so the name the user
    /// typed can be passed through verbatim.
    public let argv0: String

    /// Arguments after the command name.
    public let arguments: [String]

    /// The directory the guest sees as `/`.
    ///
    /// WASI preview 1 has no `chdir` and this build of wasi-libc ignores
    /// `PWD` — `pwd` inside the guest reports "operation not supported on
    /// this platform". Relative paths resolve against the single preopened
    /// directory, so the only way `cd` can mean anything to a wasm tool is to
    /// change which directory that is.
    public let root: URL

    /// Extra preopens, beyond the working directory.
    ///
    /// Always *in addition to* ``root``, never instead of it: the working
    /// directory stays the guest's `/` and stays first, which is both the
    /// containment rule and — because `std/Io/Dir.zig` hardcodes `Dir.cwd()`
    /// to file descriptor 3, the first preopen — the thing that makes a
    /// WASI-hosted Zig resolve relative paths against the right directory.
    public let mounts: [WasmMount]

    /// Files the guest finds in its working directory that are not on disk.
    public let overlay: [WasmOverlay]

    /// The engine this program must run on, whatever the user selected.
    ///
    /// For the cases where the choice is not a preference: a module built
    /// against `wasi_unstable` cannot instantiate on an interpreter that only
    /// implements `wasi_snapshot_preview1`, and a compiler on one is slow
    /// enough to read as broken. `nil` means the setting decides, which is the
    /// normal case and stays the normal case. Wish sets it from a package's own
    /// manifest.
    public let requiredBackend: WasmBackend?

    public init(
        moduleURL: URL,
        argv0: String,
        arguments: [String],
        root: URL,
        mounts: [WasmMount] = [],
        overlay: [WasmOverlay] = [],
        requiredBackend: WasmBackend? = nil
    ) {
        self.moduleURL = moduleURL
        self.argv0 = argv0
        self.arguments = arguments
        self.root = root
        self.mounts = mounts
        self.overlay = overlay
        self.requiredBackend = requiredBackend
    }
}

/// Where a running program's bytes come from and go to.
public struct WasmStdio: Sendable {
    /// Bytes the guest writes to stdout or stderr, in arrival order.
    public let onOutput: @Sendable (Data) -> Void

    /// Bytes to feed the guest's stdin. Finishing the stream is EOF (Ctrl-D).
    public let input: AsyncStream<UInt8>

    public init(onOutput: @escaping @Sendable (Data) -> Void, input: AsyncStream<UInt8>) {
        self.onOutput = onOutput
        self.input = input
    }
}

/// Executes WebAssembly.
///
/// Two implementations on iOS, and which one is right depends entirely on the
/// guest. An in-process interpreter — Wish uses WasmKit — copies nothing and
/// crosses nothing, and pays per instruction. `WebKitWasmRuntime` runs on
/// WebKit's JIT in the WebContent process, which is the only place on the
/// device allowed to mark memory executable: worth roughly an order of
/// magnitude on compute, and paid for by having no host filesystem on the far
/// side, so preopens are copied in and the guest's writes replayed back out.
///
/// `WasmBackend` is how the user says which, and `SelectedWasmRuntime` is what
/// reads the answer.
///
/// The seam is deliberately narrow — a program, some stdio, an exit status —
/// because everything either backend does differently has to stay behind it.
/// It is also the seam this package is drawn around: an implementation of this
/// protocol is the only thing an embedder has to hold.
public protocol WasmRuntime: Sendable {
    /// Runs to completion and returns the exit status.
    ///
    /// Cancelling the surrounding task interrupts the guest.
    func run(_ program: WasmProgram, stdio: WasmStdio) async throws -> Int32
}

public enum WasmRuntimeError: LocalizedError {
    case notAModule(URL)
    case malformed(URL, String)
    case missingEntryPoint(URL)
    case trapped(String)
    case needsWebView(String)

    public var errorDescription: String? {
        switch self {
        case let .notAModule(url):
            "\(url.lastPathComponent): not a WebAssembly module"
        case let .malformed(url, detail):
            "\(url.lastPathComponent): malformed module (\(detail))"
        case let .missingEntryPoint(url):
            "\(url.lastPathComponent): not an executable module (no _start export)"
        case let .trapped(detail):
            "trapped: \(detail)"
        case let .needsWebView(name):
            "\(name): this package needs the Web View engine — "
                + "change it in Settings → WebAssembly"
        }
    }
}
