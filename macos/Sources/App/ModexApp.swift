import SwiftUI
import AppKit

@main
struct ModexApp: App {
    @State private var store = ChatStore()
    @State private var updates = UpdateStore()
    @State private var windowState = WindowStateStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(updates)
                .environment(windowState)
                .background(WindowConfigurator(windowState: windowState))
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
    let windowState: WindowStateStore

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            configure(window)
            windowState.attach(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        configure(window)
        windowState.attach(window)
    }

    private func configure(_ window: NSWindow) {
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isOpaque = false
        window.backgroundColor = window.styleMask.contains(.fullScreen) ? .windowBackgroundColor : .clear
        window.hasShadow = true
        window.minSize = NSSize(width: 960, height: 640)
    }
}
