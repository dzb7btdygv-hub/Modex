import SwiftUI

struct RootView: View {
    @State private var selection: SidebarItem? = .destination("Chat")
    @State private var search = ""

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 224, ideal: 256, max: 320)
        } detail: {
            ChatPaneView(search: $search)
        }
        .navigationTitle("Modex")
        // The window itself is transparent; this is the system material that
        // frosts the desktop wallpaper behind both columns.
        .background(WindowVibrancyView().ignoresSafeArea())
    }
}
