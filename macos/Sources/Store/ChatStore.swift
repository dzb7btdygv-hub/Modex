import Foundation
import Observation
import OSLog

/// Drives the chat experience: boots the Codex engine, manages the RPC
/// connection and thread, sends turns, and accumulates streamed output.
/// Native counterpart of the logic in the former `App.tsx`.
@MainActor
@Observable
final class ChatStore {
    private static let newChatTitle = "New Chat"

    private(set) var messages: [ChatMessage] = []
    private(set) var status: String = "Starting Codex…"
    private(set) var isReady = false
    private(set) var turnRunning = false

    // MARK: - User selections (top-bar model + reasoning, composer context)
    var selectedModel = "GPT-5.5"
    let availableModels = ["GPT-5.5", "GPT-5.5 Codex", "GPT-5 mini"]
    var reasoning: ReasoningEffort = .high
    private(set) var selectedPermission: PermissionMode = .readOnly
    private(set) var selectedFolderPath: String?
    private(set) var selectedFolderName = "Choose folder"
    private(set) var gitBranch: String?
    private(set) var chatTitle = ChatStore.newChatTitle
    private(set) var recentChats: [RecentChat] = []
    private(set) var selectedChatId: String?

    let supervisor = CodexSupervisor()
    private let persistence = LocalSessionPersistence()
    private var rpc: CodexRPCClient?
    private var threadId: String?
    private var booted = false
    private var chatRecords: [PersistedChat] = []
    private var projectRecords: [PersistedProject] = []
    private var selectedProjectId: String?

    var canSend: Bool { isReady && !turnRunning }

    init() {
        restoreSession()
    }

    // MARK: - Boot

    func bootIfNeeded() {
        guard !booted else { return }
        booted = true
        Task { await boot() }
    }

    private func boot() async {
        do {
            let wsURL = try await supervisor.start()
            status = "Connecting to Codex…"

            let client = CodexRPCClient(
                url: wsURL,
                onNotification: { [weak self] method, params in
                    self?.handle(method: method, params: params)
                },
                onClose: { [weak self] reason in
                    guard let self else { return }
                    self.rpc = nil
                    self.threadId = nil
                    self.isReady = false
                    self.turnRunning = false
                    self.status = reason
                }
            )
            rpc = client

            _ = try await client.request("initialize", params: [
                "clientInfo": ["name": "modex", "title": "Modex", "version": "0.1.0"],
                "capabilities": ["experimentalApi": true, "requestAttestation": false],
            ])

            isReady = true
            status = "Ready."
        } catch {
            isReady = false
            let message = error.localizedDescription
            status = message
            appendSystem(message)
        }
    }

    // MARK: - Chats

    func startNewChat() {
        guard !turnRunning else { return }
        if messages.isEmpty, threadId == nil, chatTitle == Self.newChatTitle, selectedChatId != nil {
            return
        }

        persistCurrentChat()
        let chat = makeChat()
        chatRecords.insert(chat, at: 0)
        selectedChatId = chat.id
        apply(chat)
        refreshRecentChats()
        saveSession()
    }

    func selectChat(_ id: String) {
        guard !turnRunning, id != selectedChatId, let chat = chatRecords.first(where: { $0.id == id }) else {
            return
        }

        persistCurrentChat()
        selectedChatId = id
        apply(chat)
        refreshRecentChats()
        saveSession()
    }

    // MARK: - Sending

    func send(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let rpc, !turnRunning else { return }

        ensureActiveChat()
        turnRunning = true
        status = threadId == nil ? "Starting chat…" : "Thinking…"
        messages.append(ChatMessage(id: "user-\(UUID().uuidString)", role: .user, text: text))
        updateTitleIfNeeded(from: text)
        persistCurrentChat()
        saveSession()

        Task {
            do {
                let threadId = try await ensureThread(rpc)
                status = "Thinking…"
                _ = try await rpc.request("turn/start", params: turnStartParams(threadId: threadId, text: text))
            } catch {
                turnRunning = false
                status = "Could not send message."
                appendSystem(error.localizedDescription)
            }
        }
    }

