import Foundation
import Testing
import WasmRuntimeCore
import WasmWebViewRuntime

/// Runs `Fixtures/guest.wasm` on the web view backend for real.
///
/// No window on either platform. macOS runs a detached `WKWebView` at full
/// speed; the iOS simulator runs it too, but throttled to seconds a run,
/// because nothing has attached it — which is what `WasmWebViewCanvas` is for.
@MainActor
@Suite(.serialized)
struct WasmWebViewHostTests {
    /// One host for the suite, as an embedder would have one for its life.
    static let host = WasmWebViewHost()

    @Test func passesEnvironmentAndExitStatus() async throws {
        let result = try await run(
            "hello", ["7"], environment: ["GREETING": "from the host"])
        #expect(result.output == "hello from the host\n")
        #expect(result.status == 7)
    }

    @Test func defaultEnvironmentHasNoTerminal() async throws {
        #expect(WasmProgram.defaultEnvironment["TERM"] == nil)
        let result = try await run("hello", [])
        #expect(result.output == "hello unset\n")
    }

    @Test func hostFunctionAnswersWithBytes() async throws {
        let result = try await run("echo", [], stdin: "round trip", modules: [testModule()])
        #expect(result.output == "echo:round trip")
        #expect(result.status == 0)
    }

    @Test func thrownErrorReachesTheGuestAsAMessage() async throws {
        let result = try await run("fail", [], modules: [testModule()])
        #expect(result.output == "error=the host said no\n")
        #expect(result.status == 3)
    }

    @Test func eachCallRunsTheFunctionOnce() async throws {
        let counter = Counter()
        let result = try await run("count", [], modules: [testModule(counter: counter)])
        #expect(result.output == "1\n2\n")
        #expect(counter.value == 2)
    }

    @Test func aReplyIsCollectedOnce() async throws {
        let result = try await run("short", [], modules: [testModule()])
        // `echo:abcdef` is 11 bytes; a 3-byte buffer gets the first three, and
        // the rest is gone.
        #expect(result.output == "status=11 first=3 ech second=0\n")
    }

    @Test func stderrSharesStdoutsSinkByDefault() async throws {
        let result = try await run("streams", [])
        #expect(result.output == "out1\nerr1\nout2\nerr2\n")
        #expect(result.errors == "")
    }

    @Test func stderrIsKeptApartWhenAsked() async throws {
        let result = try await run("streams", [], splitStderr: true)
        #expect(result.output == "out1\nout2\n")
        #expect(result.errors == "err1\nerr2\n")
    }

    @Test func writesComeBackToTheHost() async throws {
        let result = try await run("write", [])
        #expect(result.status == 0)
        let written = try String(
            contentsOf: result.root.appending(path: "out.txt"), encoding: .utf8)
        #expect(written == "from the guest\n")
    }

    @Test func aGuestWhoseImportsAreMissingFailsToStart() async throws {
        await #expect(throws: WasmRuntimeError.self) {
            _ = try await run("echo", [], stdin: "x", modules: [])
        }
    }

    @Test func reservedModuleNamesAreRefused() async throws {
        for name in ["wasm_host", "wasi_snapshot_preview1", "", "a/b"] {
            let module = WasmHostModule(name, functions: [])
            await #expect(throws: WasmRuntimeError.self) {
                _ = try await run("hello", [], modules: [module])
            }
        }
    }

    @Test func duplicateFunctionsAreRefused() async throws {
        let call: @Sendable (Data) async throws -> Data = { $0 }
        let module = WasmHostModule(
            "test", functions: [WasmHostFunction("echo", call: call), WasmHostFunction("echo", call: call)])
        await #expect(throws: WasmRuntimeError.self) {
            _ = try await run("hello", [], modules: [module])
        }
    }

    // MARK: - Helpers

    struct Result {
        let output: String
        let errors: String
        let status: Int32
        let root: URL
    }

    struct Refusal: LocalizedError {
        var errorDescription: String? { "the host said no" }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func next() -> Int { lock.withLock { count += 1; return count } }
    }

    func testModule(counter: Counter = Counter()) -> WasmHostModule {
        WasmHostModule("test", functions: [
            WasmHostFunction("echo") { request in Data("echo:".utf8) + request },
            WasmHostFunction("fail") { _ in throw Refusal() },
            WasmHostFunction("count") { _ in Data(String(counter.next()).utf8) },
        ])
    }

    func run(
        _ applet: String,
        _ arguments: [String],
        stdin: String = "",
        environment: [String: String] = WasmProgram.defaultEnvironment,
        // The fixture is one module, so every applet imports `test.*` whether
        // it calls it or not, and every run has to offer it.
        modules: [WasmHostModule]? = nil,
        splitStderr: Bool = false
    ) async throws -> Result {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "WasmWebViewRuntimeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let module = try #require(Bundle.module.url(forResource: "guest", withExtension: "wasm"))
        var env = environment
        env.merge(WasmProgram.defaultEnvironment) { mine, _ in mine }
        let program = WasmProgram(
            moduleURL: module, argv0: applet, arguments: arguments, root: root,
            environment: env, hostModules: modules ?? [testModule()])

        let output = OutputBox()
        let input = AsyncStream<UInt8> { continuation in
            for byte in stdin.utf8 { continuation.yield(byte) }
            continuation.finish()
        }
        let errors = OutputBox()
        let onError: (@Sendable (Data) -> Void)? =
            splitStderr ? { @Sendable in errors.append($0) } : nil
        let status = try await Self.host.run(
            program,
            stdio: WasmStdio(onOutput: { output.append($0) }, input: input, onError: onError))
        return Result(output: output.text, errors: errors.text, status: status, root: root)
    }

    final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }
}
