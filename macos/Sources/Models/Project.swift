import Foundation

/// A first-class workspace. A project is the durable object a user works inside
/// — not just a transient folder path. It owns its identity, its defaults
/// (access mode, model, reasoning), and a cached git branch so the UI can show
/// context instantly without blocking on `git`.
///
/// Chats reference their owning project by ``Project/id`` (see
/// `PersistedChat.projectId`); that inverse relationship is the single source of
/// truth for "which chats belong to this project", so the project itself does
/// not duplicate a list of thread ids.
struct Project: Identifiable, Codable, Hashable {
    /// Stable identity, independent of the folder path so a project survives a
    /// rename/move (the path is updated, the id is not).
    let id: String
    /// Display name — defaults to the folder's last path component.
    var name: String
    /// Absolute, standardized folder path on disk.
    var path: String
    var createdAt: Date
    var lastOpenedAt: Date

    /// Remembered defaults — seed a new chat opened in this project and track
    /// the last-used selection so reopening the project restores context.
    var defaultPermission: PermissionMode
    var lastModel: String?
    var lastReasoning: ReasoningEffort

    /// Last-known git branch, cached so the top bar shows it immediately on
    /// reopen. Refreshed in the background; never blocks. `nil` = unknown / not
    /// a repo.
    var cachedGitBranch: String?

    init(
        id: String,
        name: String,
        path: String,
        createdAt: Date,
        lastOpenedAt: Date,
        defaultPermission: PermissionMode = .readOnly,
        lastModel: String? = nil,
        lastReasoning: ReasoningEffort = .high,
        cachedGitBranch: String? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
        self.defaultPermission = defaultPermission
        self.lastModel = lastModel
        self.lastReasoning = lastReasoning
        self.cachedGitBranch = cachedGitBranch
    }

    /// Name to show in the UI, falling back to the path if unnamed.
    var displayName: String { name.isEmpty ? path : name }

    var folderURL: URL { URL(fileURLWithPath: path) }

    /// Whether the backing folder still exists on disk. Cheap; safe to call from
    /// the main actor.
    var folderExists: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: - Migration-tolerant decoding
    //
    // Projects persisted before this model gained defaults only carry
    // {id, path, name, lastOpenedAt}. Decoding must not throw on the missing
    // keys — otherwise the whole session reads as corrupt and gets quarantined.
    // Every field added after the original ships with a sensible fallback.

    enum CodingKeys: String, CodingKey {
        case id, name, path, createdAt, lastOpenedAt
        case defaultPermission, lastModel, lastReasoning, cachedGitBranch
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        path = try container.decode(String.self, forKey: .path)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        let lastOpened = try container.decodeIfPresent(Date.self, forKey: .lastOpenedAt) ?? Date()
        lastOpenedAt = lastOpened
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? lastOpened
        defaultPermission = try container.decodeIfPresent(PermissionMode.self, forKey: .defaultPermission) ?? .readOnly
        lastModel = try container.decodeIfPresent(String.self, forKey: .lastModel)
        lastReasoning = try container.decodeIfPresent(ReasoningEffort.self, forKey: .lastReasoning) ?? .high
        cachedGitBranch = try container.decodeIfPresent(String.self, forKey: .cachedGitBranch)
    }
}
