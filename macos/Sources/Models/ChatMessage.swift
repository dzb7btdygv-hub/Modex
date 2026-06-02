import Foundation

enum MessageRole: String, Codable {
    case user
    case assistant
    case system
}

struct ChatMessage: Identifiable, Codable, Hashable {
    let id: String
    let role: MessageRole
    var text: String
    var pending: Bool = false
}

/// A row in the sidebar's "Recent Chats" list.
struct RecentChat: Identifiable, Hashable {
    let id: String
    let title: String
    let timeAgo: String
}

/// Unified selection model for the NavigationSplitView sidebar so a single
/// `List(selection:)` can span both the top-level destinations and recent chats.
enum SidebarItem: Hashable {
    case destination(String)
    case recent(String)
}

/// Codex sandbox mode exposed by the composer permission selector.
enum PermissionMode: String, CaseIterable, Identifiable, Codable {
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
enum ReasoningEffort: String, CaseIterable, Identifiable, Codable {
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

enum ChatTaskStatus: Equatable {
    case idle
    case startingCodex
    case connecting
    case initializing
    case ready
    case creatingThread
    case sendingMessage
    case thinking
    case streamingResponse
    case runningCommand
    case editingFiles
    case waitingForPermission
    case cancelling
    case completed
    case failed(String)
    case cancelled

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .startingCodex: return "Starting Codex"
        case .connecting: return "Connecting"
        case .initializing: return "Initializing"
        case .ready: return "Ready"
        case .creatingThread: return "Creating chat"
        case .sendingMessage: return "Sending"
        case .thinking: return "Thinking"
        case .streamingResponse: return "Streaming"
        case .runningCommand: return "Running command"
        case .editingFiles: return "Editing files"
        case .waitingForPermission: return "Waiting for permission"
        case .cancelling: return "Cancelling"
        case .completed: return "Completed"
        case .failed(let message): return message.isEmpty ? "Failed" : message
        case .cancelled: return "Cancelled"
        }
    }

    var systemImage: String {
        switch self {
        case .idle, .ready, .completed: return "checkmark.circle"
        case .startingCodex, .connecting, .initializing: return "bolt.horizontal.circle"
        case .creatingThread, .sendingMessage: return "paperplane"
        case .thinking: return "brain"
        case .streamingResponse: return "text.bubble"
        case .runningCommand: return "terminal"
        case .editingFiles: return "doc.text"
        case .waitingForPermission: return "hand.raised"
        case .cancelling: return "stop.circle"
        case .failed: return "exclamationmark.triangle"
        case .cancelled: return "xmark.circle"
        }
    }

    var isActive: Bool {
        switch self {
        case .startingCodex, .connecting, .initializing, .creatingThread,
             .sendingMessage, .thinking, .streamingResponse, .runningCommand,
             .editingFiles, .waitingForPermission, .cancelling:
            return true
        case .idle, .ready, .completed, .failed, .cancelled:
            return false
        }
    }

    var tint: StatusTint {
        switch self {
        case .failed: return .danger
        case .cancelling, .cancelled: return .warning
        case .completed, .ready: return .success
        default: return .secondary
        }
    }
}

enum StatusTint {
    case secondary
    case success
    case warning
    case danger
}
