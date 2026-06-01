import SwiftUI

private struct Destination: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let icon: String
}

/// Native sidebar: a system `List` in `.sidebar` style. Selection, hover, the
/// translucent material, and hide/show behavior are all provided by macOS.
struct SidebarView: View {
    @Binding var selection: SidebarItem?

    private let destinations: [Destination] = [
        .init(title: "Chat", icon: "bubble.left.and.bubble.right"),
        .init(title: "Goals", icon: "target"),
        .init(title: "Agents", icon: "person.2"),
        .init(title: "Sandbox", icon: "shippingbox"),
        .init(title: "Context Cache", icon: "square.3.layers.3d"),
        .init(title: "Recovery Points", icon: "clock.arrow.circlepath"),
        .init(title: "Usage", icon: "chart.bar"),
    ]

    private let recents: [RecentChat] = [
        .init(title: "Build auth system", timeAgo: "2m ago"),
        .init(title: "Fix navbar bug", timeAgo: "1h ago"),
        .init(title: "Add dark mode", timeAgo: "3h ago"),
        .init(title: "Improve docs", timeAgo: "Yesterday"),
        .init(title: "Refactor components", timeAgo: "2d ago"),
    ]

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(destinations) { item in
                    Label(item.title, systemImage: item.icon)
                        .tag(SidebarItem.destination(item.title))
                }
            }

            Section {
                ForEach(recents) { chat in
                    HStack(spacing: 8) {
                        Text(chat.title)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(chat.timeAgo)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(SidebarItem.recent(chat.id))
                }

                Button {
                    // Show full history.
                } label: {
                    Label("View all chats", systemImage: "arrow.right")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } header: {
                HStack {
                    Text("Recent Chats")
                    Spacer()
                    Button {
                        // Start a new chat.
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("New chat")
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) { brandMark }
        .safeAreaInset(edge: .bottom, spacing: 0) { accountFooter }
    }

    // Restrained brand expression: the app icon + wordmark, no decorative chrome.
    private var brandMark: some View {
        HStack(spacing: 9) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 22, height: 22)
            Text("Modex")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var accountFooter: some View {
        Menu {
            Button("Account Settings…") {}
            Button("Manage Subscription") {}
            Divider()
            Button("Sign Out", role: .destructive) {}
        } label: {
            HStack(spacing: 9) {
                Circle()
                    .fill(Color.accentColor.gradient)
                    .frame(width: 28, height: 28)
                    .overlay(Text("A").font(.subheadline.weight(.semibold)).foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 0) {
                    Text("Alex").font(.subheadline.weight(.medium))
                    Text("Pro Plan").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .padding(8)
    }
}
