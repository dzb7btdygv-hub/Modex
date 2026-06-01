import SwiftUI
import AppKit

/// The *system* window material, exposed to SwiftUI. With a non-opaque window
/// this samples the content behind the window — i.e. the user's desktop
/// wallpaper — so the app reads as a single translucent macOS surface rather
/// than a custom-painted background.
///
/// This is platform material behavior, not decorative glass: it adapts to
/// light/dark, accent, and Reduce Transparency automatically.
struct WindowVibrancyView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}
