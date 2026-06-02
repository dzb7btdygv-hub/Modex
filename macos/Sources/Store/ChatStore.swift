import AppKit
import Foundation
import Observation
import OSLog
import UniformTypeIdentifiers

/// Drives the chat experience: boots the Codex engine, manages the RPC
/// connection and thread, sends turns, and accumulates streamed output.
/// Native counterpart of the logic in the former `App.tsx`.
@MainActor
@Observable
final class ChatStore {
    private static let newChatTitle = "New Chat"
    private static let untitledChatTitle = "Untitled Chat"

    private(set) var messages: [ChatMessage] = []
    private(set) var status: String = "Starting Codex…"
    private(set) var taskStatus: ChatTaskStatus = .startingCodex
    private(set) var isReady = false
    private(set) var turnRunning = false

    // MARK: - User selections (top-bar model + reasoning, composer context)
    /// User-facing model label. This is the canonical value persisted per chat /
    /// project; it is translated to a wire ``selectedModelSlug`` before being
    /// sent to Codex.
    var selectedModel = ChatStore.fallbackModelCatalog[0].label
    /// Labels shown in the model picker.
    var availableModels: [String] { modelOptions.map(\.label) }
    var reasoning: ReasoningEffort = .high
    private(set) var selectedPermission: PermissionMode = .readOnly
    private(set) var selectedFolderPath: String?
    private(set) var selectedFolderName = "Choose folder"
    private(set) var gitBranch: String?
    /// Local branches in the active project, for the top-bar branch switcher.
    private(set) var gitBranches: [String] = []
    private(set) var activeProjectMissing = false
    private(set) var chatTitle = ChatStore.newChatTitle
    private(set) var selectedChatId: String?

    let supervisor = CodexSupervisor()
    private let errorCenter: ErrorCenter
    private let persistence = LocalSessionPersistence()
    private let logger = Logger(subsystem: "dev.modex.desktop", category: "ChatStore")
    private var rpc: CodexRPCClient?
    private var threadId: String?
    private var currentTurnId: String?
    private var booted = false
    /// Bumped on every (re)boot and teardown so a stale connection's close
    /// handler — fired after we've already moved on — is ignored.
    private var bootGeneration = 0
    /// The text of the most recent turn, so a failed send can be re-attempted
    /// without re-appending the user's message.
    private var lastAttemptedText: String?
    private var permissionStatusTask: Task<Void, Never>?
    private var turnCancellationRequested = false
    private var turnInterruptInFlight = false
    private var activeAssistantMessageId: String?
    private var assistantMessageIdsByItemId: [String: String] = [:]
    private var modelOptions = ChatStore.fallbackModelCatalog
    private var chatRecords: [PersistedChat] = []
    private var projectRecords: [Project] = []
    private var selectedProjectId: String?
    /// Folders the user removed from Modex's sidebar. Kept so re-importing from
    /// Codex's trusted list doesn't resurrect them on the next launch.
    private var dismissedProjectPaths: Set<String> = []
    /// Codex threads keyed by project folder path — loaded per project as its
    /// row is expanded, so each project unfolds to reveal its own chats.
    private var threadsByProjectPath: [String: [CodexThreadSummary]] = [:]
    /// Paths with an in-flight `thread/list` (per-path, so different projects can
    /// load concurrently and a switch never blocks the next project's fetch).
    private var loadingProjectPaths: Set<String> = []

    var canSend: Bool { isReady && !turnRunning }

    /// Display name of the active project, shown as the scoping header for the
    /// recent-chats list. `nil` when no folder/project is active.
    var activeProjectName: String? {
        guard let selectedProjectId,
              let project = projectRecords.first(where: { $0.id == selectedProjectId }) else { return nil }
        return project.displayName
    }

    /// All known projects, most-recently-opened first. Drives the sidebar's
    /// Projects list so switching workspaces never loses a project from view.
    var projects: [ProjectSummary] {
        // Stable alphabetical order so selecting a project never reshuffles the
        // list (the active one is shown by tint, not by jumping to the top).
        projectRecords
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            .map { ProjectSummary(id: $0.id, name: $0.displayName, path: $0.path, isMissing: !$0.folderExists) }
    }

    /// The active project's id, or `nil` when working without a folder.
    var activeProjectId: String? { selectedProjectId }

    /// Whether a project/folder is active (vs. a folderless "Chats" context).
    var isInProject: Bool { selectedProjectId != nil }

    private func setTaskStatus(_ taskStatus: ChatTaskStatus) {
        guard self.taskStatus != taskStatus else { return }
        if taskStatus != .waitingForPermission {
            permissionStatusTask?.cancel()
            permissionStatusTask = nil
        }
        self.taskStatus = taskStatus
        status = taskStatus.label
    }

    private func setActiveTurnStatus(_ taskStatus: ChatTaskStatus) {
        guard !turnCancellationRequested else { return }
        setTaskStatus(taskStatus)
    }

    private func resetTurnCancellation() {
        permissionStatusTask?.cancel()
        permissionStatusTask = nil
        currentTurnId = nil
        turnCancellationRequested = false
        turnInterruptInFlight = false
        activeAssistantMessageId = nil
        assistantMessageIdsByItemId.removeAll()
    }

    init(errors: ErrorCenter) {
        self.errorCenter = errors
        supervisor.onUnexpectedExit = { [weak self] code in
            self?.handleSidecarCrash(code: code)
        }
        restoreSession()
        importCodexProjects()
    }

    // MARK: - Boot

    func bootIfNeeded() {
        guard !booted else { return }
        booted = true
        Task { await boot() }
    }

    private func boot() async {
        bootGeneration += 1
        let generation = bootGeneration
        errorCenter.clearFatal()
        setTaskStatus(.startingCodex)

        do {
            let wsURL = try await supervisor.start()
            setTaskStatus(.connecting)

            let client = CodexRPCClient(
                url: wsURL,
                onNotification: { [weak self] method, params in
                    self?.handle(method: method, params: params)
                },
                onClose: { [weak self] reason in
                    guard let self, self.bootGeneration == generation else { return }
                    self.handleDisconnect(reason: reason)
                },
                onServerRequest: { [weak self] method, started in
                    self?.handleServerRequest(method: method, started: started)
                }
            )
            rpc = client

            do {
                setTaskStatus(.initializing)
                _ = try await client.request("initialize", params: [
                    "clientInfo": ["name": "modex", "title": "Modex", "version": "0.1.0"],
                    "capabilities": ["experimentalApi": true, "requestAttestation": false],
                ])
                await loadModelCatalog(client)
            } catch {
                // Distinguish a dropped connection from a rejected handshake.
                let detail = error.localizedDescription
                let connectionLost = detail.localizedCaseInsensitiveContains("disconnect")
                throw connectionLost
                    ? ModexError.rpcConnectionFailed(detail: detail)
                    : ModexError.rpcInitializeFailed(detail: detail)
            }

            // A newer boot superseded this one (e.g. rapid retry); don't apply
            // stale terminal state.
            guard bootGeneration == generation else {
                await client.close()
                return
            }
            isReady = true
            setTaskStatus(.ready)
            if let id = selectedProjectId { loadProjectThreads(id) }  // active project's history
            logger.log("Codex engine ready (generation \(generation)).")
        } catch let modexError as ModexError {
            guard bootGeneration == generation else { return }
            isReady = false
            setTaskStatus(.failed(modexError.title))
            errorCenter.present(modexError) { [weak self] in self?.restartCodex() }
        } catch {
            guard bootGeneration == generation else { return }
            isReady = false
            let modexError = ModexError.rpcInitializeFailed(detail: error.localizedDescription)
            setTaskStatus(.failed(modexError.title))
            errorCenter.present(modexError) { [weak self] in self?.restartCodex() }
        }
    }

