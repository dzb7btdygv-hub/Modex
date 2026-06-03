import SwiftUI

/// Shared liquid-glass pill label: icon · title · chevron, on a glass capsule.
private struct PillLabel: View {
    var systemImage: String?
    let title: String

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
            }
            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .opacity(0.5)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.75))
    }
}

/// Top-bar pill (model, reasoning). Backed by a native menu: instant to open,
/// drops *down* — which is what we want under the title bar.
struct SelectorPill: View {
    var systemImage: String? = nil
    let title: String
    let options: [String]
    let selected: String
    let onSelect: (String) -> Void

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    onSelect(option)
                } label: {
                    if option == selected {
                        Label(option, systemImage: "checkmark")
                    } else {
                        Text(option)
                    }
                }
            }
        } label: {
            PillLabel(systemImage: systemImage, title: title)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// Composer-side pill. Opens upward via a popover so options do not cover the
/// chat box beneath it.
struct UpwardSelectorPill: View {
    var systemImage: String? = nil
    let title: String
    let options: [String]
    let selected: String
    let onSelect: (String) -> Void

    @State private var isOpen = false

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            PillLabel(systemImage: systemImage, title: title)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            SelectorBox(options: options, selected: selected) { choice in
                onSelect(choice)
                isOpen = false
            }
        }
    }
}

/// Composer-side selector with no persistent backplate. It keeps the click
/// target but avoids the toolbar-style capsule behind model/reasoning controls.
struct InlineUpwardSelectorPill: View {
    var systemImage: String? = nil
    let title: String
    var accessibilityLabel: String? = nil
    let options: [String]
    let selected: String
    let onSelect: (String) -> Void

    @State private var isOpen = false
    @State private var hovering = false

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption.weight(.semibold))
                }
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(0.55)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(hovering ? Color.primary.opacity(0.07) : Color.clear, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovering = $0 }
        .accessibilityLabel(accessibilityLabel ?? title)
        .accessibilityValue(selected)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            SelectorBox(options: options, selected: selected) { choice in
                onSelect(choice)
                isOpen = false
            }
        }
    }
}

/// The popover body for the upward selector — a vertical list of choices.
private struct SelectorBox: View {
    let options: [String]
    let selected: String
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(options, id: \.self) { option in
                SelectorRow(label: option, isSelected: option == selected) {
                    onSelect(option)
                }
            }
        }
        .padding(6)
        .frame(width: 200)
    }
}

private struct SelectorRow: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .opacity(isSelected ? 1 : 0)
                Text(label).font(.callout)
                Spacer(minLength: 12)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Color.primary.opacity(0.08) : .clear, in: .rect(cornerRadius: 7))
            .contentShape(.rect(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
