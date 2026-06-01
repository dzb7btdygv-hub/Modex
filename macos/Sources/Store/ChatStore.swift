import Foundation
import Observation

/// Drives the chat experience: boots the Codex engine, manages the RPC
/// connection and thread, sends turns, and accumulates streamed output.
/// Native counterpart of the logic in the former `App.tsx`.
@MainActor
@Observable
final class ChatStore {
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
    private(set) var chatTitle = "New Chat"

    let supervisor = CodexSupervisor()
    private var rpc: CodexRPCClient?
    private var threadId: String?
    private var booted = false

    var canSend: Bool { isReady && !turnRunning }

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

    // MARK: - Sending

    func send(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let rpc, !turnRunning else { return }

        turnRunning = true
        status = threadId == nil ? "Starting chat…" : "Thinking…"
        messages.append(ChatMessage(id: "user-\(UUID().uuidString)", role: .user, text: text))
        updateTitleIfNeeded(from: text)

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
        return id
    }

    func selectPermission(_ permission: PermissionMode) {
        selectedPermission = permission
        updateThreadSettingsIfNeeded()
    }

    func selectModel(_ model: String) {
        selectedModel = model
        updateThreadSettingsIfNeeded()
    }

    func selectReasoning(_ effort: ReasoningEffort) {
        reasoning = effort
        updateThreadSettingsIfNeeded()
    }

    func selectFolder(_ url: URL) {
        let folder = url.standardizedFileURL
        selectedFolderPath = folder.path
        selectedFolderName = folder.lastPathComponent.isEmpty ? folder.path : folder.lastPathComponent
        gitBranch = nil
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
        guard chatTitle == "New Chat" else { return }
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

        case "turn/completed":
            turnRunning = false
            status = "Ready."
            if let turn = params?["turn"] as? [String: Any], let error = turn["error"] {
                appendSystem(Self.describe(error))
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
        messages.append(ChatMessage(id: "system-\(UUID().uuidString)", role: .system, text: text))
    }

    private static func describe(_ error: Any) -> String {
        if let text = error as? String { return text }
        if let dict = error as? [String: Any] {
            if let message = dict["message"] as? String { return message }
            if let nested = dict["error"] { return describe(nested) }
        }
        return "Unknown error."
    }

    func shutdown() {
        Task { await rpc?.close() }
        supervisor.stop()
    }
}