    /// Tears down the current engine/connection and boots a fresh one. Backs the
    /// "Restart Codex" / "Try Again" recovery actions.
    func restartCodex() {
        bootGeneration += 1   // orphan the old connection's close handler
        let client = rpc
        rpc = nil
        threadId = nil
        resetTurnCancellation()
        isReady = false
        turnRunning = false
        booted = false
        Task { await client?.close() }
        supervisor.stop()
        errorCenter.clearAll()
        setTaskStatus(.startingCodex)
        logger.log("Restarting Codex engine.")
        bootIfNeeded()
    }

    /// The RPC connection closed after we were live. Mid-turn it reads as an
    /// interrupted stream; otherwise as a lost/crashed engine. Pre-ready
    /// failures are owned by `boot()`'s catch, so they're ignored here.
    private func handleDisconnect(reason: String) {
        guard isReady else {
            rpc = nil
            return
        }
        let wasRunningTurn = turnRunning
        rpc = nil
        threadId = nil
        resetTurnCancellation()
        isReady = false
        turnRunning = false
        clearPendingMessages()
        setTaskStatus(.failed(reason))

        let error = wasRunningTurn
            ? ModexError.streamInterrupted(detail: reason)
            : ModexError.sidecarCrashed(detail: reason)
        errorCenter.present(error) { [weak self] in self?.restartCodex() }
    }

    /// The engine process exited unexpectedly. The RPC close handler usually
    /// fires first with richer context; this is the backstop for the case where
    /// the process dies before the socket reports it. `isReady` is the dedup
    /// guard: whichever handler runs first flips it, so the other no-ops.
    private func handleSidecarCrash(code: Int32) {
        guard isReady else { return }
        isReady = false
        turnRunning = false
        rpc = nil
        threadId = nil
        resetTurnCancellation()
        clearPendingMessages()
        setTaskStatus(.failed("Codex engine exited"))
        errorCenter.present(.sidecarCrashed(detail: "Codex engine exited with status \(code).")) {
            [weak self] in self?.restartCodex()
        }
    }

    /// Clears any half-streamed `pending` bubbles so an interrupted turn never
    /// leaves a message stuck showing "Thinking…".
    private func clearPendingMessages() {
        for index in messages.indices where messages[index].pending {
            messages[index].pending = false
        }
    }

    // MARK: - Chats

    func startNewChat() {
        guard !turnRunning else { return }
        if messages.isEmpty, threadId == nil, chatTitle == Self.newChatTitle, selectedChatId != nil {
            return
        }

        persistCurrentChat()
        // A new chat starts from the active project's remembered defaults.
        if let selectedProjectId { applyProjectDefaults(selectedProjectId) }
        let chat = makeChat()
        chatRecords.insert(chat, at: 0)
        selectedChatId = chat.id
        apply(chat)
        if isReady {
            setTaskStatus(.ready)
        }
        refreshRecentChats()
        saveSession()
    }

    func selectChat(_ id: String) {
        guard !turnRunning, id != selectedChatId else { return }

        // A Codex thread (in any loaded project list) → resume it.
        if threadsByProjectPath.values.contains(where: { $0.contains { $0.id == id } }) {
            openCodexThread(id)
            return
        }

        guard let chat = chatRecords.first(where: { $0.id == id }) else { return }
        persistCurrentChat()
        selectedChatId = id
        apply(chat)
        if isReady {
            setTaskStatus(.ready)
        }
        refreshRecentChats()
        saveSession()
    }

    // MARK: - Sending

    func send(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !turnRunning else { return }

        if activeProjectMissing {
            setTaskStatus(.failed("Folder missing"))
            errorCenter.present(.folderMissing(path: selectedFolderPath)) { [weak self] in self?.presentFolderPicker() }
            return
        }

        // Write/Full access need a workspace root; nudge the user to pick one.
        guard selectedFolderPath != nil || selectedPermission == .readOnly else {
            setTaskStatus(.failed("Folder required"))
            errorCenter.present(.folderRequired()) { [weak self] in self?.presentFolderPicker() }
            return
        }

        guard rpc != nil else {
            setTaskStatus(.failed("Codex unavailable"))
            errorCenter.present(.sidecarCrashed(detail: status)) { [weak self] in self?.restartCodex() }
            return
        }

        ensureActiveChat()
        messages.append(ChatMessage(id: "user-\(UUID().uuidString)", role: .user, text: text))
        updateTitleIfNeeded(from: text)
        persistCurrentChat()
        saveSession()

        startTurn(text)
    }

    /// Runs (or re-runs) a turn for already-appended text. Separated from
    /// ``send(_:)`` so a retry resends without duplicating the user's message.
    private func startTurn(_ text: String) {
        guard let rpc, !turnRunning else { return }
        lastAttemptedText = text
        resetTurnCancellation()
        errorCenter.dismissBanner()
        turnRunning = true
        setTaskStatus(threadId == nil ? .creatingThread : .sendingMessage)

        Task {
            let threadId: String
            do {
                threadId = try await ensureThread(rpc)
            } catch {
                turnRunning = false
                resetTurnCancellation()
                setTaskStatus(.failed("Couldn’t start the chat"))
                errorCenter.present(.threadStartFailed(detail: error.localizedDescription)) {
                    [weak self] in self?.startTurn(text)
                }
                return
            }

            if turnCancellationRequested {
                finishCancelledTurn()
                return
            }

            do {
                setTaskStatus(.sendingMessage)
                let result = try await rpc.request("turn/start", params: turnStartParams(threadId: threadId, text: text))
                if let turnId = Self.turnId(from: result) {
                    currentTurnId = turnId
                }
                if turnCancellationRequested {
                    requestTurnInterruptIfPossible()
                    return
                }
                if turnRunning, taskStatus == .sendingMessage {
                    setTaskStatus(.thinking)
                }
            } catch {
                turnRunning = false
                resetTurnCancellation()
                setTaskStatus(.failed("Message not sent"))
                errorCenter.present(Self.turnError(from: error)) {
                    [weak self] in self?.startTurn(text)
                }
            }
        }
    }

    func cancelTurn() {
        guard turnRunning else { return }
        turnCancellationRequested = true
        setTaskStatus(.cancelling)
        requestTurnInterruptIfPossible()
    }

    private func requestTurnInterruptIfPossible() {
        guard turnCancellationRequested, !turnInterruptInFlight,
              let rpc, let threadId, let currentTurnId else {
            return
        }

        turnInterruptInFlight = true
        Task {
            do {
                _ = try await rpc.request("turn/interrupt", params: [
                    "threadId": threadId,
                    "turnId": currentTurnId,
                ])
            } catch {
                guard turnRunning else { return }
                turnRunning = false
                clearPendingMessages()
                resetTurnCancellation()
                setTaskStatus(.failed("Couldn’t cancel"))
                errorCenter.present(.engineError(detail: error.localizedDescription)) {
                    [weak self] in self?.resendLastTurn()
                }
            }
        }
    }

