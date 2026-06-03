import AppKit
import SwiftUI

/// Stripped-to-basics sidebar: just recent chats + the account row. Native
/// `List(.sidebar)` keeps the system material, selection, and hide/show.
struct SidebarView: View {
    @Environment(ChatStore.self) private var store
    @Binding var selection: SidebarItem?
    @State private var renameTarget: ProjectSummary?
    @State private var renameDraft = ""
    /// Projects currently unfolded to show their chats.
    @State private var expandedProjects: Set<String> = []
    @State private var projectsCollapsed = false
    @State private var chatsCollapsed = false

    var body: some View {
        List {
            if !store.projects.isEmpty {
                Section {
                    if !projectsCollapsed {
                        ForEach(store.projects) { project in
                            ProjectRow(
                                project: project,
                                isActive: project.id == store.activeProjectId,
                                isExpanded: expandedProjects.contains(project.id),
                                onToggle: { toggle(project) },
                                onNewChat: { store.startNewChatInProject(project.id) },
                                onRename: { renameDraft = project.name; renameTarget = project },
                                onRemove: { store.removeProject(project.id) }
                            )
                            .listRow()

                            if expandedProjects.contains(project.id) {
                                ForEach(store.projectChats(project.id)) { chat in
                                    ChatRow(
                                        chat: chat,
                                        indent: 26,
                                        isActive: project.id == store.activeProjectId && chat.id == store.selectedChatId,
                                        onOpen: { store.openProjectChat(projectId: project.id, threadId: chat.id) }
                                    )
                                    .listRow()
                                }
                            }
                        }
                        if store.isInProject {
                            NoFolderRow { store.closeActiveFolder() }.listRow()
                        }
                    }
                } header: {
                    SidebarSectionHeader(title: "Projects", collapsed: projectsCollapsed) {
                        withAnimation(.easeInOut(duration: 0.18)) { projectsCollapsed.toggle() }
                    } trailing: {
                        SidebarHeaderButton(systemImage: "folder.badge.plus", help: "Open a folder as a project") {
                            store.presentFolderPicker()
                        }
                    }
                }
            }

            if store.showFolderlessChats {
                Section {
                    if !chatsCollapsed {
                        ForEach(store.folderlessChats) { chat in
                            ChatRow(
                                chat: chat,
                                indent: 8,
                                isActive: !store.isInProject && chat.id == store.selectedChatId,
                                onOpen: { store.selectChat(chat.id) }
                            )
                            .listRow()
                        }
                    }
                } header: {
                    SidebarSectionHeader(title: "Chats", collapsed: chatsCollapsed) {
                        withAnimation(.easeInOut(duration: 0.18)) { chatsCollapsed.toggle() }
                    } trailing: {
                        if !store.isInProject {
                            SidebarHeaderButton(systemImage: "plus", help: "New chat") { store.startNewChat() }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(ModexSidebarSurface().ignoresSafeArea())
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: 14) // breathing room under the traffic lights
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            EngineFooter()
        }
        .onAppear { if let id = store.activeProjectId { expandedProjects.insert(id) } }
        .onChange(of: store.activeProjectId) { _, id in if let id { expandedProjects.insert(id) } }
        .alert(
            "Rename Project",
            isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } }),
            presenting: renameTarget
        ) { project in
            TextField("Name", text: $renameDraft)
            Button("Rename") {
                store.renameProject(project.id, to: renameDraft)
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        } message: { _ in
            Text("Display name for this project in Modex.")
        }
    }

    private func toggle(_ project: ProjectSummary) {
        withAnimation(.easeInOut(duration: 0.18)) {
            if expandedProjects.contains(project.id) {
                expandedProjects.remove(project.id)
            } else {
                expandedProjects.insert(project.id)
                store.loadProjectThreads(project.id)
            }
        }
    }
}

// MARK: - Projects

/// A project header row in the tree. Tapping toggles its unfold; the active
/// project is tinted. On hover a "⋯" menu offers rename / reveal / remove.
private struct ProjectRow: View {
    let project: ProjectSummary
    let isActive: Bool
    let isExpanded: Bool
    let onToggle: () -> Void
    let onNewChat: () -> Void
    let onRename: () -> Void
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.primary.opacity(0.4))
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
                    .frame(width: 10)
                Image(systemName: isActive ? "folder.fill" : "folder")
                    .font(.callout)
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                    .frame(width: 18)
                Text(project.name)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                if project.isMissing {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .help("This project's folder is missing")
                }
                Spacer(minLength: 4)
                Color.clear.frame(width: 46, height: 1) // room for the + and ⋯ buttons
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowTint(isActive: isActive, hovering: hovering), in: .rect(cornerRadius: 7))
            .contentShape(.rect(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            if hovering {
                HStack(spacing: 1) {
                    ProjectRowIconButton(systemImage: "plus", help: "New chat in this project", action: onNewChat)
                    ProjectRowMenu(onRename: onRename, onReveal: revealInFinder, onRemove: onRemove)
                }
                .padding(.trailing, 6)
            }
        }
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovering)
        .accessibilityLabel("Project \(project.name)\(isActive ? ", active" : ""), \(isExpanded ? "expanded" : "collapsed")")
    }

    private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)])
    }
}

