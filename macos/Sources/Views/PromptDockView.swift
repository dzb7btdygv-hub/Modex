import SwiftUI

/// The prompt composer — the one custom interactive surface the brief permits.
/// A single rounded glass field: the input on top, a tidy control row beneath
/// (＋ · Smart Context … model · send), grouped in a `GlassEffectContainer`.
struct PromptDockView: View {
    @Environment(ChatStore.self) private var store
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Ask Modex to build anything…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .lineLimit(1...7)
                    .focused($focused)
                    .disabled(!store.isReady)
                    .onSubmit(submit)
                    .padding(.horizontal, 6)
                    .padding(.top, 4)

                HStack(spacing: 8) {
                    Button {
                        // Attach context.
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.glass)
                    .clipShape(Circle())
                    .help("Add context")

                    Menu {
                        Button("Smart Context", systemImage: "sparkles") {}
                        Button("Current File") {}
                        Button("Whole Project") {}
                    } label: {
                        Label("Smart Context", systemImage: "sparkles")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.glass)
                    .fixedSize()

                    Spacer()

                    Menu {
                        Button("GPT-5.5 (High)") {}
                        Button("GPT-5.5") {}
                        Button("Fast") {}
                    } label: {
                        Label("GPT-5.5 (High)", systemImage: "cpu")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.glass)
                    .fixedSize()

                    Button(action: submit) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .bold))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.glassProminent)
                    .clipShape(Circle())
                    .disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: [])
                    .help("Send")
                }
            }
            .padding(14)
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 0.75)
        )
        .contentShape(.rect(cornerRadius: 26))
        .onTapGesture { focused = true }
    }

    private var canSend: Bool {
        store.canSend && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        guard canSend else { return }
        let text = draft
        draft = ""
        store.send(text)
    }
}