    private func finishCancelledTurn() {
        turnRunning = false
        clearPendingMessages()
        resetTurnCancellation()
        setTaskStatus(.cancelled)
        persistCurrentChat()
        saveSession()
    }

    /// Re-sends the last turn if it's safe to do so. Backs the banner "Resend".
    func resendLastTurn() {
        guard let text = lastAttemptedText, canSend else { return }
        startTurn(text)
    }

    /// Presents the native folder picker and selects the chosen directory.
    /// Shared by the top bar and the "Choose Folder" recovery action.
    func presentFolderPicker() {
        let panel = NSOpenPanel()
        panel.title = "Choose Project Folder"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.treatsFilePackagesAsDirectories = true
        panel.allowedContentTypes = [.directory]
        // Open at the current folder — but never at a path that no longer exists
        // (that leaves the panel in a state where "Choose" stays disabled). Fall
        // back to the nearest existing ancestor.
        if let path = selectedFolderPath {
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: path) {
                panel.directoryURL = URL(fileURLWithPath: path)
            } else {
                let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
                if fileManager.fileExists(atPath: parent.path) {
                    panel.directoryURL = parent
                }
            }
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectFolder(url)
    }

    private func ensureThread(_ rpc: CodexRPCClient) async throws -> String {
        if let threadId { return threadId }
        setTaskStatus(.creatingThread)
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
        rememberActiveProjectDefaults()
        saveSession()
        updateThreadSettingsIfNeeded()
    }

    func selectModel(_ model: String) {
        selectedModel = canonicalModelLabel(for: model) ?? model
        persistCurrentChat()
        rememberActiveProjectDefaults()
        saveSession()
        updateThreadSettingsIfNeeded()
    }

    func selectReasoning(_ effort: ReasoningEffort) {
        reasoning = effort
        persistCurrentChat()
        rememberActiveProjectDefaults()
        saveSession()
        updateThreadSettingsIfNeeded()
    }

    /// Picks a folder: creates the project (or reopens the existing one for that
    /// path) and makes it the active workspace.
    func selectFolder(_ url: URL) {
        // Resolve symlinks before standardizing so two paths that point at the
        // same real directory (e.g. via a symlink) map to one project rather
        // than duplicating. The app isn't sandboxed, so a resolved path is a
        // sufficient identity — no security-scoped bookmark needed.
        let folder = url.resolvingSymlinksInPath().standardizedFileURL
        let projectId = upsertProject(for: folder)
        openProject(projectId)
    }

    /// Activates a project: applies its remembered defaults, picks the right
    /// chat to show, and refreshes the scoped chat list. Reused by folder
    /// selection and (potentially) project switching elsewhere.
    private func openProject(_ id: String) {
        let switching = id != selectedProjectId
        // Never switch workspaces out from under a running turn — it would yank
        // the active chat away from a streaming response. Re-picking the same
        // project mid-turn is harmless (just refreshes the display).
        guard !(switching && turnRunning) else { return }
        persistCurrentChat()
        selectedProjectId = id

        // A folder action is a context switch: drop any transient error banner
        // and clear a stale `failed` status so neither bleeds onto the new view.
        errorCenter.dismissBanner()
        if isReady { setTaskStatus(.ready) }

        guard switching else {
            // Same project re-picked — just refresh the folder display (path or
            // name may have changed) and re-probe the branch.
            applySelectedProject()
            refreshRecentChats()
            saveSession()
            updateThreadSettingsIfNeeded()
            return
        }

        applyProjectDefaults(id)

        if let recent = mostRecentChat(inProject: id) {
            // Reopening a project with history — restore its most recent chat.
            // Checked first so switching back to a project never hijacks the
            // empty scratch chat instead of the real conversation.
            selectedChatId = recent.id
            apply(recent)
        } else if let index = currentChatIndex,
                  chatRecords[index].messages.isEmpty, chatRecords[index].threadId == nil {
            // Target project has no history; fold the current empty, unsent
            // canvas into it rather than spawning a duplicate empty chat.
            chatRecords[index].projectId = id
            chatRecords[index].model = selectedModel
            chatRecords[index].reasoning = reasoning
            chatRecords[index].permission = selectedPermission
            applySelectedProject()
        } else if currentChatIndex != nil {
            // The active chat belongs elsewhere and this project has no history —
            // start a fresh chat in it.
            let chat = makeChat()
            chatRecords.insert(chat, at: 0)
            selectedChatId = chat.id
            apply(chat)
        } else {
            // No active chat yet (fresh launch). Defaults are applied; the next
            // send will create the first chat in this project.
            applySelectedProject()
        }

        refreshRecentChats()
        saveSession()
        updateThreadSettingsIfNeeded()
    }

    /// Switches the active project from the sidebar's Projects list. The old
    /// project and its chats stay on disk — they reappear the moment it's
    /// re-selected. No-op mid-turn.
    func switchToProject(_ id: String) {
        guard !turnRunning, id != selectedProjectId,
              projectRecords.contains(where: { $0.id == id }) else { return }
        openProject(id)
    }

    /// Renames a project's display name (Modex-side; Codex's trust list has no
    /// project name to sync to).
    func renameProject(_ id: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = projectRecords.firstIndex(where: { $0.id == id }) else { return }
        projectRecords[index].name = trimmed
        saveSession()
    }

    /// Removes a project from the sidebar — like Codex's "remove project", this
    /// only forgets it here; the folder and its files are untouched. Remembered
    /// so a Codex re-import won't bring it back. If it was active, detaches to a
    /// folderless context.
    func removeProject(_ id: String) {
        guard let index = projectRecords.firstIndex(where: { $0.id == id }) else { return }
        let wasActive = selectedProjectId == id
        if wasActive && turnRunning { return }   // don't yank the active project mid-turn

        dismissedProjectPaths.insert(projectRecords[index].path)
        projectRecords.remove(at: index)

        if wasActive {
            selectedProjectId = nil
            selectedPermission = .readOnly
            errorCenter.dismissBanner()
            if isReady { setTaskStatus(.ready) }
            if let recent = mostRecentChat(inProject: nil) {
                selectedChatId = recent.id
                apply(recent)
            } else {
                let chat = makeChat()
                chatRecords.insert(chat, at: 0)
                selectedChatId = chat.id
                apply(chat)
            }
            updateThreadSettingsIfNeeded()
        }

        refreshRecentChats()
        saveSession()
    }

