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
