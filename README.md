# WasmWebViewRuntime

Runs WebAssembly on WebKit's JIT, from an app that is not allowed to JIT.

iOS will not let an app mark memory executable, so Wasmtime, Wasmer's native
engine and V8 are all unavailable in-process. WebKit's WebContent process
carries the entitlement the app does not, and App Store guideline 2.5.2
explicitly permits code run by WebKit. This package runs a WASI preview 1
program in a Web Worker inside a hidden `WKWebView`, and gives it a
filesystem, stdio, and functions of your own.

Split out of [Wish](https://github.com/adammharris/wish), a terminal for iOS
whose every command is a WebAssembly module, where it was written and
debugged on devices.

| | |
| --- | --- |
| Platforms | iOS 18+, macOS 14+ |
| Guests | WASI preview 1 (`wasi_snapshot_preview1`, and `wasi_unstable`) with a `_start` export |
| Engine | WebKit's wasm JIT, in the WebContent process |
| Crashes | A guest that traps or exhausts memory takes down the web view, not the app |

## Using it

```swift
import WasmRuntimeCore
import WasmWebViewRuntime

let host = WasmWebViewHost()          // one for the app's life

// iOS only: the web view must be in a window. One line, anywhere on screen.
ContentView().hostingWasmWebView(host)

let status = try await host.run(
    WasmProgram(
        moduleURL: toolURL,
        argv0: "tool",
        arguments: ["--flag"],
        root: workingDirectory,        // the guest's `/`
        environment: ["HOME": "/", "LANG": "en_US.UTF-8"]
    ),
    stdio: WasmStdio(onOutput: { bytes in print(bytes) }, input: stdinStream)
)
```

Cancelling the surrounding task terminates the guest's worker, which stops it
even in a loop that makes no system calls.

stderr reaches `onOutput` interleaved with stdout, as a terminal wants it. A
host that parses what a guest prints — one reply per line, say — can keep the
guest's log out of it with `onError`:

```swift
WasmStdio(onOutput: { replies.append($0) }, input: requests, onError: { log.append($0) })
```

## Host functions

A guest can call functions the app provides. Group them into a module and put
it on the program:

```swift
let diaryx = WasmHostModule("diaryx", functions: [
    WasmHostFunction("query") { request in
        try await engine.answer(request)   // bytes in, bytes out
    },
])
let program = WasmProgram(/* … */, hostModules: [diaryx])
```

The guest calls them synchronously. Every function has the same type, so a
guest needs nothing generated:

```rust
#[link(wasm_import_module = "diaryx")]
extern "C" { fn query(ptr: *const u8, len: usize) -> i32; }

#[link(wasm_import_module = "wasm_host")]
extern "C" { fn take_reply(ptr: *mut u8, capacity: usize) -> i32; }
```

- The call returns `n ≥ 0` for a reply of `n` bytes, or `-(n + 1)` when the
  Swift function threw, with `n` bytes of UTF-8 error message.
- `take_reply` copies up to `capacity` bytes of that reply into guest memory,
  returns how many it copied, and releases the reply.

The guest is parked for as long as the Swift function takes, and output it
wrote before the call is flushed first. A throw does not end the run; the
guest decides what it means. `wasm_host` and WASI's own module names are
reserved.

Each call is a synchronous `XMLHttpRequest` from the worker to a
`WKURLSchemeHandler`, across a process boundary and through the main actor.
Design protocols around a few large calls, not many small ones.

## How it works

Three channels cross between the app and the WebContent process:

- **Bulk, host to guest**: modules and directory snapshots, over a
  `WKURLSchemeHandler` on the `wasm-webview://` scheme, as raw bytes.
- **Blocking, guest to host**: stdin, sleeps, file bodies, and host
  functions, as a *synchronous* `XMLHttpRequest` from the worker to the same
  handler. That is what makes WASI's synchronous calls work without
  `SharedArrayBuffer`, which a document served by a scheme handler cannot
  have.
- **Everything else**: output, exit status and the filesystem diff, as
  `WKScriptMessageHandler` messages.

There is no host filesystem on the far side. A preopen crosses as a `WSHF`
snapshot: the whole tree structure, and file bodies up to a size budget, with
the rest fetched the first time the guest reads them. The guest's writes come
back as a `WSHW` diff, applied after it exits. Read-only mounts are cached in
the page. Compiled modules are cached by size and modification time.

Wish's [docs](https://github.com/adammharris/wish/tree/master/Docs) record
the decisions and the device bugs behind all of this, especially
[Tools are WebAssembly](https://github.com/adammharris/wish/blob/master/Docs/wasm-runtime.md).

## Testing

```sh
swift test
```

runs a real guest (`Tests/WasmWebViewRuntimeTests/Fixtures/guest.rs`) on
macOS, with no window. The same suite passes on the iOS simulator through
`xcodebuild test -scheme WasmWebViewRuntime-Package`, but a run there takes
0.6–6 s against about 4 ms on the Mac: the view is detached and invisible,
and WebKit throttles it. That is what `hostingWasmWebView` is for in an app.

## License

Dual-licensed under [Apache 2.0](LICENSE-APACHE) or [MIT](LICENSE-MIT), at
your option.
