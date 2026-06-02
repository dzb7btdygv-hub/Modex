import AppKit
import SwiftUI

struct TopChatBarView: View {
    @Environment(ChatStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(store.chatTitle)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                    .layoutPriority(1)

                Button {
                    store.presentFolderPicker()
                } label: {
                    TopBarPillLabel(systemImage: "folder", title: store.selectedFolderName, showsChevron: true)
                }
                .buttonStyle(.plain)
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
                    .help("This project's folder is missing — choose it again")
                    .accessibilityLabel("Project folder missing, choose again")
                } else if let gitBranch = store.gitBranch {
                    TopBarPillLabel(systemImage: "point.3.connected.trianglepath.dotted", title: gitBranch)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Git branch, \(gitBranch)")
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 8)

            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.58))
                .frame(height: 0.75)
                .padding(.horizontal, 28)
        }
        .background(ModexDetailSurface().opacity(0.58))
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
        .background(hovering ? Color.primary.opacity(0.06) : Color.primary.opacity(0.025), in: .rect(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.primary.opacity(hovering ? 0.16 : 0.10), lineWidth: 0.75)
        )
        .contentShape(.rect(cornerRadius: 7))
        .onHover { hovering = $0 }
    }
}
