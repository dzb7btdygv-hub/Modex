import SwiftUI

/// A liquid-glass pill that shows the current selection and, when tapped,
/// expands into a small rounded "box" of options. Shared by the top-bar model
/// and reasoning selectors and the composer's context selector.
///
/// `opensUpward` flips the popover so the box grows away from the composer
/// (upward) instead of downward — keeping it from covering the chat box.
struct SelectorPill: View {
    var systemImage: String? = nil
    let title: String
    let options: [String]
    let selected: String
    var opensUpward: Bool = false
    let onSelect: (String) -> Void

    @State private var isOpen = false

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
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
            .fixedSize()
        }
        .buttonStyle(.glass)
        .popover(isPresented: $isOpen, arrowEdge: opensUpward ? .bottom : .top) {
            SelectorBox(options: options, selected: selected) { choice in
                onSelect(choice)
                isOpen = false
            }
        }
        .help(title)
    }
}

/// The popover body: a vertical stack of choices — taller than it is wide, so
/// it reads as a rectangle dropping down (or rising up) from the pill.
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
        .frame(width: 218)
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
                Text(label).font(.callout)
                Spacer(minLength: 12)
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .opacity(isSelected ? 1 : 0)
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
