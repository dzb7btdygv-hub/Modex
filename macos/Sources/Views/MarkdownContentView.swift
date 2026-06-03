import AppKit
import SwiftUI

/// Renders assistant text as lightweight Markdown so replies read as structured
/// content — headings, **bold**/*italic*/`code`, links, bullet and numbered
/// lists, block quotes, and fenced code blocks — instead of one flat paragraph.
///
/// Deliberately small and dependency-free: it covers what the engine actually
/// emits (its instructions keep lists flat and avoid tables), parsing block
/// structure by line and delegating inline styling to `AttributedString`'s
/// Markdown support. Typography uses system text styles and semantic colours per
/// the macOS HIG. The optional `foregroundStyle` lets callers render muted
/// variants (e.g. reasoning text) without changing the block layout.
struct MarkdownContent: View {
    let text: String
    var foregroundStyle: AnyShapeStyle = AnyShapeStyle(Color.primary)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownCache.shared.blocks(for: text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            MarkdownInline.text(text)
                .font(Self.headingFont(level))
                .foregroundStyle(foregroundStyle)
                .fixedSize(horizontal: false, vertical: true)

        case let .paragraph(text):
            MarkdownInline.text(text)
                .font(.body)
                .foregroundStyle(foregroundStyle)
                .fixedSize(horizontal: false, vertical: true)

        case let .bulleted(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        MarkdownInline.text(item)
                            .font(.body)
                            .foregroundStyle(foregroundStyle)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

        case let .numbered(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        MarkdownInline.text(item)
                            .font(.body)
                            .foregroundStyle(foregroundStyle)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

        case let .quote(text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.secondary.opacity(0.4))
                    .frame(width: 3)
                MarkdownInline.text(text)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)

        case let .code(language, code):
            CodeBlockView(language: language, code: code)

        case let .callout(kind, title, content):
            CalloutView(kind: kind, title: title, content: content)

        case .rule:
            Divider()
        }
    }

    private static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title3.weight(.semibold)
        case 2: return .headline
        default: return .subheadline.weight(.semibold)
        }
    }
}

// MARK: - Blocks

enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bulleted([String])
    case numbered([String])
    case quote(String)
    case code(language: String?, code: String)
    case callout(kind: CalloutKind, title: String?, content: String)
    case rule
}

/// Modex-flavored callout styles. The engine is taught (via instructions) to
/// emit these as fenced blocks — ```` ```tip ```` etc. — so it can express
/// itself with coloured, iconographic notes rather than flat text.
enum CalloutKind {
    case note, tip, success, warning, danger

    /// Maps a fenced-block tag to a callout kind, or `nil` if the tag is a real
    /// code language (so normal code fences still render as code).
    static func from(_ tag: String) -> CalloutKind? {
        switch tag.lowercased() {
        case "note", "info": return .note
        case "tip", "hint": return .tip
        case "success", "check", "done": return .success
        case "warning", "caution": return .warning
        case "danger", "important", "error": return .danger
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .note: return "Note"
        case .tip: return "Tip"
        case .success: return "Success"
        case .warning: return "Warning"
        case .danger: return "Important"
        }
    }

    var systemImage: String {
        switch self {
        case .note: return "info.circle.fill"
        case .tip: return "lightbulb.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .danger: return "exclamationmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .note: return .blue
        case .tip, .success: return .green
        case .warning: return .orange
        case .danger: return .red
        }
    }
}

// MARK: - Inline rendering

enum MarkdownInline {
    /// Renders inline Markdown (bold, italic, inline code, links) for a single
    /// block of text, preserving whitespace/newlines and falling back to plain
    /// text if parsing fails.
    static func text(_ string: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        if let attributed = try? AttributedString(markdown: string, options: options) {
            return Text(attributed)
        }
        return Text(string)
    }
}

// MARK: - Fenced code block

/// A fenced code block: optional language tag, a hover-revealed copy control,
/// and horizontally scrollable monospaced content.
struct CodeBlockView: View {
    let language: String?
    let code: String

    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if hovering || copied {
                    Button(action: copy) {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.caption2.weight(.medium))
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy code")
                    .accessibilityLabel(copied ? "Code copied" : "Copy code")
                    .transition(.opacity)
                }
            }
            .frame(minHeight: 18)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider().opacity(0.5)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.75)
        )
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: hovering)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}

// MARK: - Callout

