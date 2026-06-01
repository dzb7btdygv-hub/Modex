import SwiftUI
import AppKit

@main
struct ModexApp: App {
    @State private var store = ChatStore()
    @State private var updates = UpdateStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(updates)
                .background(WindowConfigurator())
                .onAppear {
                    store.bootIfNeeded()
                    updates.start()
                }
                .onDisappear {
                    store.shutdown()
                    updates.stop()
                }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1240, height: 820)
        .commands {
            // Keep every toolbar action reachable from the menu bar (HIG).
            CommandGroup(replacing: .newItem) {
                Button("New Chat") {}.keyboardShortcut("n")
            }
        }
    }
}

/// Makes the window non-opaque with a transparent, full-height titlebar so the
/// desktop wallpaper shows through the system materials and the native toolbar
/// floats over the content. Traffic lights stay in place.
private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.minSize = NSSize(width: 960, height: 640)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
