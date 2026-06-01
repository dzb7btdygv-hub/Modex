import SwiftUI

struct ConversationView: View {
    @Environment(ChatStore.self) private var store

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(store.messages) { message in
                        MessageRow(message: message)
                            .id(message.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
            }
            .scrollContentBackground(.hidden)
            .onChange(of: store.messages.count) {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }
}

private struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 56)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.quaternary, in: .rect(cornerRadius: 16))
            }
        case .assistant:
            Text(displayText)
                .foregroundStyle(message.text.isEmpty && message.pending ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .system:
            Label(message.text, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.red)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.quaternary, in: .rect(cornerRadius: 12))
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var displayText: String {
        message.text.isEmpty && message.pending ? "Thinking…" : message.text
    }
}
