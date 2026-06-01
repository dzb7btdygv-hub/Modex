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
