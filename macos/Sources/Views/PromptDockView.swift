import AppKit
import SwiftUI

/// The prompt composer. A thin permission pill sits above-left and opens upward;
/// beneath it a compact glass rectangle holds ＋ · the text field · send/stop.
struct PromptDockView: View {
    @Environment(ChatStore.self) private var store
    @State private var draft = ""
    @State private var textHeight: CGFloat = 32

    private var hasText: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var canSend: Bool { store.canSend && hasText }
    private var canStop: Bool { store.turnRunning }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            selectorRow
            .padding(.horizontal, 4)

            HStack(alignment: .center, spacing: 8) {
                Button {
                    // Attach context.
                } label: {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Add context")
                .accessibilityLabel("Add context")

                ZStack(alignment: .leading) {
                    ComposerTextView(
                        text: $draft,
                        height: $textHeight,
                        isEnabled: store.isReady,
                        onSubmit: submit
                    )

                    if draft.isEmpty {
                        Text("Ask Modex to build anything…")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .allowsHitTesting(false)
                    }
                }
                .frame(minHeight: 30)
                .frame(height: textHeight, alignment: .center)

                SendButton(
                    active: hasText,
                    enabled: canSend || canStop,
                    isRunning: store.turnRunning,
                    action: store.turnRunning ? store.cancelTurn : submit
                )
            }
            .padding(.leading, 9)
            .padding(.trailing, 7)
            .padding(.vertical, 6)
            .frame(minHeight: 42)
            .glassEffect(.regular, in: .rect(cornerRadius: 21))
            .overlay(
                RoundedRectangle(cornerRadius: 21, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.75)
            )
            .contentShape(.rect(cornerRadius: 21))
        }
    }

    private var selectorRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 8) {
                permissionSelector
                Spacer(minLength: 12)
                modelSelector
                reasoningSelector
            }

            VStack(alignment: .leading, spacing: 6) {
                permissionSelector
                HStack(spacing: 8) {
                    modelSelector
                    reasoningSelector
                }
            }
        }
    }

    private var permissionSelector: some View {
        PermissionSelector(
            selected: store.selectedPermission,
            onSelect: store.selectPermission
        )
    }

    private var modelSelector: some View {
        InlineUpwardSelectorPill(
            systemImage: "cpu",
            title: store.selectedModel,
            accessibilityLabel: "Model, \(store.selectedModel)",
            options: store.availableModels,
            selected: store.selectedModel
        ) { store.selectModel($0) }
    }

    private var reasoningSelector: some View {
        InlineUpwardSelectorPill(
            systemImage: "brain",
            title: store.reasoning.label,
            accessibilityLabel: "Reasoning, \(store.reasoning.label)",
            options: ReasoningEffort.allCases.map(\.label),
            selected: store.reasoning.label
        ) { if let level = ReasoningEffort(label: $0) { store.selectReasoning(level) } }
    }

    private func submit() {
        guard canSend else { return }
        let text = draft
        draft = ""
        store.send(text)
    }
}

/// Liquid-glass circle that fills with pink once there's something to send or stop.
/// Springy native press + a subtle hover lift.
private struct SendButton: View {
    let active: Bool
    let enabled: Bool
    let isRunning: Bool
    let action: () -> Void

    @State private var hovering = false
    private let pink = Color(red: 1.0, green: 0.42, blue: 0.72)
    private var filled: Bool { active || isRunning }

    var body: some View {
        Button(action: action) {
            Image(systemName: isRunning ? "stop.fill" : "arrow.up")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(filled ? Color.white : Color.secondary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(pink).opacity(filled ? 1 : 0))
                .background(Color.clear.glassEffect(.regular, in: Circle()))
        }
        .buttonStyle(PressableStyle())
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .scaleEffect(hovering && enabled ? 1.07 : 1.0)
        .animation(.smooth(duration: 0.18), value: filled)
        .animation(.smooth(duration: 0.18), value: isRunning)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovering)
        .help(isRunning ? "Stop" : "Send")
        .accessibilityLabel(isRunning ? "Stop response" : "Send message")
    }
}

private struct PermissionSelector: View {
    let selected: PermissionMode
    let onSelect: (PermissionMode) -> Void

    @State private var isOpen = false
    @State private var hovering = false

    private let danger = Color(red: 1.0, green: 0.31, blue: 0.18)

    private var tint: Color {
        selected == .fullAccess ? danger : .secondary
    }

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: selected.systemImage)
                    .font(.caption.weight(.semibold))
                Text(selected.label)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(0.55)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(hovering ? tint.opacity(0.10) : Color.clear, in: .capsule)
            .overlay(Capsule().strokeBorder(selected == .fullAccess ? danger.opacity(0.42) : .clear, lineWidth: 0.75))
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovering = $0 }
        .accessibilityLabel("Permissions, \(selected.label)")
        .accessibilityValue(selected.sandboxMode)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(PermissionMode.allCases) { mode in
                    PermissionRow(mode: mode, selected: mode == selected) {
                        onSelect(mode)
                        isOpen = false
                    }
                }
            }
            .padding(6)
            .frame(width: 190)
        }
    }
}

private struct PermissionRow: View {
    let mode: PermissionMode
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false
    private let danger = Color(red: 1.0, green: 0.31, blue: 0.18)

    private var tint: Color {
        mode == .fullAccess ? danger : .primary
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark" : mode.systemImage)
                    .font(.caption.weight(.semibold))
                    .frame(width: 14)
                Text(mode.label).font(.callout)
                Spacer(minLength: 12)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? tint.opacity(0.09) : .clear, in: .rect(cornerRadius: 7))
            .contentShape(.rect(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let isEnabled: Bool
    let onSubmit: () -> Void

    private let minHeight: CGFloat = 30
    private let maxHeight: CGFloat = 154

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true

        let textView = SubmitTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.isRichText = false
        textView.isEditable = isEnabled
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .preferredFont(forTextStyle: .body, options: [:])
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.textContainerInset = NSSize(width: 0, height: 5)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: minHeight)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.string = text
        textView.setAccessibilityLabel("Message")
        textView.setAccessibilityPlaceholderValue("Ask Modex to build anything")

        scrollView.documentView = textView
        context.coordinator.textView = textView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text {
            textView.string = text
        }
        textView.isEditable = isEnabled
        textView.onSubmit = onSubmit
        textView.setAccessibilityLabel("Message")
        textView.setAccessibilityPlaceholderValue("Ask Modex to build anything")
        context.coordinator.parent = self
        context.coordinator.updateHeight()
        scrollView.hasVerticalScroller = height >= maxHeight
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: SubmitTextView?

        init(_ parent: ComposerTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            updateHeight()
        }

        func updateHeight() {
            guard
                let textView,
                let layoutManager = textView.layoutManager,
                let textContainer = textView.textContainer
            else { return }

            layoutManager.ensureLayout(for: textContainer)
            let usedHeight = layoutManager.usedRect(for: textContainer).height + textView.textContainerInset.height * 2
            let nextHeight = min(max(parent.minHeight, ceil(usedHeight)), parent.maxHeight)

            if abs(parent.height - nextHeight) > 0.5 {
                DispatchQueue.main.async {
                    self.parent.height = nextHeight
                }
            }
        }
    }
}

private final class SubmitTextView: NSTextView {
    var onSubmit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76

        if isReturn {
            if event.modifierFlags.contains(.shift) {
                insertNewlineIgnoringFieldEditor(nil)
            } else {
                onSubmit?()
            }
            return
        }

        super.keyDown(with: event)
    }
}

/// Springy press feedback for custom glass buttons.
private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.55), value: configuration.isPressed)
    }
}