    /// Leaves the current project to work without a folder. Chats created here
    /// are projectless and surface under the sidebar's "Chats" section. Drops to
    /// Read only, since Write/Full access need a workspace root. No-op mid-turn.
    func closeActiveFolder() {
        guard !turnRunning, selectedProjectId != nil else { return }
        persistCurrentChat()
        selectedProjectId = nil
        errorCenter.dismissBanner()
        if isReady { setTaskStatus(.ready) }
        selectedPermission = .readOnly

        if let recent = mostRecentChat(inProject: nil) {
            // Resume the most recent folderless chat, if any.
            selectedChatId = recent.id
            apply(recent)
        } else if let index = currentChatIndex,
                  chatRecords[index].messages.isEmpty, chatRecords[index].threadId == nil {
            // Fold the current empty canvas into the folderless context.
            chatRecords[index].projectId = nil
            chatRecords[index].permission = selectedPermission
            applySelectedProject()
        } else {
            // Active chat belongs to a project — start a fresh folderless one.
            let chat = makeChat()
            chatRecords.insert(chat, at: 0)
            selectedChatId = chat.id
            apply(chat)
        }

        refreshRecentChats()
        saveSession()
        updateThreadSettingsIfNeeded()
    }

    /// Seeds the composer (access mode, model, reasoning) from a project's
    /// remembered defaults. Used when *opening* a project — never when opening an
    /// existing chat, whose own saved settings win.
    private func applyProjectDefaults(_ id: String) {
        guard let project = projectRecords.first(where: { $0.id == id }) else { return }
        selectedPermission = project.defaultPermission
        if let model = project.lastModel, let label = canonicalModelLabel(for: model) {
            selectedModel = label
        }
        reasoning = project.lastReasoning
    }

    /// Writes the current composer selections back to the active project so the
    /// project remembers them as its last-used defaults.
    private func rememberActiveProjectDefaults() {
        guard let selectedProjectId,
              let index = projectRecords.firstIndex(where: { $0.id == selectedProjectId }) else { return }
        projectRecords[index].defaultPermission = selectedPermission
        projectRecords[index].lastModel = selectedModel
        projectRecords[index].lastReasoning = reasoning
    }

    private func mostRecentChat(inProject id: String?) -> PersistedChat? {
        chatRecords
            .filter { $0.projectId == id }
            .max { $0.updatedAt < $1.updatedAt }
    }

    // MARK: - Model catalog

    /// A selectable model: `label` is shown in the UI and persisted per chat /
    /// project; `slug` is the identifier Codex accepts on the wire. Sending a
    /// display name (e.g. "GPT-5.5") instead of its slug ("gpt-5.5") makes the
    /// engine reject the request as an unsupported model.
    private struct ModelOption {
        let label: String
        let slug: String
        var aliases: [String] = []
        var isDefault = false
    }

    private static let fallbackModelCatalog: [ModelOption] = [
        ModelOption(label: "GPT-5.5", slug: "gpt-5.5", aliases: ["gpt-5-5", "gpt-5.5-pro", "gpt-5p5"]),
        ModelOption(label: "GPT-5.4", slug: "gpt-5.4", aliases: ["gpt-5-4"]),
        ModelOption(label: "GPT-5.4-Mini", slug: "gpt-5.4-mini", aliases: ["GPT-5.4 Mini", "GPT-5 mini"]),
        ModelOption(label: "GPT-5.3-Codex", slug: "gpt-5.3-codex", aliases: ["GPT-5.3 Codex", "GPT-5.3-Codex-Spark", "gpt-5.3-codex-spark"]),
    ]

    private func canonicalModelLabel(for value: String) -> String? {
        Self.canonicalModelLabel(for: value, in: modelOptions)
            ?? Self.canonicalModelLabel(for: value, in: Self.fallbackModelCatalog)
    }

    private static func canonicalModelLabel(for value: String, in catalog: [ModelOption]) -> String? {
        catalog.first { option in
            option.label == value || option.slug == value || option.aliases.contains(value)
        }?.label
    }

    private var selectedModelSlug: String {
        modelOptions.first { $0.label == selectedModel }?.slug
            ?? Self.fallbackModelCatalog.first { $0.label == selectedModel }?.slug
            ?? selectedModel
    }

    private func loadModelCatalog(_ rpc: CodexRPCClient) async {
        var loaded: [ModelOption] = []
        var cursor: String?

        do {
            repeat {
                var params: [String: Any] = ["includeHidden": true, "limit": 100]
                if let cursor { params["cursor"] = cursor }
                guard let result = try await rpc.request("model/list", params: params) as? [String: Any] else {
                    break
                }

                let models = result["data"] as? [[String: Any]] ?? []
                loaded.append(contentsOf: models.compactMap(Self.modelOption))
                cursor = result["nextCursor"] as? String
            } while cursor != nil
        } catch {
            logger.error("Could not load Codex model catalog: \(error.localizedDescription, privacy: .public)")
            return
        }

        let options = Self.deduplicatedModelOptions(loaded.filter { !Self.isInternalModel(slug: $0.slug) })
        guard !options.isEmpty else { return }

        let previous = selectedModel
        modelOptions = options
        if let label = canonicalModelLabel(for: previous) {
            selectedModel = label
        } else if let defaultOption = options.first(where: \.isDefault) {
            selectedModel = defaultOption.label
        } else {
            selectedModel = options[0].label
        }
    }

    private static func modelOption(from model: [String: Any]) -> ModelOption? {
        guard
            let slug = (model["model"] as? String) ?? (model["id"] as? String),
            !slug.isEmpty
        else { return nil }

        let label = (model["displayName"] as? String)
            ?? (model["id"] as? String)
            ?? slug
        var aliases = [slug]
        if let id = model["id"] as? String, id != slug {
            aliases.append(id)
        }
        return ModelOption(
            label: label,
            slug: slug,
            aliases: aliases,
            isDefault: model["isDefault"] as? Bool ?? false
        )
    }

    /// Excludes non-chat entries the server lists with `includeHidden` (e.g. the
    /// internal `codex-auto-review` reviewer) so they never show in the picker.
    private static func isInternalModel(slug: String) -> Bool {
        let s = slug.lowercased()
        return s.contains("auto-review") || s.contains("auto_review")
    }

    private static func deduplicatedModelOptions(_ options: [ModelOption]) -> [ModelOption] {
        var seen = Set<String>()
        var result: [ModelOption] = []
        for option in options {
            guard seen.insert(option.slug).inserted else { continue }
            result.append(option)
        }
        return result.sorted {
            if $0.isDefault != $1.isDefault { return $0.isDefault }
            return $0.label.localizedStandardCompare($1.label) == .orderedAscending
        }
    }

    /// Modex-specific guidance layered on top of Codex's built-in persona via
    /// the `developerInstructions` thread param. Teaches the engine the app's
    /// rendering vocabulary (callouts) and a little about the Modex environment,
    /// so it can express itself richly. Kept short — it rides every turn.
    private static let modexDeveloperInstructions = """
    You are running inside Modex, a native macOS app. Your replies render as \
    GitHub-flavored Markdown in a chat panel, so use clear structure: short \
    paragraphs, headings, flat lists, and fenced code blocks with a language tag.

    Modex adds five callout blocks for emphasis. Use them sparingly — only when \
    they genuinely help — by writing a fenced block whose tag is the callout name, \
    with an optional short title on the fence line:
    - `note` — neutral context or an aside
    - `tip` — a helpful suggestion
    - `success` — confirm something worked
    - `warning` — something to be careful about
    - `danger` — a destructive or high-risk action
    Example: a fence opening with ```tip Quick tip then the body then a closing \
    fence. Do not nest callouts or place fenced code inside a callout.

    Environment: the user chooses a project folder and an access mode (Read only, \
    Write, or Full access) from Modex's UI; you cannot change these yourself, so if \
    you need write access or a workspace folder, ask the user to set it. Keep \
    replies concise and skimmable.
    """

