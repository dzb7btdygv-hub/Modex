import SwiftUI

/// The prompt composer. A thin context pill sits above-left and opens *upward*;
/// beneath it a compact glass rectangle holds ＋ · the text field · send. The
/// box grows upward (up to a cap, then scrolls) as you type more lines, carrying
/// the context pill up with it.
struct PromptDockView: View {
    @Environment(ChatStore.self) private var store
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var hasText: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var canSend: Bool { store.canSend && hasText }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            UpwardSelectorPill(
                systemImage: "sparkles",
                title: store.contextMode,
                options: store.contextModes,
                selected: store.contextMode
            ) { store.contextMode = $0 }
            .padding(.leading, 4)

            HStack(alignment: .bottom, spacing: 10) {
                Button {
                    // Attach context.
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Add context")

                TextField("Ask Modex to build anything…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .lineLimit(1...8)
                    .focused($focused)
                    .disabled(!store.isReady)
                    .onSubmit(submit)
                    .frame(minHeight: 32)

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
            .onTapGesture { focused = true }
        }
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
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(active ? Color.white : Color.secondary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(pink).opacity(active ? 1 : 0))
                .background(Color.clear.glassEffect(.regular, in: Circle()))
        }
        .buttonStyle(PressableStyle())
        .keyboardShortcut(.return, modifiers: [])
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .scaleEffect(hovering && enabled ? 1.07 : 1.0)
        .animation(.smooth(duration: 0.18), value: active)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovering)
        .help("Send")
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
