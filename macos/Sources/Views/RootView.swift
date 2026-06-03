import SwiftUI

struct RootView: View {
    @Environment(UpdateStore.self) private var updates
    @Environment(ChatStore.self) private var store
    @State private var selection: SidebarItem?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
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
        // Centered Settings panel that dims + blurs the whole window behind it.
        .overlay { SettingsOverlay() }
        .onAppear {
            selection = store.selectedChatId.map(SidebarItem.recent)
        }
        .onChange(of: selection) { _, item in
            if case .recent(let id)? = item {
                store.selectChat(id)
            }
        }
        .onChange(of: store.selectedChatId) { _, id in
            selection = id.map(SidebarItem.recent)
        }
    }

    @ViewBuilder
    private var versionReadout: some View {
        if !updates.versionString.isEmpty {
            Text(updates.versionString)
                .font(.system(size: 9, weight: .regular).monospacedDigit())
                .foregroundStyle(.secondary)
                .opacity(0.62)
                // Clear of the window's rounded bottom-right corner.
                .padding(.trailing, 16)
                .padding(.bottom, 12)
                .allowsHitTesting(false)
        }
    }
}