    private func ensureThread(_ rpc: CodexRPCClient) async throws -> String {
        if let threadId { return threadId }
        let result = try await rpc.request("thread/start", params: threadStartParams())
        guard
            let dict = result as? [String: Any],
            let thread = dict["thread"] as? [String: Any],
            let id = thread["id"] as? String
        else {
            throw CodexError.message("Codex did not return a thread id.")
        }
        threadId = id
        persistCurrentChat()
        saveSession()
        return id
    }

    func selectPermission(_ permission: PermissionMode) {
        selectedPermission = permission
        persistCurrentChat()
        saveSession()
        updateThreadSettingsIfNeeded()
    }

    func selectModel(_ model: String) {
        selectedModel = model
        persistCurrentChat()
        saveSession()
        updateThreadSettingsIfNeeded()
    }

    func selectReasoning(_ effort: ReasoningEffort) {
        reasoning = effort
        persistCurrentChat()
        saveSession()
        updateThreadSettingsIfNeeded()
    }

    func selectFolder(_ url: URL) {
        let folder = url.standardizedFileURL
        selectedProjectId = upsertProject(for: folder)
        selectedFolderPath = folder.path
        selectedFolderName = folder.lastPathComponent.isEmpty ? folder.path : folder.lastPathComponent
        gitBranch = nil
        persistCurrentChat()
        saveSession()
        updateThreadSettingsIfNeeded()

        Task {
            let branch = await Self.gitBranch(at: folder)
            if selectedFolderPath == folder.path {
                gitBranch = branch
            }
        }
    }

    private func threadStartParams() -> [String: Any] {
        var params: [String: Any] = [
            "approvalPolicy": "never",
            "sandbox": selectedPermission.sandboxMode,
            "ephemeral": false,
            "model": selectedModel,
            "serviceName": "modex",
        ]
        if let selectedFolderPath {
            params["cwd"] = selectedFolderPath
            params["runtimeWorkspaceRoots"] = [selectedFolderPath]
        }
        return params
    }

    private func turnStartParams(threadId: String, text: String) -> [String: Any] {
        var params: [String: Any] = [
            "threadId": threadId,
            "input": [["type": "text", "text": text, "text_elements": []]],
            "model": selectedModel,
            "effort": reasoning.rawValue,
            "sandboxPolicy": selectedPermission.sandboxPolicy(folderPath: selectedFolderPath),
        ]
        if let selectedFolderPath {
            params["cwd"] = selectedFolderPath
            params["runtimeWorkspaceRoots"] = [selectedFolderPath]
        }
        return params
    }

    private func updateThreadSettingsIfNeeded() {
        guard let rpc, let threadId, !turnRunning else { return }

        var params: [String: Any] = [
            "threadId": threadId,
            "model": selectedModel,
            "effort": reasoning.rawValue,
            "sandboxPolicy": selectedPermission.sandboxPolicy(folderPath: selectedFolderPath),
        ]
        if let selectedFolderPath {
            params["cwd"] = selectedFolderPath
        }

        Task {
            _ = try? await rpc.request("thread/settings/update", params: params)
        }
    }

    private func updateTitleIfNeeded(from text: String) {
        guard chatTitle == Self.newChatTitle else { return }
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        chatTitle = firstLine.count > 54 ? "\(firstLine.prefix(51))..." : firstLine
    }

