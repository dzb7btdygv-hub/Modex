import Foundation

/// Minimal JSON-RPC 2.0 client over a WebSocket, talking to the Codex
/// app-server. Native equivalent of the former `CodexRpc` TypeScript class.
///
/// Codex speaks three message shapes:
///   • responses   — carry `id` + `result`/`error`   → resolve a pending request
///   • notifications — carry `method`, no `id`        → forwarded to the UI
///   • server requests — carry `id` + `method`        → answered with safe defaults
actor CodexRPCClient {
    typealias NotificationHandler = @MainActor (String, [String: Any]?) -> Void
    typealias CloseHandler = @MainActor (String) -> Void
    typealias ServerRequestHandler = @MainActor (String, Bool) -> Void

    private let task: URLSessionWebSocketTask
    private let onNotification: NotificationHandler
    private let onClose: CloseHandler
    private let onServerRequest: ServerRequestHandler?

    private var nextId = 1
    private var pending: [Int: Pending] = [:]
    private var closed = false

    /// A request awaiting its response, paired with the timeout task that fails
    /// it if Codex never replies (a hang, as opposed to a socket close).
    private struct Pending {
        let continuation: CheckedContinuation<Any?, Error>
        let timeout: Task<Void, Never>
    }

    /// Default ceiling for a single request. Codex acknowledges `turn/start`
    /// promptly (the model's work streams back as notifications), so every RPC
    /// is expected to answer well within this window; exceeding it means the
    /// engine is wedged and the caller should recover rather than hang forever.
    private static let defaultTimeout: Duration = .seconds(120)

    init(
        url: URL,
        onNotification: @escaping NotificationHandler,
        onClose: @escaping CloseHandler,
        onServerRequest: ServerRequestHandler? = nil
    ) {
        self.task = URLSession.shared.webSocketTask(with: url)
        self.onNotification = onNotification
        self.onClose = onClose
        self.onServerRequest = onServerRequest
        self.task.resume()
        Task { await self.receiveLoop() }
    }

    /// Sends a request and awaits its `result` payload (or throws on RPC error,
    /// socket close, or timeout).
    @discardableResult
    func request(_ method: String, params: [String: Any], timeout: Duration = CodexRPCClient.defaultTimeout) async throws -> Any? {
        let id = nextId
        nextId += 1

        let envelope: [String: Any] = [
            "jsonrpc": "2.0", "id": id, "method": method, "params": params,
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        let text = String(decoding: data, as: UTF8.self)

        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                await self?.expire(id, method: method)
            }
            pending[id] = Pending(continuation: continuation, timeout: timeoutTask)
            Task {
                do {
                    try await task.send(.string(text))
                } catch {
                    finish(id, with: .failure(error))
                }
            }
        }
    }

    /// Resolves a pending request, cancelling its timeout. No-op if it already
    /// resolved (response, timeout, or close raced first), so it never
    /// double-resumes a continuation.
    private func finish(_ id: Int, with result: Result<Any?, Error>) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.timeout.cancel()
        entry.continuation.resume(with: result)
    }

    /// Fails a request whose response never arrived within its timeout window.
    private func expire(_ id: Int, method: String) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.continuation.resume(throwing: CodexError.message("Codex didn’t respond to “\(method)” in time."))
    }

    func close() {
        guard !closed else { return }
        closed = true
        task.cancel(with: .goingAway, reason: nil)
        failPending("Codex disconnected.")
    }

    // MARK: - Receive loop

    private func receiveLoop() async {
        while !closed {
            do {
                let message = try await task.receive()
                switch message {
                case .string(let text): await handle(text)
                case .data(let data): await handle(String(decoding: data, as: UTF8.self))
                @unknown default: break
                }
            } catch {
                guard !closed else { return }
                closed = true
                failPending("Codex disconnected.")
                let handler = onClose
                Task { @MainActor in handler("Codex disconnected.") }
                return
            }
        }
    }

    private func handle(_ text: String) async {
        guard
            let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        let id = object["id"] as? Int

        // Response to one of our requests.
        if let id, object["result"] != nil || object["error"] != nil {
            if let error = object["error"] as? [String: Any] {
                let msg = error["message"] as? String ?? "Codex error."
                finish(id, with: .failure(CodexError.message(msg)))
            } else {
                finish(id, with: .success(object["result"]))
            }
            return
        }

        guard let method = object["method"] as? String else { return }

        // Server-initiated request (needs a reply) vs. fire-and-forget notification.
        if let id {
            await notifyServerRequest(method, started: true)
            respondToServerRequest(id: id, method: method)
            await notifyServerRequest(method, started: false)
        } else {
            let params = object["params"] as? [String: Any]
            let handler = onNotification
            Task { @MainActor in handler(method, params) }
        }
    }

    private func notifyServerRequest(_ method: String, started: Bool) async {
        guard let handler = onServerRequest else { return }
        await handler(method, started)
    }

    private func respondToServerRequest(id: Int, method: String) {
        let result = Self.defaultServerResponse(for: method)
        let envelope: [String: Any]
        if let result {
            envelope = ["jsonrpc": "2.0", "id": id, "result": result]
        } else {
            envelope = [
                "jsonrpc": "2.0", "id": id,
                "error": ["code": -32601, "message": "\(method) is not supported by Modex yet."],
            ]
        }
        guard
            let data = try? JSONSerialization.data(withJSONObject: envelope)
        else { return }
        let text = String(decoding: data, as: UTF8.self)
        Task { try? await task.send(.string(text)) }
    }

    /// Mirrors the safe defaults from the TypeScript client: decline approvals,
    /// supply empty tool results, so an unattended turn never hangs.
    private static func defaultServerResponse(for method: String) -> [String: Any]? {
        switch method {
        case "item/commandExecution/requestApproval",
             "item/fileChange/requestApproval":
            return ["decision": "decline"]
        case "item/permissions/requestApproval":
            return ["permissions": [:], "scope": "turn", "strictAutoReview": true]
        case "item/tool/requestUserInput":
            return ["answers": [:]]
        case "mcpServer/elicitation/request":
            return ["action": "decline", "content": NSNull(), "_meta": NSNull()]
        case "item/tool/call":
            return ["contentItems": [], "success": false]
        case "applyPatchApproval", "execCommandApproval":
            return ["decision": "denied"]
        default:
            return nil
        }
    }

    private func failPending(_ message: String) {
        let waiting = pending
        pending.removeAll()
        for (_, entry) in waiting {
            entry.timeout.cancel()
            entry.continuation.resume(throwing: CodexError.message(message))
        }
    }
}
