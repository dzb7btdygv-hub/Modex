import AppKit
import SwiftUI

struct TopChatBarView: View {
    @Environment(ChatStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            titleRow
                // Match the conversation's centered 720 column so the chat title
                // sits directly above the message text it labels (not pinned to
                // the far left while the messages center).
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
                // The usage ring rides the window's true right edge, independent
                // of the centered title column.
                .overlay(alignment: .trailing) { UsageRingView() }
                .padding(.horizontal, 28)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.7))
                .frame(height: 1)
                .padding(.horizontal, 28)
        }
        .background(ModexDetailSurface().opacity(0.58))
    }

    private var titleRow: some View {
        HStack(spacing: 10) {
            Text(store.chatTitle)
                .font(.headline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.primary)

            Button {
                store.presentFolderPicker()
            } label: {
                TopBarPillLabel(systemImage: "folder", title: store.selectedFolderName, showsChevron: true)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help("Choose project folder")
            .accessibilityLabel("Choose project folder")
            .accessibilityValue(store.selectedFolderPath ?? "No folder selected")

            if store.activeProjectMissing {
                Button {
                    store.presentFolderPicker()
                } label: {
                    FolderMissingPill()
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help("This project's folder is missing — choose it again")
                .accessibilityLabel("Project folder missing, choose again")
            } else if let gitBranch = store.gitBranch {
                BranchMenu(current: gitBranch, branches: store.gitBranches) { store.switchGitBranch($0) }
            }

            // Reserve a lane on the right so the pills never slide under the ring.
            Spacer(minLength: 36)
        }
    }
}

/// The git-branch pill, now a switcher: lists local branches and checks one out.
private struct BranchMenu: View {
    let current: String
    let branches: [String]
    let onSwitch: (String) -> Void

    private var options: [String] { branches.isEmpty ? [current] : branches }

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { branch in
                Button {
                    if branch != current { onSwitch(branch) }
                } label: {
                    if branch == current {
                        Label(branch, systemImage: "checkmark")
                    } else {
                        Text(branch)
                    }
                }
            }
        } label: {
            TopBarPillLabel(systemImage: "point.3.connected.trianglepath.dotted", title: current, showsChevron: true)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch branch")
        .accessibilityLabel("Git branch, \(current)")
    }
}

private struct FolderMissingPill: View {
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
            Text("Folder missing")
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Color.orange.opacity(hovering ? 0.16 : 0.10), in: .rect(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 0.75)
        )
        .contentShape(.rect(cornerRadius: 7))
        .onHover { hovering = $0 }
    }
}

private struct TopBarPillLabel: View {
    let systemImage: String
    let title: String
    var showsChevron = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(0.55)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(hovering ? Color.primary.opacity(0.08) : Color.primary.opacity(0.025), in: .rect(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.primary.opacity(hovering ? 0.18 : 0.10), lineWidth: 0.75)
        )
        .contentShape(.rect(cornerRadius: 7))
        .scaleEffect(ModexMotion.hoverScale(reduceMotion, hovering ? 1.03 : 1.0))
        .onHover { hovering = $0 }
        .animation(ModexMotion.micro(reduceMotion), value: hovering)
    }
}
