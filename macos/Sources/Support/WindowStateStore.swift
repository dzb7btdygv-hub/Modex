import AppKit
import Observation

@MainActor
@Observable
final class WindowStateStore {
    private(set) var isFullscreen = false

    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []

    func attach(_ window: NSWindow) {
        guard self.window !== window else {
            refresh()
            return
        }

        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()

        self.window = window
        refresh()

        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            },
            center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            },
        ]
    }

    func refresh() {
        isFullscreen = window?.styleMask.contains(.fullScreen) == true
        window?.backgroundColor = isFullscreen ? .windowBackgroundColor : .clear
    }
}
