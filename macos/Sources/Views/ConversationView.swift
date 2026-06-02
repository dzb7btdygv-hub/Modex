import Foundation
import SwiftUI

struct ConversationView: View {
    @Environment(ChatStore.self) private var store

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(store.messages) { message in
                        MessageRow(message: message, activeStatus: activeStatus(for: message))
                            .id(message.id)
                    }
                    if let status = standaloneActivityStatus {
                        InlineActivityRow(status: status)
                            .id("activity")
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
            .onChange(of: store.taskStatus) {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    private var conversationStatus: ChatTaskStatus? {
        store.taskStatus.isConversationActivity ? store.taskStatus : nil
    }

    private var hasEmptyPendingAssistant: Bool {
        store.messages.contains { $0.role == .assistant && $0.pending && $0.text.isEmpty }
    }

    private var standaloneActivityStatus: ChatTaskStatus? {
        guard let status = conversationStatus, !hasEmptyPendingAssistant else { return nil }
        return status
    }

    private func activeStatus(for message: ChatMessage) -> ChatTaskStatus? {
        guard message.role == .assistant, message.pending, message.text.isEmpty else { return nil }
        return conversationStatus
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    let activeStatus: ChatTaskStatus?

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
            VStack(alignment: .leading, spacing: 8) {
                if let thinkingText {
                    ThinkingDisclosure(text: thinkingText, isActive: message.pending)
                    if let activeStatus, activeStatus != .thinking {
                        InlineActivityRow(status: activeStatus)
                    }
                } else if isAwaitingReply {
                    InlineActivityRow(status: activeStatus ?? .thinking)
                }

                if let toolOutputText {
                    ToolOutputBlock(text: toolOutputText)
                }

                if !message.text.isEmpty {
                    AssistantMarkdownText(text: message.text)
                }
            }
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

    private var isAwaitingReply: Bool {
        message.text.isEmpty && message.pending
    }

    private var thinkingText: String? {
        let text = message.reasoningSummaryText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? message.reasoningSummaryText
            : message.reasoningText
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    private var toolOutputText: String? {
        guard let text = message.toolOutputText,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return text
    }
}

private struct InlineActivityRow: View {
    let status: ChatTaskStatus

    private var tint: Color {
        switch status.tint {
        case .secondary: return .secondary
        case .success: return .green
        case .warning: return .orange
        case .danger: return .red
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            if status != .thinking {
                Image(systemName: status.systemImage)
                    .font(.callout.weight(.semibold))
                    .frame(width: 18)
            }
            Text(status.conversationLabel)
                .font(.callout.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .shimmering(active: status.isActive)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status, \(status.conversationLabel)")
    }
}

private struct ThinkingDisclosure: View {
    let text: String
    let isActive: Bool

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            AssistantMarkdownText(text: text, foregroundStyle: Color.secondary)
                .padding(.top, 4)
        } label: {
            Text("Thinking")
                .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
            .shimmering(active: isActive)
        }
        .tint(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AssistantMarkdownText: View {
    let text: String
    var foregroundStyle: AnyShapeStyle

    init(text: String) {
        self.text = text
        self.foregroundStyle = AnyShapeStyle(Color.primary)
    }

    init<S: ShapeStyle>(text: String, foregroundStyle: S) {
        self.text = text
        self.foregroundStyle = AnyShapeStyle(foregroundStyle)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Self.blocks(in: text)) { block in
                switch block.kind {
                case .text:
                    Group {
                        if let attributed = Self.markdown(block.text) {
                            Text(attributed)
                        } else {
                            Text(block.text)
                        }
                    }
                    .foregroundStyle(foregroundStyle)
                case .code:
                    CodeBlock(text: block.text)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func markdown(_ text: String) -> AttributedString? {
        try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        )
    }

    private static func blocks(in text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var rest = text[...]

        while let open = rest.range(of: "```") {
            let before = rest[..<open.lowerBound]
            if !before.isEmpty {
                blocks.append(.init(kind: .text, text: String(before)))
            }

            let afterOpen = rest[open.upperBound...]
            guard let close = afterOpen.range(of: "```") else {
                blocks.append(.init(kind: .text, text: String(rest[open.lowerBound...])))
                return blocks
            }

            var code = String(afterOpen[..<close.lowerBound])
            if let newline = code.firstIndex(of: "\n") {
                let firstLine = code[..<newline].trimmingCharacters(in: .whitespacesAndNewlines)
                if firstLine.range(of: #"^[A-Za-z0-9_+#.-]+$"#, options: .regularExpression) != nil {
                    code = String(code[code.index(after: newline)...])
                }
            }
            blocks.append(.init(kind: .code, text: code.trimmingCharacters(in: .newlines)))
            rest = afterOpen[close.upperBound...]
        }

        if !rest.isEmpty {
            blocks.append(.init(kind: .text, text: String(rest)))
        }
        return blocks.isEmpty ? [.init(kind: .text, text: text)] : blocks
    }
}

private struct MarkdownBlock: Identifiable {
    enum Kind {
        case text
        case code
    }

    let id = UUID()
    let kind: Kind
    let text: String
}

private struct CodeBlock: View {
    let text: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.quaternary, in: .rect(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
        )
    }
}

private struct ToolOutputBlock: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Command")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            CodeBlock(text: text.trimmingCharacters(in: .newlines))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
