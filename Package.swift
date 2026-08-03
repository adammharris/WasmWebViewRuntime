// swift-tools-version:6.2
import PackageDescription

// The JIT backend, split out of the app.
//
// Not because a second consumer exists — there isn't one — but because the
// boundary was being held by discipline rather than by the compiler. Everything
// in here had to stay ignorant of packages, manifests, the shell's namespace
// and the terminal, and nothing but care was stopping `BinManifest` from
// appearing in a signature. Now the module graph stops it.
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
// The interpreter is deliberately *not* here. It is 450 lines of WasmKit and
// SystemPackage glue with no relationship to any of this beyond implementing
// the same protocol, and pulling it in would make a package about web views
// depend on a WebAssembly engine.
let package = Package(
    name: "WasmWebViewRuntime",
    platforms: [
        // iOS 16 is where the web content process of an unattached WKWebView
        // started being terminated, which is the constraint `WasmWebViewCanvas`
        // exists to satisfy. The app targets 18 for unrelated reasons.
        .iOS(.v18)
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
    ]
)
