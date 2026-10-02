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

    /// The guest's environment variables.
    ///
    /// Belongs to the program rather than to either backend, because a guest
    /// that behaves differently between engines over `$TERM` is a bug nobody
    /// would think to look for there. The embedder decides what a guest sees;
    /// ``defaultEnvironment`` is only what it gets when nobody says.
    public let environment: [String: String]

    /// Functions the embedder offers the guest, grouped by import module.
    ///
    /// The guest declares them as imports and calls them synchronously; see
    /// ``WasmHostModule`` for the calling convention. An engine that cannot
    /// offer them refuses the program rather than running it without.
    public let hostModules: [WasmHostModule]

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
        environment: [String: String] = WasmProgram.defaultEnvironment,
        hostModules: [WasmHostModule] = [],
        requiredBackend: WasmBackend? = nil
    ) {
        self.moduleURL = moduleURL
        self.argv0 = argv0
        self.arguments = arguments
        self.root = root
        self.mounts = mounts
        self.overlay = overlay
        self.environment = environment
        self.hostModules = hostModules
        self.requiredBackend = requiredBackend
    }

    /// What a guest sees when the embedder names no environment: a home, a
    /// working directory and a path that are all the guest's `/`, and a UTF-8
    /// locale. No `TERM` — whether there is a terminal, and which, is the
    /// embedder's to say.
    public static let defaultEnvironment: [String: String] = [
        "HOME": "/",
        "PWD": "/",
        "PATH": "/",
        "LANG": "en_US.UTF-8",
    ]
}

/// One function the embedder offers a guest.
///
/// Bytes in, bytes out. What the bytes mean — JSON, a fixed struct, a path —
/// is a contract between the embedder and the guests it writes for, and none
/// of this package's business.
public struct WasmHostFunction: Sendable {
    /// The import field name, e.g. `query` for `(import "diaryx" "query" …)`.
    public let name: String

    /// Answers one call. Throwing hands the guest the error's description in
    /// place of a reply, and the guest decides what that means; it does not
    /// end the run.
    ///
    /// The guest is blocked for as long as this takes, and nothing it wrote
    /// before the call is held back: output is flushed first.
    public let call: @Sendable (Data) async throws -> Data

    public init(_ name: String, call: @escaping @Sendable (Data) async throws -> Data) {
        self.name = name
        self.call = call
    }
}

/// A WebAssembly import module whose functions are answered by the embedder.
///
/// The calling convention is the same for every function in every module, so
/// that a guest needs nothing generated to use one:
///
/// ```wat
/// (import "diaryx" "query" (func $query (param i32 i32) (result i32)))
/// (import "wasm_host" "take_reply" (func $take (param i32 i32) (result i32)))
/// ```
///
/// - A call passes a pointer and a length: the request, in guest memory.
/// - It returns `n >= 0` when the function answered with `n` bytes, or
///   `-(n + 1)` when it threw, with `n` bytes of UTF-8 error message.
/// - Either way the bytes are held for the guest, which collects them with
///   `wasm_host.take_reply(ptr, capacity)`. That copies up to `capacity` bytes
///   to `ptr`, returns how many it copied, and lets the reply go — so a guest
///   with a buffer too small for what it was told the length was has lost the
///   rest, and should have allocated what it was told.
///
/// Two calls rather than one because the reply's length is not known until the
/// function has run, and a guest-supplied buffer that turned out too small
/// would mean calling again — running a function with side effects twice.
///
/// `wasm_host` is reserved, and so are the names WASI's own modules use.
public struct WasmHostModule: Sendable {
    /// The import module name a guest names, e.g. `diaryx`.
    public let name: String
    public let functions: [WasmHostFunction]

    /// The module through which a guest collects a reply.
    public static let replyModule = "wasm_host"

    /// Names a host module may not take, because something else answers them.
    public static let reservedNames: Set<String> = [
        replyModule, "wasi_snapshot_preview1", "wasi_unstable",
    ]

    public init(_ name: String, functions: [WasmHostFunction]) {
        self.name = name
        self.functions = functions
    }
}

/// Where a running program's bytes come from and go to.
public struct WasmStdio: Sendable {
    /// Bytes the guest writes to stdout, and to stderr too unless `onError`
    /// is given — in arrival order either way.
    public let onOutput: @Sendable (Data) -> Void

    /// Bytes the guest writes to stderr, kept apart from stdout.
    ///
    /// `nil`, the default, sends stderr to `onOutput`, interleaved with stdout
    /// as the guest wrote them, which is what a terminal wants. A host that
    /// parses a guest's stdout — replies, one per line — wants the guest's
    /// log somewhere else, and gives this. The runtime's own complaints (a
    /// write-back that failed) go here too when it is given.
    ///
    /// A backend that cannot tell the two streams apart sends both to
    /// `onOutput`; the web view backend can.
    public let onError: (@Sendable (Data) -> Void)?

    /// Bytes to feed the guest's stdin. Finishing the stream is EOF (Ctrl-D).
    public let input: AsyncStream<UInt8>

    /// Whether each of fd 0, 1, and 2 is a terminal rather than a pipe.
    ///
    /// This is the answer to `isatty`, and a REPL is a different program
    /// depending on it: with a terminal it prints a prompt and evaluates a
    /// line at a time, and without one it reads the whole of stdin as a
    /// script. The embedder knows which — the shell already tracks it, and
    /// flips it off for a pipeline stage — and the guest has no other way to
    /// find out, because on this side of the boundary there is no file
    /// descriptor to ask.
    ///
    /// Only the web view backend can act on it: an in-process interpreter
    /// hands the guest a real pipe, and a pipe is not a terminal however it is
    /// described. Defaults to `false`, which is both the honest answer for a
    /// batch embedder and the one that keeps the two backends agreeing.
    public let stdinIsTerminal: Bool
    public let stdoutIsTerminal: Bool
    public let stderrIsTerminal: Bool

    public init(
        onOutput: @escaping @Sendable (Data) -> Void,
        input: AsyncStream<UInt8>,
        onError: (@Sendable (Data) -> Void)? = nil,
        stdinIsTerminal: Bool = false,
        stdoutIsTerminal: Bool = false,
        stderrIsTerminal: Bool = false
    ) {
        self.onOutput = onOutput
        self.input = input
        self.onError = onError
        self.stdinIsTerminal = stdinIsTerminal
        self.stdoutIsTerminal = stdoutIsTerminal
        self.stderrIsTerminal = stderrIsTerminal
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
    case invalidHostModule(String)

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
            "\(name): this program needs the web view backend"
        case let .invalidHostModule(detail):
            "invalid host module: \(detail)"
        }
    }
}
