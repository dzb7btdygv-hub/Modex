import SwiftUI

struct ModexRootSurface: View {
    @Environment(WindowStateStore.self) private var windowState

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .opacity(windowState.isFullscreen ? 1 : 0.22)

            WindowVibrancyView(
                material: windowState.isFullscreen ? .contentBackground : .underWindowBackground,
                blendingMode: windowState.isFullscreen ? .withinWindow : .behindWindow
            )
            .opacity(windowState.isFullscreen ? 0.82 : 1)
        }
    }
}

struct ModexSidebarSurface: View {
    @Environment(WindowStateStore.self) private var windowState

    var body: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
                .opacity(windowState.isFullscreen ? 0.86 : 0.18)

            WindowVibrancyView(material: .sidebar, blendingMode: .withinWindow)
                .opacity(windowState.isFullscreen ? 0.72 : 0.58)
        }
    }
}

struct ModexDetailSurface: View {
    @Environment(WindowStateStore.self) private var windowState

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .opacity(windowState.isFullscreen ? 0.92 : 0.08)

            WindowVibrancyView(material: .contentBackground, blendingMode: .withinWindow)
                .opacity(windowState.isFullscreen ? 0.52 : 0.24)
        }
    }
}
