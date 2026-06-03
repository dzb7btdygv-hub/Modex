import Foundation

/// A composer slash command. Typing "/" in an empty-ish prompt opens a palette
/// that filters these by their token (`/c` → `/co` → `/com` → `/compact`). Each
/// is a discrete action the app performs locally — none of this text is sent to
/// the model.
struct SlashCommand: Identifiable, Hashable {
    enum Action: Hashable {
        case compact
        case newChat
        case openSettings
        case setPermission(PermissionMode)
    }

    /// The command word without its leading slash, e.g. "compact".
    let token: String
    let title: String
    let subtitle: String
    let systemImage: String
    let action: Action

    var id: String { token }
    var display: String { "/" + token }

    /// The commands offered, in palette order.
    static let all: [SlashCommand] = [
        SlashCommand(token: "compact", title: "Compact context",
                     subtitle: "Summarize the conversation to free up the context window",
                     systemImage: "arrow.down.right.and.arrow.up.left", action: .compact),
        SlashCommand(token: "new", title: "New chat",
                     subtitle: "Start a fresh conversation",
                     systemImage: "square.and.pencil", action: .newChat),
        SlashCommand(token: "read", title: "Read only",
                     subtitle: "Switch to read-only access",
                     systemImage: "lock", action: .setPermission(.readOnly)),
        SlashCommand(token: "write", title: "Write access",
                     subtitle: "Let Codex edit files in the workspace",
                     systemImage: "pencil", action: .setPermission(.write)),
        SlashCommand(token: "full", title: "Full access",
                     subtitle: "Allow Codex unrestricted access — use with care",
                     systemImage: "exclamationmark.triangle", action: .setPermission(.fullAccess)),
        SlashCommand(token: "settings", title: "Settings",
                     subtitle: "Appearance, accent colour, and behaviour",
                     systemImage: "gearshape", action: .openSettings),
    ]

    /// Commands whose token starts with the typed query (case-insensitive). An
    /// empty query (just "/") returns everything. A query containing whitespace
    /// returns nothing — the user has moved past the command into a real prompt.
    static func matches(for query: String) -> [SlashCommand] {
        guard !query.contains(where: \.isWhitespace) else { return [] }
        let needle = query.lowercased()
        guard !needle.isEmpty else { return all }
        return all.filter { $0.token.hasPrefix(needle) }
    }

    /// If `text` is a lone slash token (`/`, `/com`, …) with nothing after it,
    /// returns the query after the slash. Otherwise nil (not in command mode).
    static func query(in text: String) -> String? {
        guard text.hasPrefix("/") else { return nil }
        let rest = text.dropFirst()
        guard !rest.contains(where: \.isWhitespace), !rest.contains("\n") else { return nil }
        return String(rest)
    }
}