/// A chat row (Codex thread or local chat), styled like a project row so
/// selection looks identical. `indent` nests it beneath its project.
private struct ChatRow: View {
    let chat: RecentChat
    var indent: CGFloat = 8
    let isActive: Bool
    let onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                Text(chat.title)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(chat.timeAgo)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary.opacity(0.5))
            }
            .padding(.leading, indent)
            .padding(.trailing, 8)
            .frame(height: 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowTint(isActive: isActive, hovering: hovering), in: .rect(cornerRadius: 7))
            .contentShape(.rect(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovering)
        .accessibilityLabel("Chat, \(chat.title)")
        .accessibilityValue(chat.timeAgo)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// A small hover icon button on a project row (the "+" new-chat affordance),
/// matching the ⋯ menu's look.
private struct ProjectRowIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(hovering ? Color.primary.opacity(0.14) : Color.clear, in: .rect(cornerRadius: 5))
                .contentShape(.rect(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Collapsible section header with a disclosure chevron + optional trailing control.
private struct SidebarSectionHeader<Trailing: View>: View {
    let title: String
    let collapsed: Bool
    let onToggle: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onToggle) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(collapsed ? -90 : 0))
                        .foregroundStyle(.primary.opacity(0.5))
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary.opacity(0.62))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            trailing()
        }
        .padding(.vertical, 3)
        .help(collapsed ? "Show \(title)" : "Hide \(title)")
    }
}

private struct SidebarHeaderButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary.opacity(0.68))
        .help(help)
        .accessibilityLabel(help)
        .padding(.trailing, 8)
    }
}

/// Shared row tint so projects and chats select/hover identically.
private func rowTint(isActive: Bool, hovering: Bool) -> Color {
    if isActive { return Color.accentColor.opacity(0.16) }
    return hovering ? Color.primary.opacity(0.06) : .clear
}

private extension View {
    /// Sidebar row chrome: no separator, clear background, tight insets so the
    /// tinted selection reads as an inset box like the native sidebar.
    func listRow() -> some View {
        listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
    }
}

/// The hover "⋯" affordance on a project row. Sits in an overlay (not nested in
/// the row's button) so its menu captures clicks cleanly.
private struct ProjectRowMenu: View {
    let onRename: () -> Void
    let onReveal: () -> Void
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        Menu {
            Button(action: onRename) { Label("Rename…", systemImage: "pencil") }
            Button(action: onReveal) { Label("Reveal in Finder", systemImage: "folder") }
            Divider()
            Button(role: .destructive, action: onRemove) {
                Label("Remove from Sidebar", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(hovering ? Color.primary.opacity(0.14) : Color.clear, in: .rect(cornerRadius: 5))
                .contentShape(.rect(cornerRadius: 5))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help("Project options")
        .accessibilityLabel("Project options")
    }
}

/// Leaves the active project to work folderless (chats move to the "Chats" list).
private struct NoFolderRow: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "folder.badge.minus")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text("Work without a folder")
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Color.primary.opacity(0.06) : .clear, in: .rect(cornerRadius: 7))
            .contentShape(.rect(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovering)
        .help("Work outside any project")
    }
}

// MARK: - Account row

/// The account area's backdrop. Uses behind-window vibrancy so it shows the
/// wallpaper (matching the sidebar) rather than a flat black fill, while still
/// occluding the chat list that scrolls behind it.
private struct AccountSurface: View {
    var body: some View {
        ZStack {
            WindowVibrancyView(material: .sidebar, blendingMode: .behindWindow)
            Color(nsColor: .controlBackgroundColor).opacity(0.22)
        }
    }
}

/// The sidebar's bottom footer. Modex has no account, subscription, or sign-in,
/// so this is an honest readout of the Codex engine's state plus the real
/// controls that act on it (update when available, restart, reveal config).
private struct EngineFooter: View {
    @Environment(ChatStore.self) private var store
    @Environment(UpdateStore.self) private var updates
    @State private var expanded = false

    private var anim: Animation { .spring(response: 0.36, dampingFraction: 0.9) }

