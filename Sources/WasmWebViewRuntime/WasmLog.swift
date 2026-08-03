import Foundation
import os

/// Where this backend's diagnostics go.
///
/// The app's `Diagnostics` is not reachable from here, and should not be: a
/// package that logs under its embedder's subsystem is a package that cannot be
/// dropped into a second one. The subsystem is read off whoever is running, so
/// the predicate that already shows the shell's logs —
/// `log stream --predicate 'subsystem == "me.adammharris.wish"'` — still shows
/// these, under their own category.
enum WasmLog {
    static let runtime = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "WasmWebViewRuntime",
        category: "wasm"
    )
}
