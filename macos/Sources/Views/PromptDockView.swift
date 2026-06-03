import AppKit
import SwiftUI

/// Keys the composer's text view forwards to SwiftUI so the slash-command
/// palette can be driven from the keyboard (↑/↓ to move, ⏎/⇥ to pick, ⎋ to
/// dismiss) while normal typing still falls through to the field editor.
enum ComposerKey { case up, down, submit, tab, escape }

/// The prompt composer. A thin permission pill sits above-left and opens upward;
/// beneath it a compact glass rectangle holds the text field · send/stop. Typing
/// "/" grows a liquid-glass command palette upward out of the bar.
struct PromptDockView: View {
    @Environment(ChatStore.self) private var store
    @Environment(ThemeStore.self) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft = ""
    @State private var textHeight: CGFloat = 32

    // Selector open-states are lifted here so a ViewThatFits branch swap can't
    // tear down an open picker mid-interaction.
    @State private var permissionOpen = false
    @State private var modelOpen = false
    @State private var reasoningOpen = false

    // Slash-command palette state.
    @State private var commandIndex = 0
    @State private var paletteDismissed = false

    private var hasText: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var canSend: Bool { store.canSend && hasText }
    private var canStop: Bool { store.turnRunning }

    private var commandMatches: [SlashCommand] {
        guard let query = SlashCommand.query(in: draft) else { return [] }
        return SlashCommand.matches(for: query)
    }
    private var showPalette: Bool { !paletteDismissed && !commandMatches.isEmpty }
    private var clampedCommandIndex: Int {
        guard !commandMatches.isEmpty else { return 0 }
        return min(max(0, commandIndex), commandMatches.count - 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showPalette {
                SlashCommandPalette(
                    commands: commandMatches,
                    selectedIndex: clampedCommandIndex,
                    accent: theme.accentColor,
                    onSelect: run,
                    onHover: { commandIndex = $0 }
                )
                .padding(.horizontal, 4)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            selectorRow
                .padding(.horizontal, 8)

            HStack(alignment: .center, spacing: 8) {
                ZStack(alignment: .leading) {
                    ComposerTextView(
                        text: $draft,
                        height: $textHeight,
                        isEnabled: store.isReady,
                        onKey: handleKey
                    )

                    if !hasText {
                        Text("Ask Modex to build anything…")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .allowsHitTesting(false)
                    }
                }
                .frame(minHeight: 30)
                .frame(height: textHeight, alignment: .center)

                SendButton(
                    active: canSend || canStop,
                    enabled: canSend || canStop,
                    isRunning: store.turnRunning,
                    accent: theme.accentColor,
                    action: store.turnRunning ? store.cancelTurn : { _ = submit() }
                )
            }
            // Asymmetric by design: text needs a generous left inset; the round
            // send button nests into the stadium's right cap with a margin equal
            // to its vertical inset (6) so it reads as concentric, not cramped.
            .padding(.leading, 16)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .frame(minHeight: 42)
            .glassEffect(.regular, in: .rect(cornerRadius: 21))
            .overlay(
                RoundedRectangle(cornerRadius: 21, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
            )
            .contentShape(.rect(cornerRadius: 21))
        }
        .animation(ModexMotion.micro(reduceMotion), value: showPalette)
        .animation(ModexMotion.micro(reduceMotion), value: commandMatches)
        .onChange(of: draft) { _, _ in
            // Re-show the palette after a typed change and re-anchor the
            // selection to the top of the freshly filtered list.
            paletteDismissed = false
            commandIndex = 0
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
            isOpen: $permissionOpen,
            onSelect: store.selectPermission
        )
    }

    private var modelSelector: some View {
        InlineUpwardSelectorPill(
            systemImage: "cpu",
            title: store.selectedModel,
            accessibilityLabel: "Model, \(store.selectedModel)",
            options: store.availableModels,
            selected: store.selectedModel,
            isOpenBinding: $modelOpen
        ) { store.selectModel($0) }
    }

    private var reasoningSelector: some View {
        InlineUpwardSelectorPill(
            systemImage: "brain",
            title: store.reasoning.label,
            accessibilityLabel: "Reasoning, \(store.reasoning.label)",
            options: ReasoningEffort.allCases.map(\.label),
            selected: store.reasoning.label,
            isOpenBinding: $reasoningOpen
        ) { if let level = ReasoningEffort(label: $0) { store.selectReasoning(level) } }
    }

    // MARK: - Actions

    /// Routes a keystroke forwarded from the text view. Returns whether it was
    /// handled (so the field editor doesn't also act on it).
    private func handleKey(_ key: ComposerKey) -> Bool {
        if showPalette {
            let count = commandMatches.count
            switch key {
            case .up:
                commandIndex = (clampedCommandIndex - 1 + count) % count
                return true
            case .down:
                commandIndex = (clampedCommandIndex + 1) % count
                return true
            case .submit, .tab:
                run(commandMatches[clampedCommandIndex])
                return true
            case .escape:
                paletteDismissed = true
                return true
            }
        }
        // No palette: only Return is special; everything else falls through.
        switch key {
        case .submit: return submit()
        default: return false
        }
    }

    /// Sends the draft, clearing it only if the engine accepted it (so a rejected
    /// send keeps the user's text). While a turn runs, Return stops it — mirroring
    /// the send button. Returns whether the keystroke was handled.
    @discardableResult
    private func submit() -> Bool {
        if store.turnRunning {
            store.cancelTurn()
            return true
        }
        guard canSend else { return false }
        if store.send(draft) {
            draft = ""
            return true
        }
        return false
    }

    private func run(_ command: SlashCommand) {
        draft = ""
        commandIndex = 0
        paletteDismissed = false
        switch command.action {
        case .compact: store.compactContext()
        case .newChat: store.startNewChat()
        case .openSettings: theme.isSettingsPresented = true
        case .setPermission(let mode): store.selectPermission(mode)
        }
    }
}

// MARK: - Slash-command palette

/// The liquid-glass command list that grows upward out of the composer. The
/// selected row is washed in the accent ("faded pink"); ↑/↓ or hover move it,
/// ⏎/⇥ or click run it.
private struct SlashCommandPalette: View {
    let commands: [SlashCommand]
    let selectedIndex: Int
    let accent: Color
    let onSelect: (SlashCommand) -> Void
    let onHover: (Int) -> Void

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                SlashCommandRow(
                    command: command,
                    isSelected: index == selectedIndex,
                    accent: accent,
                    onTap: { onSelect(command) },
                    onHover: { if $0 { onHover(index) } }
                )
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Slash commands")
    }
}

private struct SlashCommandRow: View {
    let command: SlashCommand
    let isSelected: Bool
    let accent: Color
    let onTap: () -> Void
    let onHover: (Bool) -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: command.systemImage)
                    .font(.callout)
                    .foregroundStyle(isSelected ? accent : .secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(command.title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(command.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(command.display)
                    .font(.caption.monospaced())
                    .foregroundStyle(isSelected ? accent : .secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? accent.opacity(0.16) : Color.clear, in: .rect(cornerRadius: 10))
            .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover(perform: onHover)
        .accessibilityLabel("\(command.title), \(command.display)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Send button

/// Liquid-glass circle that fills with the accent once there's something to send
/// or stop. Springy native press + a subtle hover lift (both honor Reduce Motion).
private struct SendButton: View {
    let active: Bool
    let enabled: Bool
    let isRunning: Bool
    let accent: Color
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    private var filled: Bool { active || isRunning }

    var body: some View {
        Button(action: action) {
            Image(systemName: isRunning ? "stop.fill" : "arrow.up")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(filled ? Color.white : Color.secondary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(accent).opacity(filled ? 1 : 0))
                .background(Color.clear.glassEffect(.regular, in: Circle()))
        }
        .buttonStyle(PressableStyle())
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .scaleEffect(ModexMotion.hoverScale(reduceMotion, hovering && enabled ? 1.07 : 1.0))
        .animation(ModexMotion.micro(reduceMotion), value: filled)
        .animation(ModexMotion.micro(reduceMotion), value: isRunning)
        .animation(ModexMotion.spring(reduceMotion), value: hovering)
        .help(isRunning ? "Stop" : "Send")
        .accessibilityLabel(isRunning ? "Stop response" : "Send message")
    }
}

private struct PermissionSelector: View {
    let selected: PermissionMode
    @Binding var isOpen: Bool
    let onSelect: (PermissionMode) -> Void

    @State private var hovering = false

    private var tint: Color {
        selected == .fullAccess ? .modexDanger : .secondary
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
            .overlay(Capsule().strokeBorder(selected == .fullAccess ? Color.modexDanger.opacity(0.42) : .clear, lineWidth: 0.75))
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

    private var tint: Color {
        mode == .fullAccess ? .modexDanger : .primary
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
    let onKey: (ComposerKey) -> Bool

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
        textView.onKey = onKey
        textView.isRichText = false
        textView.isEditable = isEnabled
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .preferredFont(forTextStyle: .body, options: [:])
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        // Symmetric inset large enough that a single line fills the min height,
        // so the text sits vertically centred rather than riding high.
        textView.textContainerInset = NSSize(width: 0, height: 7)
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
        textView.onKey = onKey
        textView.setAccessibilityLabel("Message")
        textView.setAccessibilityPlaceholderValue("Ask Modex to build anything")
        context.coordinator.parent = self
        context.coordinator.updateHeight()
        scrollView.hasVerticalScroller = height >= maxHeight

        // Place the keyboard in the composer the first time it's ready, so the
        // user can type immediately on launch / after the engine connects — but
        // only if nothing else currently owns focus (don't yank from a popover).
        if isEnabled, !context.coordinator.hasAutofocused, let window = textView.window {
            let firstResponder = window.firstResponder
            let focusIsFree = firstResponder == nil || firstResponder === window
            if focusIsFree, window.attachedSheet == nil {
                context.coordinator.hasAutofocused = true
                DispatchQueue.main.async { window.makeFirstResponder(textView) }
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: SubmitTextView?
        /// Auto-focus the composer only once, so we never yank focus back from a
        /// popover/menu the user has since opened.
        var hasAutofocused = false

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
    var onKey: ((ComposerKey) -> Bool)?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76

        if isReturn {
            if event.modifierFlags.contains(.shift) {
                insertNewlineIgnoringFieldEditor(nil)
            } else if onKey?(.submit) != true {
                // Not handled (nothing to send, palette closed) — fall through to
                // normal field-editor behavior instead of swallowing the key.
                super.keyDown(with: event)
            }
            return
        }

        switch event.keyCode {
        case 126 where onKey?(.up) == true: return     // ↑
        case 125 where onKey?(.down) == true: return    // ↓
        case 53 where onKey?(.escape) == true: return   // ⎋
        case 48 where onKey?(.tab) == true: return      // ⇥
        default: break
        }

        super.keyDown(with: event)
    }
}

/// Springy press feedback for custom glass buttons (honors Reduce Motion).
private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PressableBody(configuration: configuration)
    }

    private struct PressableBody: View {
        let configuration: Configuration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? (reduceMotion ? 1.0 : 0.9) : 1)
                .animation(ModexMotion.spring(reduceMotion), value: configuration.isPressed)
        }
    }
}
