import Foundation
import WasmRuntimeCore

/// Runs WebAssembly on WebKit's JIT.
///
/// The WebContent process holds the `dynamic-codesigning` entitlement this
/// process never will, so wasm there is compiled rather than interpreted. That
/// is the whole reason this backend exists, and it is worth roughly an order of
/// magnitude on anything compute-bound.
///
/// What it costs is the filesystem. There is no host FS on the other side of
/// the boundary, so a preopen has to be copied in as a tree and the guest's
/// changes replayed back out afterwards — see `WasmSnapshot`. That makes short,
/// file-heavy commands *slower* than the interpreter and long compute-bound
/// ones far faster, which is exactly the axis `WasmBackend` asks the user to
/// choose on.
///
/// Everything hard lives in `WasmWebViewHost`; this is the adapter that lets a
/// main-actor-bound web view satisfy a `Sendable` protocol callable from any
/// pipeline stage.
public final class WebKitWasmRuntime: WasmRuntime {
    private let host: WasmWebViewHost

    public init(host: WasmWebViewHost) {
        self.host = host
    }

    public func run(_ program: WasmProgram, stdio: WasmStdio) async throws -> Int32 {
        try await host.run(program, stdio: stdio)
    }
}