/// A coloured, iconographic note — Modex's way of letting the engine express
/// emphasis. Styled to echo the Liquid-Glass error banners: tinted fill, hairline
/// border, leading symbol. Body is rendered as nested Markdown.
struct CalloutView: View {
    let kind: CalloutKind
    var title: String?
    let content: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: kind.systemImage)
                .font(.callout.weight(.semibold))
                .foregroundStyle(kind.tint)
                .frame(width: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: content.isEmpty ? 0 : 4) {
                Text(title ?? kind.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(kind.tint)
                if !content.isEmpty {
                    MarkdownContent(text: content)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(kind.tint.opacity(0.10), in: .rect(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(kind.tint.opacity(0.28), lineWidth: 0.75)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title ?? kind.title) callout")
    }
}

// MARK: - Parse cache

/// Small main-actor LRU that memoizes `text -> [MarkdownBlock]`.
///
/// During streaming, any store change re-renders the whole conversation, so
/// every message's `MarkdownContent.body` re-runs — without a cache that re-parses
/// every *settled* message's unchanged text on every token (O(messages × tokens)).
/// Keying by the exact text turns those into cache hits; only the one message
/// whose text actually changed is parsed.
@MainActor
final class MarkdownCache {
    static let shared = MarkdownCache()

    private var entries: [String: [MarkdownBlock]] = [:]
    private var order: [String] = []
    private let limit = 256

    func blocks(for text: String) -> [MarkdownBlock] {
        if let hit = entries[text] { return hit }
        let parsed = MarkdownParser.parse(text)
        entries[text] = parsed
        order.append(text)
        if order.count > limit {
            let evicted = order.removeFirst()
            entries.removeValue(forKey: evicted)
        }
        return parsed
    }
}

// MARK: - Parser

enum MarkdownParser {
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = text.components(separatedBy: "\n")
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }

        while index < lines.count {
            let raw = lines[index]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            // Fenced block — consume until the closing fence. The info string
            // may name a code language (```swift) or a Modex callout (```tip),
            // optionally followed by a title (```tip Quick tip).
            if trimmed.hasPrefix("```") {
                flushParagraph()
                let info = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                index += 1 // skip closing fence (no-op if we ran off the end)

                let body = code.joined(separator: "\n")
                let (tag, title) = splitFenceInfo(info)
                if let kind = CalloutKind.from(tag) {
                    blocks.append(.callout(kind: kind, title: title, content: body))
                } else {
                    blocks.append(.code(language: tag.isEmpty ? nil : tag, code: body))
                }
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let level = headingLevel(trimmed) {
                flushParagraph()
                let content = String(trimmed.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: level, text: content))
                index += 1
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(.rule)
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quote: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    let line = lines[index].trimmingCharacters(in: .whitespaces)
                    quote.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quote.joined(separator: "\n")))
                continue
            }

            if isBullet(trimmed) {
                flushParagraph()
                var items: [String] = []
                while index < lines.count, isBullet(lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append(stripBullet(lines[index].trimmingCharacters(in: .whitespaces)))
                    index += 1
                }
                blocks.append(.bulleted(items))
                continue
            }

            if isNumbered(trimmed) {
                flushParagraph()
                var items: [String] = []
                while index < lines.count, isNumbered(lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append(stripNumber(lines[index].trimmingCharacters(in: .whitespaces)))
                    index += 1
                }
                blocks.append(.numbered(items))
                continue
            }

            paragraph.append(trimmed)
            index += 1
        }

        flushParagraph()
        return blocks
    }

    /// Splits a fence info string into its leading tag and an optional title,
    /// e.g. `"tip Quick tip"` → (`"tip"`, `"Quick tip"`), `"swift"` → (`"swift"`, nil).
    private static func splitFenceInfo(_ info: String) -> (tag: String, title: String?) {
        guard let space = info.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
            return (info, nil)
        }
        let tag = String(info[..<space])
        let rest = info[info.index(after: space)...].trimmingCharacters(in: .whitespaces)
        return (tag, rest.isEmpty ? nil : rest)
    }

    private static func headingLevel(_ line: String) -> Int? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix { $0 == "#" }.count
        guard hashes <= 6, line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func isBullet(_ line: String) -> Bool {
        line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")
    }

    private static func stripBullet(_ line: String) -> String {
        String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    }

    /// Matches `1. ` / `12. ` style ordered-list markers (period only, per the
    /// engine's flat-list formatting rules).
    private static func isNumbered(_ line: String) -> Bool {
        guard let dot = line.firstIndex(of: ".") else { return false }
        let digits = line[line.startIndex..<dot]
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return false }
        let afterDot = line.index(after: dot)
        return afterDot < line.endIndex && line[afterDot] == " "
    }

    private static func stripNumber(_ line: String) -> String {
        guard let dot = line.firstIndex(of: ".") else { return line }
        return String(line[line.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
    }
}