    private static func gitBranch(at folder: URL) async -> String? {
        await Task.detached {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", folder.path, "branch", "--show-current"]
            process.standardOutput = output
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return nil }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let branch = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return branch.isEmpty ? nil : branch
            } catch {
                return nil
            }
        }.value
    }

    // MARK: - Notification handling (mirrors handleNotification in App.tsx)

    private func handle(method: String, params: [String: Any]?) {
        switch method {
        case "item/started":
            guard
                let item = params?["item"] as? [String: Any],
                item["type"] as? String == "agentMessage",
                let itemId = item["id"] as? String
            else { return }
            let id = "assistant-\(itemId)"
            if !messages.contains(where: { $0.id == id }) {
                messages.append(ChatMessage(id: id, role: .assistant, text: "", pending: true))
            }

        case "item/agentMessage/delta":
            guard
                let itemId = params?["itemId"] as? String,
                let delta = params?["delta"] as? String
            else { return }
            let id = "assistant-\(itemId)"
            if let index = messages.firstIndex(where: { $0.id == id }) {
                messages[index].text += delta
                messages[index].pending = true
            } else {
                messages.append(ChatMessage(id: id, role: .assistant, text: delta, pending: true))
            }

        case "item/completed":
            guard
                let item = params?["item"] as? [String: Any],
                item["type"] as? String == "agentMessage",
                let itemId = item["id"] as? String
            else { return }
            let id = "assistant-\(itemId)"
            if let index = messages.firstIndex(where: { $0.id == id }) {
                messages[index].text = item["text"] as? String ?? messages[index].text
                messages[index].pending = false
            }
            persistCurrentChat()
            saveSession()

        case "turn/completed":
            turnRunning = false
            status = "Ready."
            for index in messages.indices where messages[index].pending {
                messages[index].pending = false
            }
            if let turn = params?["turn"] as? [String: Any], let error = turn["error"] {
                appendSystem(Self.describe(error))
            } else {
                persistCurrentChat()
                saveSession()
            }

        case "error":
            turnRunning = false
            status = "Codex returned an error."
            appendSystem(Self.describe(params?["error"] ?? params as Any))

        default:
            break
        }
    }

    private func appendSystem(_ text: String) {
        ensureActiveChat()
        messages.append(ChatMessage(id: "system-\(UUID().uuidString)", role: .system, text: text))
        persistCurrentChat()
        saveSession()
    }

    private static func describe(_ error: Any) -> String {
        if let text = error as? String { return text }
        if let dict = error as? [String: Any] {
            if let message = dict["message"] as? String { return message }
            if let nested = dict["error"] { return describe(nested) }
        }
        return "Unknown error."
    }

    func flushPersistence() {
        persistCurrentChat()
        saveSession()
    }

    func shutdown() {
        persistCurrentChat()
        persistence.saveImmediately(snapshot())
        let client = rpc
        rpc = nil
        threadId = nil
        isReady = false
        turnRunning = false
        booted = false
        status = "Starting Codex…"
        Task { await client?.close() }
        supervisor.stop()
    }

    // MARK: - Local session persistence

    private func restoreSession() {
        guard let stored = persistence.load() else {
            refreshRecentChats()
            return
        }

        selectedModel = availableModels.contains(stored.selectedModel) ? stored.selectedModel : selectedModel
        reasoning = stored.reasoning
        selectedPermission = stored.permission
        projectRecords = stored.projects
        selectedProjectId = stored.selectedProjectId ?? stored.lastActiveProjectId
        chatRecords = stored.chats.map { chat in
            var restored = chat
            // A persisted UI chat can be shown after relaunch, but the new app-server session needs a fresh thread.
            restored.threadId = nil
            restored.messages = restored.messages.map { message in
                var copy = message
                copy.pending = false
                return copy
            }
            return restored
        }
        selectedChatId = stored.selectedChatId.flatMap { id in
            chatRecords.contains(where: { $0.id == id }) ? id : nil
        } ?? chatRecords.first?.id

        if let selectedChatId, let chat = chatRecords.first(where: { $0.id == selectedChatId }) {
            apply(chat)
        } else {
            applySelectedProject()
        }
        refreshRecentChats()
    }

    private func ensureActiveChat() {
        guard selectedChatId == nil || currentChatIndex == nil else { return }
        let chat = makeChat()
        chatRecords.insert(chat, at: 0)
        selectedChatId = chat.id
        chatTitle = chat.title
        messages = chat.messages
        threadId = chat.threadId
        refreshRecentChats()
    }

    private func makeChat() -> PersistedChat {
        PersistedChat(
            id: UUID().uuidString,
            threadId: nil,
            title: Self.newChatTitle,
            projectId: selectedProjectId,
            model: selectedModel,
            reasoning: reasoning,
            permission: selectedPermission,
            messages: [],
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    private var currentChatIndex: Int? {
        guard let selectedChatId else { return nil }
        return chatRecords.firstIndex { $0.id == selectedChatId }
    }

    private func apply(_ chat: PersistedChat) {
        threadId = chat.threadId
        chatTitle = chat.title
        messages = chat.messages
        selectedModel = availableModels.contains(chat.model) ? chat.model : selectedModel
        reasoning = chat.reasoning
        selectedPermission = chat.permission
        selectedProjectId = chat.projectId
        applySelectedProject()
    }

    private func applySelectedProject() {
        guard let selectedProjectId, let project = projectRecords.first(where: { $0.id == selectedProjectId }) else {
            selectedFolderPath = nil
            selectedFolderName = "Choose folder"
            gitBranch = nil
            return
        }

        selectedFolderPath = project.path
        selectedFolderName = project.name.isEmpty ? project.path : project.name
        gitBranch = nil
        let folder = URL(fileURLWithPath: project.path)
        Task {
            let branch = await Self.gitBranch(at: folder)
            if selectedFolderPath == project.path {
                gitBranch = branch
            }
        }
    }

    private func persistCurrentChat() {
        guard let index = currentChatIndex else {
            refreshRecentChats()
            return
        }

        chatRecords[index].threadId = threadId
        chatRecords[index].title = chatTitle
        chatRecords[index].projectId = selectedProjectId
        chatRecords[index].model = selectedModel
        chatRecords[index].reasoning = reasoning
        chatRecords[index].permission = selectedPermission
        chatRecords[index].messages = messages
        chatRecords[index].updatedAt = Date()
        refreshRecentChats()
    }

    private func upsertProject(for folder: URL) -> String {
        let path = folder.path
        let name = folder.lastPathComponent.isEmpty ? path : folder.lastPathComponent

        if let index = projectRecords.firstIndex(where: { $0.path == path }) {
            projectRecords[index].name = name
            projectRecords[index].lastOpenedAt = Date()
            return projectRecords[index].id
        }

        let project = PersistedProject(id: UUID().uuidString, path: path, name: name, lastOpenedAt: Date())
        projectRecords.append(project)
        return project.id
    }

    private func refreshRecentChats() {
        recentChats = chatRecords
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { RecentChat(id: $0.id, title: $0.title, timeAgo: Self.timeAgo(from: $0.updatedAt)) }
    }

    private func saveSession() {
        persistence.save(snapshot())
    }

    private func snapshot() -> PersistedSession {
        PersistedSession(
            version: 1,
            selectedChatId: selectedChatId,
            selectedProjectId: selectedProjectId,
            lastActiveProjectId: selectedProjectId,
            selectedModel: selectedModel,
            reasoning: reasoning,
            permission: selectedPermission,
            projects: projectRecords,
            chats: chatRecords.sorted { $0.updatedAt > $1.updatedAt }
        )
    }

    private static func timeAgo(from date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "Just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        return days == 1 ? "Yesterday" : "\(days)d ago"
    }
}

private struct PersistedSession: Codable {
    var version: Int
    var selectedChatId: String?
    var selectedProjectId: String?
    var lastActiveProjectId: String?
    var selectedModel: String
    var reasoning: ReasoningEffort
    var permission: PermissionMode
    var projects: [PersistedProject]
    var chats: [PersistedChat]
}

private struct PersistedProject: Codable, Hashable {
    var id: String
    var path: String
    var name: String
    var lastOpenedAt: Date
}

private struct PersistedChat: Codable, Hashable {
    var id: String
    var threadId: String?
    var title: String
    var projectId: String?
    var model: String
    var reasoning: ReasoningEffort
    var permission: PermissionMode
    var messages: [ChatMessage]
    var createdAt: Date
    var updatedAt: Date
}

private final class LocalSessionPersistence {
    private let logger = Logger(subsystem: "dev.modex.desktop", category: "SessionPersistence")
    private let queue = DispatchQueue(label: "dev.modex.desktop.session-persistence", qos: .utility)
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    func load() -> PersistedSession? {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        do {
            let data = try Data(contentsOf: url)
            return try decoder.decode(PersistedSession.self, from: data)
        } catch {
            logger.error("Could not load persisted Modex session at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func save(_ session: PersistedSession) {
        queue.async { [encoder, logger] in
            Self.write(session, encoder: encoder, logger: logger)
        }
    }

    func saveImmediately(_ session: PersistedSession) {
        queue.sync { [encoder, logger] in
            Self.write(session, encoder: encoder, logger: logger)
        }
    }

    private static func write(_ session: PersistedSession, encoder: JSONEncoder, logger: Logger) {
        let url = fileURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try encoder.encode(session)
            try data.write(to: url, options: [.atomic])
        } catch {
            logger.error("Could not save persisted Modex session at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("Modex", isDirectory: true)
            .appendingPathComponent("session.json")
    }

    private var fileURL: URL { Self.fileURL }
}
