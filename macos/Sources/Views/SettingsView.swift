import SwiftUI

/// The in-window Settings experience: a centered glass panel that dims and
/// blurs the whole window behind it, with a category sidebar on the left and the
/// matching pane on the right. Driven by `ThemeStore.isSettingsPresented` so the
/// sidebar gear, the `/settings` command, and ⌘, all open the same surface.
struct SettingsOverlay: View {
    @Environment(ThemeStore.self) private var theme

    var body: some View {
        ZStack {
            if theme.isSettingsPresented {
                // Slight blur + scrim over the app; clicking it dismisses.
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .overlay(Color.black.opacity(0.10))
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { dismiss() }
                    .transition(.opacity)

                SettingsPanel(onClose: dismiss)
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: theme.isSettingsPresented)
    }

    private func dismiss() {
        theme.isSettingsPresented = false
    }
}

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case appearance, behavior, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .appearance: return "Appearance"
        case .behavior: return "Behavior"
        case .about: return "About"
        }
    }
    var systemImage: String {
        switch self {
        case .appearance: return "paintpalette"
        case .behavior: return "slider.horizontal.3"
        case .about: return "info.circle"
        }
    }
}

private struct SettingsPanel: View {
    let onClose: () -> Void
    @State private var category: SettingsCategory = .appearance

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .frame(width: 720, height: 480)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.28), radius: 30, y: 14)
        .accessibilityAddTraits(.isModal)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Settings")
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.top, 18)
                .padding(.bottom, 10)

            ForEach(SettingsCategory.allCases) { item in
                SettingsCategoryRow(item: item, isSelected: item == category) {
                    category = item
                }
            }
            Spacer()
        }
        .frame(width: 196)
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(category.title)
                    .font(.title2.weight(.semibold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(.quaternary, in: .circle)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close settings")
                .accessibilityLabel("Close settings")
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)

            ScrollView {
                Group {
                    switch category {
                    case .appearance: AppearancePane()
                    case .behavior: BehaviorPane()
                    case .about: AboutPane()
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct SettingsCategoryRow: View {
    let item: SettingsCategory
    let isSelected: Bool
    let action: () -> Void
    @Environment(ThemeStore.self) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: item.systemImage)
                    .font(.callout)
                    .foregroundStyle(isSelected ? theme.accentColor : .secondary)
                    .frame(width: 20)
                Text(item.title)
                    .font(.callout)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(rowTint, in: .rect(cornerRadius: 8))
            .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var rowTint: Color {
        if isSelected { return theme.accentColor.opacity(0.16) }
        return hovering ? Color.primary.opacity(0.06) : .clear
    }
}

// MARK: - Section scaffolding

/// A titled settings group with a subtitle and content, on a faint card.
private struct SettingsSection<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 24)
    }
}

// MARK: - Appearance

private struct AppearancePane: View {
    @Environment(ThemeStore.self) private var theme

    private let columns = [GridItem(.adaptive(minimum: 34, maximum: 34), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "Theme", subtitle: "Match the system, or lock Modex to light or dark.") {
                HStack(spacing: 12) {
                    ForEach(AppearancePreference.allCases) { option in
                        ThemeOptionCard(option: option, isSelected: theme.appearance == option) {
                            theme.appearance = option
                        }
                    }
                }
            }

            SettingsSection(title: "Accent color", subtitle: "Tints buttons, selection, and the context ring.") {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(AccentOption.allCases) { option in
                        AccentSwatch(option: option, isSelected: theme.accent == option) {
                            theme.accent = option
                        }
                    }
                }
            }
        }
    }
}

private struct ThemeOptionCard: View {
    let option: AppearancePreference
    let isSelected: Bool
    let action: () -> Void
    @Environment(ThemeStore.self) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: option.systemImage)
                    .font(.system(size: 22))
                    .foregroundStyle(isSelected ? theme.accentColor : .secondary)
                    .frame(height: 26)
                Text(option.label)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(isSelected ? theme.accentColor.opacity(0.12) : Color.primary.opacity(hovering ? 0.05 : 0.025),
                        in: .rect(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? theme.accentColor.opacity(0.6) : Color.primary.opacity(0.08),
                                  lineWidth: isSelected ? 1.5 : 0.75)
            )
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(option.label) appearance")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct AccentSwatch: View {
    let option: AccentOption
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(option.color)
                .frame(width: 26, height: 26)
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .overlay(
                    Circle().strokeBorder(.white.opacity(isSelected ? 0.9 : 0.0), lineWidth: 1.5)
                )
                .overlay(
                    Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.75)
                )
                .scaleEffect(hovering ? 1.12 : 1.0)
                .shadow(color: option.color.opacity(isSelected ? 0.5 : 0), radius: 5)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovering)
        .help(option.label)
        .accessibilityLabel("\(option.label) accent")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Behavior

private struct BehaviorPane: View {
    @Environment(ThemeStore.self) private var theme

    var body: some View {
        @Bindable var theme = theme
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "Composer") {
                VStack(spacing: 2) {
                    SettingsToggleRow(
                        title: "Return sends the message",
                        subtitle: theme.returnSends
                            ? "⇧⏎ inserts a new line."
                            : "⌘⏎ sends; ⏎ inserts a new line.",
                        isOn: $theme.returnSends
                    )
                }
            }

            SettingsSection(title: "Context") {
                SettingsToggleRow(
                    title: "Offer to compact when nearly full",
                    subtitle: "Suggest compacting the conversation as it approaches the model's context window.",
                    isOn: $theme.autoCompactNearLimit
                )
            }
        }
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - About

private struct AboutPane: View {
    @Environment(UpdateStore.self) private var updates

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Modex").font(.title2.weight(.semibold))
                    Text(updates.versionString.isEmpty ? "A native macOS client for the Codex engine"
                                                        : "Version \(updates.versionString)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)

            Text("Modex is an open-source desktop client powered by the Codex engine. It stores no credentials of its own — sign-in is delegated to your local Codex setup.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Link(destination: URL(string: "https://github.com/dzb7btdygv-hub/Modex")!) {
                Label("View the project on GitHub", systemImage: "arrow.up.right.square")
                    .font(.callout.weight(.medium))
            }
            .padding(.top, 2)

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
