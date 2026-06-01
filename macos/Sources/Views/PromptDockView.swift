import SwiftUI

/// The prompt composer — the one genuinely custom interactive surface the brief
/// permits. A single `regular` glass field holding standard system controls,
/// grouped in a `GlassEffectContainer` so they blend as one element.
struct PromptDockView: View {
    @Environment(ChatStore.self) private var store
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(alignment: .leading, spacing: 14) {
                TextField("Ask Modex to build anything…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineLimit(1...6)
                    .focused($focused)
                    .disabled(!store.isReady)
                    .onSubmit(submit)

                HStack(spacing: 8) {
                    Button {
                        // Attach context.
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.glass)
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
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: [])
                    .help("Send")
                }
            }
            .padding(16)
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
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
