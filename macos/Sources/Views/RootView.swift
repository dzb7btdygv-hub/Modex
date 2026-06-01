import SwiftUI

struct RootView: View {
    @Environment(UpdateStore.self) private var updates
    @State private var selection: SidebarItem?

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 224, ideal: 256, max: 320)
        } detail: {
            ChatPaneView()
        }
        // No window title — the composer owns model and reasoning controls.
        .navigationTitle("")
        .toolbar(removing: .title)
        .background(ModexRootSurface().ignoresSafeArea())
        // Very small, faint, dynamic version readout.
        .overlay(alignment: .bottomTrailing) { versionReadout }
    }

    @ViewBuilder
    private var versionReadout: some View {
        if !updates.versionString.isEmpty {
            Text(updates.versionString)
                .font(.system(size: 9, weight: .regular).monospacedDigit())
                .foregroundStyle(.secondary)
                .opacity(0.62)
                .padding(.trailing, 9)
                .padding(.bottom, 6)
                .allowsHitTesting(false)
        }
    }
}
