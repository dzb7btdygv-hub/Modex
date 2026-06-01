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
        .navigationTitle("Modex")
        // The window itself is transparent; this is the system material that
        // frosts the desktop wallpaper behind both columns.
        .background(WindowVibrancyView().ignoresSafeArea())
        // Very small, faint, dynamic version readout.
        .overlay(alignment: .bottomTrailing) { versionReadout }
    }

    @ViewBuilder
    private var versionReadout: some View {
        if !updates.versionString.isEmpty {
            Text(updates.versionString)
                .font(.system(size: 9, weight: .regular).monospacedDigit())
                .foregroundStyle(.secondary)
                .opacity(0.4)
                .padding(.trailing, 9)
                .padding(.bottom, 6)
                .allowsHitTesting(false)
        }
    }
}
