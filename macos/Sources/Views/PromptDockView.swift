import AppKit
import SwiftUI

/// The prompt composer. A thin context pill sits above-left and opens *upward*;
/// beneath it a compact glass rectangle holds ＋ · the text field · send. The
/// box grows upward (up to a cap, then scrolls) as you type more lines, carrying
/// the context pill up with it.
struct PromptDockView: View {
    @Environment(ChatStore.self) private var store
    @State private var draft = ""
    @State private var textHeight: CGFloat = 32

    private var hasText: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var canSend: Bool { store.canSend && hasText }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            selectorRow
            .padding(.horizontal, 4)

            HStack(alignment: .bottom, spacing: 10) {
                Button {
                    // Attach context.
                } label: {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
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
                .frame(height: textHeight)

                SendButton(active: hasText, enabled: canSend, action: submit)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.75)
            )
            .contentShape(.rect(cornerRadius: 22))
        }
    }

    private var selectorRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 8) {
                contextSelector
                Spacer(minLength: 12)
                modelSelector
                reasoningSelector
            }

            VStack(alignment: .leading, spacing: 6) {
                contextSelector
                HStack(spacing: 8) {
                    modelSelector
                    reasoningSelector
                }
            }
        }
    }

    private var contextSelector: some View {
        InlineUpwardSelectorPill(
            systemImage: "sparkles",
            title: store.contextMode,
            accessibilityLabel: "Context mode, \(store.contextMode)",
            options: store.contextModes,
            selected: store.contextMode
        ) { store.contextMode = $0 }
    }

    private var modelSelector: some View {
        InlineUpwardSelectorPill(
            systemImage: "cpu",
            title: store.selectedModel,
            accessibilityLabel: "Model, \(store.selectedModel)",
            options: store.availableModels,
            selected: store.selectedModel
        ) { store.selectedModel = $0 }
    }

    private var reasoningSelector: some View {
        InlineUpwardSelectorPill(
            systemImage: "brain",
            title: store.reasoning.label,
            accessibilityLabel: "Reasoning, \(store.reasoning.label)",
            options: ReasoningEffort.allCases.map(\.label),
            selected: store.reasoning.label
        ) { if let level = ReasoningEffort(label: $0) { store.reasoning = level } }
    }

    private func submit() {
        guard canSend else { return }
        let text = draft
        draft = ""
        store.send(text)
    }
}

/// Liquid-glass circle that fills with pink once there's something to send.
/// Springy native press + a subtle hover lift.
private struct SendButton: View {
    let active: Bool
    let enabled: Bool
    let action: () -> Void

    @State private var hovering = false
    private let pink = Color(red: 1.0, green: 0.42, blue: 0.72)

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.body.weight(.bold))
                .foregroundStyle(active ? Color.white : Color.secondary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(pink).opacity(active ? 1 : 0))
                .background(Color.clear.glassEffect(.regular, in: Circle()))
        }
        .buttonStyle(PressableStyle())
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .scaleEffect(hovering && enabled ? 1.07 : 1.0)
        .animation(.smooth(duration: 0.18), value: active)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovering)
        .help("Send")
        .accessibilityLabel("Send message")
    }
}

private struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let isEnabled: Bool
    let onSubmit: () -> Void

    private let minHeight: CGFloat = 32
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
        textView.textContainerInset = NSSize(width: 0, height: 6)
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
