import Foundation
import os

/// Where this backend's diagnostics go.
///
/// The embedder's own logging is not reachable from here, and should not be:
/// a package that logs through its embedder's types is a package that cannot
/// be dropped into a second one. The subsystem is read off whoever is running,
/// so the predicate that already shows the embedder's logs —
/// `log stream --predicate 'subsystem == "<its bundle id>"'` — shows these
/// too, under their own category.
enum WasmLog {
    static let runtime = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "WasmWebViewRuntime",
        category: "wasm"
    )
}