    private func threadStartParams() -> [String: Any] {
        var params: [String: Any] = [
            "approvalPolicy": "never",
            "sandbox": selectedPermission.sandboxMode,
            "ephemeral": false,
            "model": selectedModelSlug,
            "serviceName": "modex",
            "developerInstructions": Self.modexDeveloperInstructions,
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
            "model": selectedModelSlug,
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
        guard let rpc, let threadId, !turnRunning, !activeProjectMissing else { return }

        var params: [String: Any] = [
            "threadId": threadId,
            "model": selectedModelSlug,
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
        chatTitle = Self.generatedTitle(from: text) ?? Self.untitledChatTitle
    }

    static func generatedTitle(from text: String) -> String? {
        var title = text
            .replacingOccurrences(of: "```[\\s\\S]*?```", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "`([^`]+)`", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^\\)]+\\)", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "[*#>]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !title.isEmpty else { return nil }

        if let sentenceEnd = title.range(of: "[.?!;:]\\s+", options: .regularExpression) {
            let candidate = String(title[..<sentenceEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.count >= 8 { title = candidate }
        }

        let prefixes = [
            "can you ", "could you ", "would you ", "please ", "pls ",
            "help me with ", "help me ", "help with ", "help ", "i need to ", "i want to ", "i'd like to ",
            "id like to ", "can we ", "could we ", "make it so "
        ]
        while let prefix = prefixes.first(where: { title.lowercased().hasPrefix($0) }) {
            title.removeFirst(prefix.count)
        }

        let noiseWords: Set<String> = ["a", "an", "the", "this", "that", "these", "those", "issue", "problem"]
        var words = title
            .split(separator: " ")
            .map { String($0).trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
            .filter { !noiseWords.contains($0.lowercased()) }

        guard words.contains(where: { $0.rangeOfCharacter(from: .alphanumerics) != nil }) else { return nil }

        if words.count > 7 { words = Array(words.prefix(7)) }
        title = words.joined(separator: " ")
        if title.count > 50 {
            title = String(title.prefix(50)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return title.isEmpty ? nil : title
    }

    /// Best-effort current git branch. Always non-fatal: any failure (not a
    /// repo, git missing, non-zero exit) just yields `nil` so the branch pill
    /// hides — it never blocks chat. Failures are logged, not surfaced.
    private static func gitBranch(at folder: URL) async -> String? {
        await Task.detached {
            let log = Logger(subsystem: "dev.modex.desktop", category: "GitBranch")
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", folder.path, "branch", "--show-current"]
            process.standardOutput = output
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    log.debug("git branch detection skipped at \(folder.path, privacy: .public) (status \(process.terminationStatus)).")
                    return nil
                }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let branch = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return branch.isEmpty ? nil : branch
            } catch {
                log.debug("git branch detection failed at \(folder.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }.value
    }

    /// Local branch names in the repo. Best-effort; `[]` on any failure.
    private static func gitBranches(at folder: URL) async -> [String] {
        await Task.detached {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", folder.path, "branch", "--format=%(refname:short)"]
            process.standardOutput = output
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return [] }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                return String(decoding: data, as: UTF8.self)
                    .split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            } catch {
                return []
            }
        }.value
    }

    /// Runs `git switch <name>`. Returns success + git's stderr on failure so the
    /// banner can explain (e.g. uncommitted changes).
    private static func switchBranch(_ name: String, at folder: URL) async -> (ok: Bool, message: String) {
        await Task.detached {
            let process = Process()
            let errorPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", folder.path, "switch", name]
            process.standardError = errorPipe
            process.standardOutput = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 { return (true, "") }
                let text = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                return (false, text.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch {
                return (false, error.localizedDescription)
            }
        }.value
    }

    // MARK: - Notification handling (mirrors handleNotification in App.tsx)

    private func handle(method: String, params: [String: Any]?) {
        switch method {
        case "turn/started":
            if let turnId = Self.turnId(from: params?["turn"] ?? params) {
                currentTurnId = turnId
            }
            if turnCancellationRequested {
                requestTurnInterruptIfPossible()
                return
            }
            if turnRunning {
                setTaskStatus(.thinking)
            }

        case "item/started":
            guard
                let item = params?["item"] as? [String: Any],
                let itemType = item["type"] as? String,
                let itemId = item["id"] as? String
            else { return }
            switch itemType {
            case "agentMessage":
                setActiveTurnStatus(.thinking)
                _ = ensureAssistantMessage(for: itemId)
            case "reasoning":
                setActiveTurnStatus(.thinking)
                _ = ensureAssistantMessage(for: itemId)
            case "commandExecution":
                setActiveTurnStatus(.runningCommand)
            case "fileChange":
                setActiveTurnStatus(.editingFiles)
            default:
                if turnRunning {
                    setActiveTurnStatus(.thinking)
                }
            }

        case "item/agentMessage/delta":
            guard
                let itemId = params?["itemId"] as? String,
                let delta = params?["delta"] as? String
            else { return }
            setActiveTurnStatus(.streamingResponse)
            let index = ensureAssistantMessage(for: itemId)
            messages[index].text += delta
            messages[index].pending = true

        case "item/reasoning/textDelta":
            appendReasoningDelta(params?["delta"] as? String, itemId: params?["itemId"] as? String, isSummary: false)

        case "item/reasoning/summaryPartAdded":
            if let itemId = params?["itemId"] as? String {
                setActiveTurnStatus(.thinking)
                _ = ensureAssistantMessage(for: itemId)
            }

        case "item/reasoning/summaryTextDelta":
            appendReasoningDelta(params?["delta"] as? String, itemId: params?["itemId"] as? String, isSummary: true)

        case "command/exec/outputDelta",
            "process/outputDelta",
             "item/commandExecution/outputDelta",
             "item/commandExecution/terminalInteraction":
            if turnRunning {
                setActiveTurnStatus(.runningCommand)
                appendToolOutput(Self.streamText(from: params), itemId: params?["itemId"] as? String)
            }

        case "turn/diff/updated",
             "item/fileChange/outputDelta",
             "item/fileChange/patchUpdated":
            if turnRunning {
                setActiveTurnStatus(.editingFiles)
            }

        case "serverRequest/resolved":
            if turnRunning, !turnCancellationRequested, taskStatus == .waitingForPermission {
                setTaskStatus(.thinking)
            }

        case "item/completed":
            guard
                let item = params?["item"] as? [String: Any],
                let itemType = item["type"] as? String,
                let itemId = item["id"] as? String
            else { return }
            if itemType == "agentMessage" {
                let id = assistantMessageIdsByItemId[itemId] ?? "assistant-\(itemId)"
                if let index = messages.firstIndex(where: { $0.id == id }) {
                    messages[index].text = item["text"] as? String ?? messages[index].text
                    messages[index].pending = false
                }
            } else if turnRunning {
                setActiveTurnStatus(.thinking)
            }
            persistCurrentChat()
            saveSession()

        case "turn/completed":
            turnRunning = false
            clearPendingMessages()
            let turn = params?["turn"] as? [String: Any]
            let turnStatus = turn?["status"] as? String
            let error = Self.meaningfulError(turn?["error"])
            let wasCancelling = turnCancellationRequested
            resetTurnCancellation()
            if turnStatus == "interrupted" || (wasCancelling && error == nil) {
                setTaskStatus(.cancelled)
                persistCurrentChat()
                saveSession()
            } else if let error {
                presentEngineError(Self.describe(error))
            } else if turnStatus == "failed" {
                presentEngineError(Self.describe(turn ?? params ?? [:]))
            } else {
                setTaskStatus(.completed)
                persistCurrentChat()
                saveSession()
            }

        case "error":
            turnRunning = false
            resetTurnCancellation()
            setTaskStatus(.failed("Codex returned an error"))
            presentEngineError(Self.describe(Self.meaningfulError(params?["error"]) ?? params ?? [:]))

        default:
            break
        }
    }

    private func handleServerRequest(method: String, started: Bool) {
        guard turnRunning, !turnCancellationRequested else { return }
        guard method.contains("requestApproval") || method.contains("permissions/requestApproval") else {
            return
        }

        if started {
            permissionStatusTask?.cancel()
            permissionStatusTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.turnRunning else { return }
                    self.setTaskStatus(.waitingForPermission)
                }
            }
        } else if turnRunning, taskStatus == .waitingForPermission {
            setTaskStatus(.thinking)
        } else {
            permissionStatusTask?.cancel()
            permissionStatusTask = nil
        }
    }

    /// Surfaces a Codex-reported error in the banner, classifying sandbox /
    /// permission rejections so we can suggest raising permissions.
    private func presentEngineError(_ detail: String) {
        let error = Self.isPermissionError(detail)
            ? ModexError.permissionDenied(detail: detail)
            : ModexError.engineError(detail: detail)
        setTaskStatus(.failed(error.title))
        errorCenter.present(error) { [weak self] in self?.resendLastTurn() }
    }

    /// Maps a thrown turn error to a permission rejection or a generic send
    /// failure based on its text.
    private static func turnError(from error: Error) -> ModexError {
        let detail = error.localizedDescription
        return isPermissionError(detail)
            ? .permissionDenied(detail: detail)
            : .turnSendFailed(detail: detail)
    }

    /// Heuristic: does this error read like a sandbox/permission/approval
    /// rejection (vs. a generic engine failure)? Anchored on sandbox- and
    /// filesystem-specific signals so generic words like "rejected"/"blocked"
    /// (which appear in unrelated network/server errors) don't misfire and
    /// suggest raising permissions when that wouldn't help.
    private static func isPermissionError(_ text: String) -> Bool {
        let needles = ["sandbox", "seatbelt", "permission", "denied", "not permitted",
                       "operation not permitted", "read-only", "read only",
                       "eacces", "eperm", "not allowed", "not approved",
                       "requires approval", "approval was declined", "approval required"]
        let lower = text.lowercased()
        return needles.contains { lower.contains($0) }
    }

    private static func describe(_ error: Any) -> String {
        if let text = error as? String { return text }
        if error is NSNull { return "Codex sent an error notification without details." }
        if let dict = error as? [String: Any] {
            if let message = dict["message"] as? String { return message }
            if let nested = dict["error"] { return describe(nested) }
        }
        return "Codex sent an error notification without details."
    }

    private static func meaningfulError(_ error: Any?) -> Any? {
        guard let error, !(error is NSNull) else { return nil }
        if let text = error as? String, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }
        if let dict = error as? [String: Any], dict.isEmpty {
            return nil
        }
        return error
    }

    private static func turnId(from payload: Any?) -> String? {
        guard let dict = payload as? [String: Any] else { return nil }
        if let id = dict["turnId"] as? String { return id }
        if let id = dict["id"] as? String { return id }
        if let turn = dict["turn"] as? [String: Any] {
            return turn["turnId"] as? String ?? turn["id"] as? String
        }
        return nil
    }

    private func ensureAssistantMessage(for itemId: String?) -> Int {
        if let itemId,
           let id = assistantMessageIdsByItemId[itemId],
           let index = messages.firstIndex(where: { $0.id == id }) {
            return index
        }

        if let id = activeAssistantMessageId,
           let index = messages.firstIndex(where: { $0.id == id }),
           messages[index].role == .assistant,
           messages[index].pending {
            if let itemId {
                assistantMessageIdsByItemId[itemId] = id
            }
            return index
        }

        let id = "assistant-\(itemId ?? UUID().uuidString)"
        messages.append(ChatMessage(id: id, role: .assistant, text: "", pending: true))
        activeAssistantMessageId = id
        if let itemId {
            assistantMessageIdsByItemId[itemId] = id
        }
        return messages.index(before: messages.endIndex)
    }

    private func appendReasoningDelta(_ delta: String?, itemId: String?, isSummary: Bool) {
        guard let delta, !delta.isEmpty else { return }
        setActiveTurnStatus(.thinking)
        let index = ensureAssistantMessage(for: itemId)
        if isSummary {
            messages[index].reasoningSummaryText = (messages[index].reasoningSummaryText ?? "") + delta
        } else {
            messages[index].reasoningText = (messages[index].reasoningText ?? "") + delta
        }
        messages[index].pending = true
    }

    private func appendToolOutput(_ delta: String?, itemId: String?) {
        guard let delta, !delta.isEmpty else { return }
        let index = ensureAssistantMessage(for: itemId)
        messages[index].toolOutputText = (messages[index].toolOutputText ?? "") + delta
        messages[index].pending = true
    }

    private static func streamText(from params: [String: Any]?) -> String? {
        guard let params else { return nil }
        for key in ["delta", "text", "chunk", "output", "message"] {
            if let text = params[key] as? String { return text }
        }
        for key in ["output", "data", "terminalInteraction"] {
            if let nested = params[key] as? [String: Any],
               let text = streamText(from: nested) {
                return text
            }
        }
        return nil
    }

    func flushPersistence() {
        persistCurrentChat()
        saveSession()
    }

    func shutdown() {
        persistCurrentChat()
        persistence.saveImmediately(snapshot())
        bootGeneration += 1   // ignore the deliberate close handler
        let client = rpc
        rpc = nil
        threadId = nil
        resetTurnCancellation()
        isReady = false
        turnRunning = false
        booted = false
        setTaskStatus(.startingCodex)
        Task { await client?.close() }
        supervisor.stop()
    }

    // MARK: - Local session persistence

    private func restoreSession() {
        let stored: PersistedSession
        switch persistence.load() {
        case .empty:
            refreshRecentChats()
            return
        case .corrupt(let detail):
            persistence.quarantineCorruptFile()
            refreshRecentChats()
            errorCenter.present(.sessionDataCorrupt(detail: detail))
            return
        case .session(let session):
            stored = session
        }

        selectedModel = canonicalModelLabel(for: stored.selectedModel) ?? selectedModel
        reasoning = stored.reasoning
        selectedPermission = stored.permission
        projectRecords = stored.projects
        dismissedProjectPaths = Set(stored.dismissedProjectPaths ?? [])
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
            if let selectedProjectId { applyProjectDefaults(selectedProjectId) }
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
        resetTurnCancellation()
        chatTitle = chat.title
        messages = chat.messages
        selectedModel = canonicalModelLabel(for: chat.model) ?? selectedModel
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
            gitBranches = []
            activeProjectMissing = false
            return
        }

        selectedFolderPath = project.path
        selectedFolderName = project.displayName
        activeProjectMissing = !project.folderExists
        // Show the cached branch immediately; refresh in the background.
        gitBranch = project.cachedGitBranch
        gitBranches = []

        // A missing folder can't be a git repo — skip the probe and keep the
        // warning visible.
        guard !activeProjectMissing else { return }

        let folder = project.folderURL
        let projectId = project.id
        Task {
            let branch = await Self.gitBranch(at: folder)
            guard self.selectedProjectId == projectId else { return }
            gitBranch = branch
            cacheGitBranch(branch, for: projectId)
            let branches = await Self.gitBranches(at: folder)
            guard self.selectedProjectId == projectId else { return }
            gitBranches = branches
        }
    }

    /// Checks out a different branch in the active project. Non-destructive: git
    /// refuses a switch that would lose changes, and we surface that as a banner.
    func switchGitBranch(_ name: String) {
        guard let folderPath = selectedFolderPath, let projectId = selectedProjectId, name != gitBranch else { return }
        let folder = URL(fileURLWithPath: folderPath)
        Task {
            let (ok, message) = await Self.switchBranch(name, at: folder)
            guard self.selectedProjectId == projectId else { return }
            if ok {
                gitBranch = name
                cacheGitBranch(name, for: projectId)
                gitBranches = await Self.gitBranches(at: folder)
            } else {
                errorCenter.present(.gitSwitchFailed(detail: message))
            }
        }
    }

    /// Persists the freshly-probed branch onto its project so the next open
    /// shows it instantly. No-ops when unchanged to avoid redundant writes.
    private func cacheGitBranch(_ branch: String?, for projectId: String) {
        guard let index = projectRecords.firstIndex(where: { $0.id == projectId }),
              projectRecords[index].cachedGitBranch != branch else { return }
        projectRecords[index].cachedGitBranch = branch
        saveSession()
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

    /// Maps a folder to its project, creating one if this path is new. Dedupes
    /// strictly by standardized path so the same folder never spawns duplicates.
    private func upsertProject(for folder: URL) -> String {
        let path = folder.path
        let name = folder.lastPathComponent.isEmpty ? path : folder.lastPathComponent

        if let index = projectRecords.firstIndex(where: { $0.path == path }) {
            projectRecords[index].name = name
            projectRecords[index].lastOpenedAt = Date()
            return projectRecords[index].id
        }

        let now = Date()
        let project = Project(
            id: UUID().uuidString,
            name: name,
            path: path,
            createdAt: now,
            lastOpenedAt: now,
            defaultPermission: selectedPermission,
            lastModel: selectedModel,
            lastReasoning: reasoning
        )
        projectRecords.append(project)
        return project.id
    }

    // MARK: - Codex integration

    /// Seeds Modex's project list from Codex's trusted folders
    /// (`~/.codex/config.toml`), so projects you already work on in Codex show
    /// up here. Idempotent: dedupes by path and skips folders gone from disk.
    private func importCodexProjects() {
        let known = Set(projectRecords.map(\.path))
        let epoch = Date(timeIntervalSince1970: 0) // unopened-in-Modex → sorts below real recents
        let home = FileManager.default.homeDirectoryForCurrentUser
            .resolvingSymlinksInPath().standardizedFileURL.path
        // Codex auto-creates a dated working dir per conversation here; those are
        // not durable projects, so they'd just be noise in the list.
        let scratchRoot = home + "/Documents/Codex/"
        var added = false

        for rawPath in Self.codexTrustedProjectPaths() {
            let url = URL(fileURLWithPath: rawPath).resolvingSymlinksInPath().standardizedFileURL
            let path = url.path
            guard !known.contains(path),
                  !projectRecords.contains(where: { $0.path == path }),
                  !dismissedProjectPaths.contains(path),  // user removed it — don't resurrect
                  FileManager.default.fileExists(atPath: path),
                  path != home,                    // the whole home dir isn't a project
                  !path.hasPrefix(scratchRoot)      // skip per-conversation scratch dirs
            else { continue }

            let name = url.lastPathComponent.isEmpty ? path : url.lastPathComponent
            projectRecords.append(Project(
                id: UUID().uuidString,
                name: name,
                path: path,
                createdAt: epoch,
                lastOpenedAt: epoch
            ))
            added = true
        }

        if added { saveSession() }
    }

    /// Parses `~/.codex/config.toml` for `[projects."<path>"]` tables marked
    /// `trust_level = "trusted"`. Hand-rolled (no TOML dependency) and tolerant:
    /// any parse miss just yields fewer paths, never a throw.
    private static func codexTrustedProjectPaths() -> [String] {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/config.toml")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }

        var paths: [String] = []
        var pendingPath: String?

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                // A new table header — only [projects."..."] arms a candidate.
                pendingPath = projectTableHeaderPath(line)
            } else if let path = pendingPath,
                      line.replacingOccurrences(of: " ", with: "").lowercased().hasPrefix("trust_level=\"trusted\"") {
                paths.append(path)
                pendingPath = nil
            }
        }
        return paths
    }

    /// Extracts `<path>` from a `[projects."<path>"]` TOML header, or nil.
    private static func projectTableHeaderPath(_ line: String) -> String? {
        guard line.hasPrefix("[projects.\""), let open = line.range(of: "\"") else { return nil }
        let rest = line[open.upperBound...]
        guard let close = rest.range(of: "\"") else { return nil }
        return String(rest[..<close.lowerBound])
    }

    /// Opens a Codex thread as the live conversation by resuming it — history is
    /// loaded and subsequent turns continue the same thread.
    private func openCodexThread(_ id: String) {
        guard let rpc else { return }
        persistCurrentChat()
        Task {
            do {
                let result = try await rpc.request("thread/resume", params: ["threadId": id]) as? [String: Any]
                guard let result, let thread = result["thread"] as? [String: Any] else {
                    if isReady { setTaskStatus(.ready) }
                    return
                }
                threadId = id
                selectedChatId = id
                resetTurnCancellation()
                messages = Self.messages(fromThread: thread)
                chatTitle = Self.threadTitle(thread)
                if let model = result["model"] as? String, let label = canonicalModelLabel(for: model) {
                    selectedModel = label
                }
                if let effort = result["reasoningEffort"] as? String, let level = ReasoningEffort(rawValue: effort) {
                    reasoning = level
                }
                if isReady { setTaskStatus(.ready) }
                refreshRecentChats()
                saveSession()
            } catch {
                if isReady { setTaskStatus(.ready) }
                errorCenter.present(.threadStartFailed(detail: error.localizedDescription)) {
                    [weak self] in self?.openCodexThread(id)
                }
            }
        }
    }

    private static func threadSummary(_ thread: [String: Any]) -> CodexThreadSummary? {
        guard let id = thread["id"] as? String, !id.isEmpty else { return nil }
        let updatedAt: Date = {
            if let seconds = thread["updatedAt"] as? Double { return Date(timeIntervalSince1970: seconds) }
            if let seconds = thread["updatedAt"] as? Int { return Date(timeIntervalSince1970: Double(seconds)) }
            return Date(timeIntervalSince1970: 0)
        }()
        return CodexThreadSummary(id: id, title: threadTitle(thread), updatedAt: updatedAt)
    }

    private static func threadTitle(_ thread: [String: Any]) -> String {
        if let name = (thread["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if let preview = thread["preview"] as? String, let title = generatedTitle(from: preview) {
            return title
        }
        return untitledChatTitle
    }

    /// Flattens a resumed thread's turns into displayable messages. Keeps the
    /// readable user/assistant exchange; transient detail (reasoning, command
    /// output) is left out of restored history.
    private static func messages(fromThread thread: [String: Any]) -> [ChatMessage] {
        guard let turns = thread["turns"] as? [[String: Any]] else { return [] }
        var result: [ChatMessage] = []
        for turn in turns {
            for item in (turn["items"] as? [[String: Any]]) ?? [] {
                guard let type = item["type"] as? String, let itemId = item["id"] as? String else { continue }
                switch type {
                case "userMessage":
                    let text = ((item["content"] as? [[String: Any]]) ?? [])
                        .compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
                        .joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { result.append(ChatMessage(id: "u-\(itemId)", role: .user, text: text)) }
                case "agentMessage":
                    let text = (item["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { result.append(ChatMessage(id: "a-\(itemId)", role: .assistant, text: text)) }
                default:
                    break
                }
            }
        }
        return result
    }

    /// Recent chats scoped to the active project. Chats with no project (e.g.
    /// Read-only sessions started without a folder) surface only when no project
    /// is active, so a chat is always grouped under the workspace it belongs to.
    /// Kicks a refresh of the active project's threads after state changes
    /// (sends, opens). Per-project lists are computed, so nothing else to rebuild.
    private func refreshRecentChats() {
        if let id = selectedProjectId { loadProjectThreads(id) }
    }

    /// Chats shown nested under a project when it's unfolded — its Codex threads,
    /// plus the active project's current unsent draft pinned on top.
    func projectChats(_ projectId: String) -> [RecentChat] {
        guard let project = projectRecords.first(where: { $0.id == projectId }) else { return [] }
        var rows = (threadsByProjectPath[project.path] ?? [])
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { RecentChat(id: $0.id, title: $0.title, timeAgo: Self.timeAgo(from: $0.updatedAt)) }
        if projectId == selectedProjectId, threadId == nil, messages.isEmpty, let draftId = selectedChatId,
           !rows.contains(where: { $0.id == draftId }) {
            rows.insert(RecentChat(id: draftId, title: chatTitle, timeAgo: "Just now"), at: 0)
        }
        return rows
    }

    /// Chats made without a folder (the folderless "Chats" section). Local-only;
    /// Codex's folderless threads aren't surfaced (their cwd is ambiguous).
    var folderlessChats: [RecentChat] {
        chatRecords
            .filter { $0.projectId == nil }
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { RecentChat(id: $0.id, title: $0.title, timeAgo: Self.timeAgo(from: $0.updatedAt)) }
    }

    /// Whether to show the folderless "Chats" section at all.
    var showFolderlessChats: Bool { !isInProject || !folderlessChats.isEmpty }

    /// Loads a project's Codex threads (by folder). Per-path in-flight guard lets
    /// projects load independently; a failed fetch keeps any cached list.
    func loadProjectThreads(_ projectId: String) {
        guard isReady, let rpc,
              let project = projectRecords.first(where: { $0.id == projectId }),
              project.folderExists,
              !loadingProjectPaths.contains(project.path) else { return }
        let path = project.path
        loadingProjectPaths.insert(path)
        Task {
            let result = try? await rpc.request("thread/list", params: [
                "cwd": path,
                "limit": 100,
                "useStateDbOnly": true,
            ]) as? [String: Any]
            loadingProjectPaths.remove(path)
            guard let result else { return }   // failed — keep cached list
            let data = result["data"] as? [[String: Any]] ?? []
            threadsByProjectPath[path] = data.compactMap(Self.threadSummary)
        }
    }

    /// Opens a chat under a project — switching the active project first if the
    /// chat belongs to a different one, then resuming the thread.
    func openProjectChat(projectId: String, threadId id: String) {
        guard !turnRunning, id != selectedChatId else { return }
        if projectId != selectedProjectId, projectRecords.contains(where: { $0.id == projectId }) {
            persistCurrentChat()
            selectedProjectId = projectId
            applyProjectDefaults(projectId)
            applySelectedProject()
            if let index = projectRecords.firstIndex(where: { $0.id == projectId }) {
                projectRecords[index].lastOpenedAt = Date()
            }
            saveSession()
        }
        openCodexThread(id)
    }

    /// Starts a fresh chat in a specific project (used by the per-project
    /// "New chat" row), switching to it first if needed.
    func startNewChatInProject(_ projectId: String) {
        guard !turnRunning else { return }
        if projectId != selectedProjectId { switchToProject(projectId) }
        startNewChat()
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
            dismissedProjectPaths: dismissedProjectPaths.isEmpty ? nil : Array(dismissedProjectPaths),
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

/// A row in the sidebar's Projects list.
struct ProjectSummary: Identifiable, Hashable {
    let id: String
    let name: String
    let path: String
    /// Backing folder no longer exists on disk — shown with a warning glyph.
    let isMissing: Bool
}

/// A Codex thread surfaced as a chat in the sidebar.
struct CodexThreadSummary: Identifiable, Hashable {
    let id: String
    let title: String
    let updatedAt: Date
}

private struct PersistedSession: Codable {
    var version: Int
    var selectedChatId: String?
    var selectedProjectId: String?
    var lastActiveProjectId: String?
    var selectedModel: String
    var reasoning: ReasoningEffort
    var permission: PermissionMode
    var projects: [Project]
    /// Optional (added later) — folders the user removed from the sidebar.
    /// Decodes to nil for sessions written before this field existed.
    var dismissedProjectPaths: [String]?
    var chats: [PersistedChat]
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

    enum LoadOutcome {
        case empty
        case session(PersistedSession)
        case corrupt(String)
    }

    func load() -> LoadOutcome {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }

        do {
            let data = try Data(contentsOf: url)
            return .session(try decoder.decode(PersistedSession.self, from: data))
        } catch {
            logger.error("Could not load persisted Modex session at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .corrupt(error.localizedDescription)
        }
    }

    /// Moves an unreadable session file aside so the next launch starts clean
    /// without losing the original data for inspection.
    func quarantineCorruptFile() {
        let url = fileURL
        let quarantined = url.deletingLastPathComponent().appendingPathComponent("session-corrupt.json")
        try? FileManager.default.removeItem(at: quarantined)
        do {
            try FileManager.default.moveItem(at: url, to: quarantined)
            logger.error("Quarantined corrupt session to \(quarantined.path, privacy: .public)")
        } catch {
            logger.error("Could not quarantine corrupt session: \(error.localizedDescription, privacy: .public)")
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
