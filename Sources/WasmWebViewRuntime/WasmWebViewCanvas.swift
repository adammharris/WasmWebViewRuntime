import SwiftUI
import WebKit

#if canImport(UIKit)
/// Puts the JIT backend's web view in the view hierarchy, where it has to be.
///
/// This looks like dead weight and is not. From iOS 16 on, a `WKWebView` that
/// is not in a window has its web content process terminated, and one that the
/// system considers invisible has its JavaScript throttled — either of which
/// turns the backend into a runtime that hangs on its first command. A view
/// that is attached, one point across, and behind whatever the embedder is
/// drawing is the smallest arrangement that stays alive.
///
/// Not `isHidden`, and not zero-sized, for the same reason: both read as "not
/// visible" to WebKit's throttling. Nearly transparent and one pixel does not.
public struct WasmWebViewCanvas: UIViewRepresentable {
    let host: WasmWebViewHost

    public init(host: WasmWebViewHost) {
        self.host = host
    }

    public func makeUIView(context _: Context) -> WKWebView {
        host.view
    }

    public func updateUIView(_: WKWebView, context _: Context) {}
}
#elseif canImport(AppKit)
/// The macOS counterpart, for an embedder that wants one code path.
///
/// macOS does not terminate the web content process of a detached
/// `WKWebView`, so the backend runs without this; `WasmWebViewHostTests` runs
/// with no window at all. Attaching it is harmless, and keeps a view that is
/// shared with iOS from needing a platform check.
public struct WasmWebViewCanvas: NSViewRepresentable {
    let host: WasmWebViewHost

    public init(host: WasmWebViewHost) {
        self.host = host
    }

    public func makeNSView(context _: Context) -> WKWebView {
        host.view
    }

    public func updateNSView(_: WKWebView, context _: Context) {}
}
#endif

extension View {
    /// Attaches the web view behind whatever the embedder is drawing.
    ///
    /// Shipped with the backend rather than left to the embedder because on
    /// iOS it is not decoration: get it wrong and the backend hangs on its
    /// first command, with nothing in the failure pointing at a missing view.
    public func hostingWasmWebView(_ host: WasmWebViewHost) -> some View {
        background(alignment: .bottomLeading) {
            WasmWebViewCanvas(host: host)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
