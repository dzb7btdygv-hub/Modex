import AppKit
import Foundation
import SwiftUI

struct ConversationView: View {
    @Environment(ChatStore.self) private var store

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(store.messages) { message in
                        MessageRow(
                            message: message,
                            activeStatus: activeStatus(for: message),
                            isLast: message.id == store.messages.last?.id
                        )
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
    @Environment(ChatStore.self) private var store
    let message: ChatMessage
    let activeStatus: ChatTaskStatus?
    /// Whether this is the last message in the conversation — gates the
    /// "Regenerate" action to the most recent reply.
    var isLast: Bool = false

    var body: some View {
        switch message.role {
        case .user:
            UserBubble(text: message.text)
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

                // Action row under a settled reply (hidden while streaming).
                if !message.text.isEmpty, !message.pending {
                    AssistantActionBar(
                        text: message.text,
                        canRegenerate: isLast && store.canSend,
                        onRegenerate: { store.resendLastTurn() }
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .system:
            Label(message.text, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.red)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.quaternary, in: .rect(cornerRadius: 10))
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
            // Only parse/render the reasoning body when the disclosure is open —
            // it stays collapsed by default, so this avoids markdown work on every
            // streamed reasoning token for content the user isn't looking at.
            if isExpanded {
                AssistantMarkdownText(text: text, foregroundStyle: Color.secondary)
                    .padding(.top, 4)
            }
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

/// Thin wrapper preserving the existing call sites while delegating rendering to
/// the shared ``MarkdownContent`` engine (headings, lists, quotes, fenced code,
/// inline styling).
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
        MarkdownContent(text: text, foregroundStyle: foregroundStyle)
    }
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

// MARK: - User message

/// The user's prompt bubble with a copy control that fades in on hover. The
/// control's space is always reserved so revealing it never shifts layout.
private struct UserBubble: View {
    let text: String
    @State private var hovering = false

    var body: some View {
        HStack {
            Spacer(minLength: 56)
            VStack(alignment: .trailing, spacing: 2) {
                Text(text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.quaternary, in: .rect(cornerRadius: 16))
                // The copy control's space is always reserved (no layout shift),
                // so keep it permanently hittable and only fade its opacity —
                // moving the cursor onto it never disables it mid-transit.
                MessageCopyButton(text: text)
                    .opacity(hovering ? 1 : 0)
            }
        }
        // Make the whole row — bubble, the 2pt gap, and the copy column — one
        // contiguous hover region so there's no dead strip on the way to the icon.
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: hovering)
    }
}

// MARK: - Assistant actions

/// Persistent action row beneath a settled assistant reply.
private struct AssistantActionBar: View {
    let text: String
    let canRegenerate: Bool
    let onRegenerate: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            MessageCopyButton(text: text)
            if canRegenerate {
                ActionIconButton(systemImage: "arrow.clockwise", help: "Regenerate response", action: onRegenerate)
            }
        }
        .padding(.leading, -5) // nudge the glyphs to align under the body text
    }
}

/// A copy-to-clipboard icon that briefly confirms with a checkmark.
private struct MessageCopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        ActionIconButton(
            systemImage: copied ? "checkmark" : "doc.on.doc",
            help: copied ? "Copied" : "Copy"
        ) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        }
        .animation(.easeInOut(duration: 0.15), value: copied)
    }
}

/// Small secondary icon button sized to a comfortable click target.
private struct ActionIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(hovering ? Color.primary.opacity(0.08) : .clear, in: .rect(cornerRadius: 7))
                .contentShape(.rect(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}
