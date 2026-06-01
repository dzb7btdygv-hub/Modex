import SwiftUI

/// Stripped-to-basics sidebar: just recent chats + the account row. Native
/// `List(.sidebar)` keeps the system material, selection, and hide/show.
struct SidebarView: View {
    @Binding var selection: SidebarItem?

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
                ForEach(recents) { chat in
                    HStack(spacing: 8) {
                        Text(chat.title).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(chat.timeAgo)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(SidebarItem.recent(chat.id))
                }
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
                    .padding(.trailing, 8) // nudged left off the edge
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: 14) // breathing room under the traffic lights
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            AccountFooter()
        }
    }
}

// MARK: - Account row

private struct AccountFooter: View {
    @Environment(UpdateStore.self) private var updates
    @State private var showAccount = false

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(Color.accentColor.gradient)
                .frame(width: 30, height: 30)
                .overlay(Text("A").font(.subheadline.weight(.semibold)).foregroundStyle(.white))

            VStack(alignment: .leading, spacing: 0) {
                Text("Alex").font(.subheadline.weight(.medium))
                Text("Pro Plan").font(.caption).foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if updates.isUpdateAvailable || updates.isUpdating {
                UpdateButton()
            }

            Button {
                showAccount.toggle()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Account")
            .popover(isPresented: $showAccount, arrowEdge: .bottom) {
                AccountPopover()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// Pink update pill: a compact icon that, on hover, grows leftward into a
/// labelled "Update" capsule. Clicking pulls + rebuilds + relaunches.
private struct UpdateButton: View {
    @Environment(UpdateStore.self) private var updates
    @State private var hovering = false

    private let pink = Color(red: 1.0, green: 0.42, blue: 0.72)

    private var expanded: Bool { hovering || updates.isUpdating }

    var body: some View {
        Button {
            updates.installUpdate()
        } label: {
            HStack(spacing: 6) {
                if expanded {
                    Text(updates.isUpdating ? "Updating" : "Update")
                        .font(.caption.weight(.semibold))
                        .fixedSize()
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
                Image(systemName: updates.isUpdating ? "arrow.triangle.2.circlepath" : "arrow.down")
                    .font(.callout.weight(.bold))
            }
            .foregroundStyle(pink)
            .padding(.horizontal, expanded ? 10 : 0)
            .frame(minWidth: 26)
            .frame(height: 26)
            .background(Capsule().fill(pink.opacity(0.14)))
            .overlay(Capsule().strokeBorder(pink.opacity(0.35), lineWidth: 0.75))
        }
        .buttonStyle(.plain)
        .onHover { value in
            withAnimation(.smooth(duration: 0.22)) { hovering = value }
        }
        .disabled(updates.isUpdating)
        .help("A new version is available — click to update")
    }
}

private struct AccountPopover: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.accentColor.gradient)
                    .frame(width: 38, height: 38)
                    .overlay(Text("A").font(.headline).foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Alex").font(.subheadline.weight(.semibold))
                    Text("Pro Plan").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider()

            VStack(spacing: 2) {
                AccountRow(title: "Settings", icon: "gearshape") {}
                AccountRow(title: "Manage Subscription", icon: "creditcard") {}
            }
            .padding(6)

            Divider()

            VStack(spacing: 2) {
                AccountRow(title: "Sign Out", icon: "rectangle.portrait.and.arrow.right", role: .destructive) {}
            }
            .padding(6)
        }
        .frame(width: 250)
    }
}

private struct AccountRow: View {
    let title: String
    let icon: String
    var role: ButtonRole? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 18)
                Text(title)
                Spacer()
            }
            .font(.callout)
            .foregroundStyle(role == .destructive ? Color.red : Color.primary)
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(hovering ? Color.primary.opacity(0.06) : Color.clear, in: .rect(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
