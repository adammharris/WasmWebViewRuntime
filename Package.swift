// swift-tools-version:6.2
import PackageDescription

// Runs WebAssembly on WebKit's JIT, in the WebContent process, from an app
// that is not itself allowed to JIT.
//
// Split out of Wish (github.com/adammharris/wish), first into a local package
// so the module graph held a boundary that had been held by discipline, then
// into this repository when a second embedder arrived. Everything in here
// stays ignorant of what its embedder is: a shell, a journal, anything else.
//
// Two targets, because the layering is real:
//
//   WasmRuntimeCore     what a wasm program is, what runs one, which engine
//                       to use. No WebKit. The interpreter that stays in the
//                       app imports this and nothing else — a `WasmKitRuntime`
//                       that had to import the web view backend to find its
//                       own protocol would be the wrong shape.
//   WasmWebViewRuntime  the web view, the page, the worker, and the snapshot
//                       format that crosses between them.
//
// The interpreter is deliberately *not* here (Wish keeps its WasmKit one). It is 450 lines of WasmKit and
// SystemPackage glue with no relationship to any of this beyond implementing
// the same protocol, and pulling it in would make a package about web views
// depend on a WebAssembly engine.
let package = Package(
    name: "WasmWebViewRuntime",
    platforms: [
        // iOS 16 is where the web content process of an unattached WKWebView
        // started being terminated, which is the constraint `WasmWebViewCanvas`
        // exists to satisfy. 18 is what Wish targeted when this was split
        // out; nothing here has been tried lower.
        .iOS(.v18),
        // macOS runs a detached web view, so the canvas is optional there.
        // 14 is the release paired with iOS 17's WebKit; untried lower.
        .macOS(.v14),
    ],
    products: [
        .library(name: "WasmRuntimeCore", targets: ["WasmRuntimeCore"]),
        .library(name: "WasmWebViewRuntime", targets: ["WasmWebViewRuntime"]),
    ],
    targets: [
        .target(
            name: "WasmRuntimeCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "WasmWebViewRuntime",
            dependencies: ["WasmRuntimeCore"],
            resources: [
                // `copy` rather than `process`: these are fetched by path
                // through a `WKURLSchemeHandler`, so what matters is that the
                // bytes arrive unchanged and land somewhere predictable.
                // `process` reserves the right to transform and to flatten;
                // `copy` puts the directory in the bundle exactly as it is,
                // which is what `WasmWebViewHost.resource` then looks up.
                //
                // The directory is `Runtime` and not the obvious `Resources`
                // because `copy` preserves the name, and a folder called
                // `Resources` at the top of a bundle is how codesign
                // recognises the macOS layout. It signs the app, sees one
                // inside this bundle, and fails the build with "bundle format
                // unrecognized, invalid, or unsuitable" — which says nothing
                // whatsoever about the actual problem.
                .copy("Runtime")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "WasmWebViewRuntimeTests",
            dependencies: ["WasmRuntimeCore", "WasmWebViewRuntime"],
            // `guest.wasm` is built from `guest.rs`; see the comment at its top.
            exclude: ["Fixtures/guest.rs"],
            resources: [.copy("Fixtures/guest.wasm")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
