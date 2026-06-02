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
    private var pending: [Int: CheckedContinuation<Any?, Error>] = [:]
    private var closed = false

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

    /// Sends a request and awaits its `result` payload (or throws on RPC error).
    @discardableResult
    func request(_ method: String, params: [String: Any]) async throws -> Any? {
        let id = nextId
        nextId += 1

        let envelope: [String: Any] = [
            "jsonrpc": "2.0", "id": id, "method": method, "params": params,
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        let text = String(decoding: data, as: UTF8.self)

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task {
                do {
                    try await task.send(.string(text))
                } catch {
                    pending[id] = nil
                    continuation.resume(throwing: error)
                }
            }
        }
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
            guard let continuation = pending.removeValue(forKey: id) else { return }
            if let error = object["error"] as? [String: Any] {
                let msg = error["message"] as? String ?? "Codex error."
                continuation.resume(throwing: CodexError.message(msg))
            } else {
                continuation.resume(returning: object["result"])
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
        for (_, continuation) in waiting {
            continuation.resume(throwing: CodexError.message(message))
        }
    }
}
