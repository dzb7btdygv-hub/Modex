import Foundation

enum MessageRole {
    case user
    case assistant
    case system
}

struct ChatMessage: Identifiable {
    let id: String
    let role: MessageRole
    var text: String
    var pending: Bool = false
}

/// A row in the sidebar's "Recent Chats" list.
struct RecentChat: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let timeAgo: String
}

/// Unified selection model for the NavigationSplitView sidebar so a single
/// `List(selection:)` can span both the top-level destinations and recent chats.
enum SidebarItem: Hashable {
    case destination(String)
    case recent(UUID)
}

/// Codex sandbox mode exposed by the composer permission selector.
enum PermissionMode: String, CaseIterable, Identifiable {
    case readOnly
    case write
    case fullAccess

    var id: String { rawValue }

    var label: String {
        switch self {
        case .readOnly: return "Read only"
        case .write: return "Write"
        case .fullAccess: return "Full access"
        }
    }

    var systemImage: String {
        switch self {
        case .readOnly: return "lock"
        case .write: return "pencil"
        case .fullAccess: return "exclamationmark.triangle"
        }
    }

    var sandboxMode: String {
        switch self {
        case .readOnly: return "read-only"
        case .write: return "workspace-write"
        case .fullAccess: return "danger-full-access"
        }
    }

    func sandboxPolicy(folderPath: String?) -> [String: Any] {
        switch self {
        case .readOnly:
            return ["type": "readOnly", "networkAccess": false]
        case .write:
            return [
                "type": "workspaceWrite",
                "networkAccess": false,
                "writableRoots": folderPath.map { [$0] } ?? [],
            ]
        case .fullAccess:
            return ["type": "dangerFullAccess"]
        }
    }
}

/// Reasoning effort exposed by the top-bar selector (Low → xHigh).
enum ReasoningEffort: String, CaseIterable, Identifiable {
    case low, medium, high, xhigh

    var id: String { rawValue }

    var label: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "xHigh"
        }
    }

    init?(label: String) {
        guard let match = Self.allCases.first(where: { $0.label == label }) else { return nil }
        self = match
    }
}