    var body: some View {
        engineRow
            // Wallpaper-backed so chat text scrolling under the bar is occluded.
            .background(AccountSurface())
            // Hidden while expanded — the raised replica below stands in for it.
            .opacity(expanded ? 0 : 1)
            .allowsHitTesting(!expanded)
            .overlay(alignment: .bottom) {
                if expanded {
                    // The row rises and the menu fills in beneath it, on the same
                    // wallpaper surface as the sidebar so it reads as part of it
                    // (not a black card). An overlay (not taller inset content)
                    // keeps the window from resizing.
                    VStack(spacing: 0) {
                        engineRow
                        Divider()
                            .padding(.horizontal, 12)
                            .padding(.bottom, 4)
                        menuItems
                    }
                    .background(AccountSurface())
                    .overlay(alignment: .top) {
                        Divider().opacity(0.6) // delineate the rising panel from the list
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(1)
                }
            }
    }

    private var engineRow: some View {
        HStack(spacing: 9) {
            EngineStatusDot(tint: statusColor)
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 0) {
                Text("Codex engine").font(.subheadline.weight(.medium))
                Text(store.isReady ? "Connected" : store.status)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary.opacity(0.7))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if updates.updateError != nil {
                UpdateErrorChip()
            } else if updates.isUpdateAvailable || updates.isUpdating {
                UpdateButton()
            }

            Button {
                withAnimation(anim) { expanded.toggle() }
            } label: {
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary.opacity(0.7))
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Engine options")
            .accessibilityLabel(expanded ? "Hide engine menu" : "Show engine menu")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Codex engine, \(store.isReady ? "connected" : store.status)")
    }

    private var menuItems: some View {
        VStack(spacing: 2) {
            AccountRow(title: "Restart Codex", icon: "arrow.clockwise") {
                collapse()
                store.restartCodex()
            }
            AccountRow(title: "Reveal Codex Config", icon: "folder") {
                collapse()
                revealCodexConfig()
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 8)
    }

    private var statusColor: Color {
        switch store.taskStatus {
        case .ready, .completed: return .green
        case .failed: return .red
        default: return store.isReady ? .green : .orange
        }
    }

    /// Reveals the user's Codex config (or the ~/.codex folder) in Finder so they
    /// can inspect trusted projects / auth without leaving Modex.
    private func revealCodexConfig() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexDir = home.appendingPathComponent(".codex", isDirectory: true)
        let config = codexDir.appendingPathComponent("config.toml")
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: config.path) {
            NSWorkspace.shared.activateFileViewerSelecting([config])
        } else if fileManager.fileExists(atPath: codexDir.path) {
            NSWorkspace.shared.activateFileViewerSelecting([codexDir])
        } else {
            NSWorkspace.shared.open(home)
        }
    }

    private func collapse() { withAnimation(anim) { expanded = false } }
}

/// A small filled status indicator for the engine footer (green = connected,
/// amber = starting, red = failed).
private struct EngineStatusDot: View {
    let tint: Color

    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(0.16))
            Circle().fill(tint).frame(width: 9, height: 9)
        }
        .accessibilityHidden(true)
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
        .accessibilityLabel(updates.isUpdating ? "Updating Modex" : "Update Modex")
    }
}

/// Compact amber chip shown in place of the update pill when a check or install
/// fails. Tapping opens a small popover with the explanation, retry, and dismiss
/// — keeping update errors near the control instead of the app-wide banner.
private struct UpdateErrorChip: View {
    @Environment(UpdateStore.self) private var updates
    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
                .frame(width: 26, height: 26)
                .background(Capsule().fill(Color.orange.opacity(0.14)))
                .overlay(Capsule().strokeBorder(Color.orange.opacity(0.35), lineWidth: 0.75))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(updates.updateError?.title ?? "Update failed")
        .accessibilityLabel(updates.updateError?.title ?? "Update failed")
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            if let error = updates.updateError {
                UpdateErrorPopover(error: error) {
                    showPopover = false
                    updates.retryAfterError()
                } onDismiss: {
                    showPopover = false
                    updates.dismissError()
                }
            }
        }
    }
}

private struct UpdateErrorPopover: View {
    let error: ModexError
    let onRetry: () -> Void
    let onDismiss: () -> Void

    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(error.title)
                    .font(.subheadline.weight(.semibold))
            }

            Text(error.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let action = error.suggestedAction {
                Text(action)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let detail = error.technicalDetail {
                Button {
                    withAnimation(.smooth(duration: 0.16)) { showDetails.toggle() }
                } label: {
                    Text(showDetails ? "Hide details" : "Show details")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                if showDetails {
                    ScrollView {
                        Text(detail)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                    }
                    .frame(maxHeight: 90)
                    .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 7))
                }
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Dismiss", action: onDismiss)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.caption.weight(.medium))
                if error.isRetryable {
                    Button(error.retryLabel ?? "Retry", action: onRetry)
                        .buttonStyle(.glassProminent)
                        .controlSize(.small)
                        .tint(.orange)
                }
            }
        }
        .padding(14)
        .frame(width: 260)
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
