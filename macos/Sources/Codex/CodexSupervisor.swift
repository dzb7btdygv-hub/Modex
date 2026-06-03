import Foundation
import Observation
import OSLog

/// Lifecycle phases for the bundled Codex `app-server`.
enum CodexPhase: Equatable {
    case stopped
    case starting
    case running
}

/// Spawns and supervises the bundled `codex app-server` process, parsing its
/// stdout to discover the local WebSocket endpoint.
///
/// This is the native replacement for the former Tauri Rust supervisor: a plain
/// `Process` plus a `Pipe` reader. No webview, no IPC bridge.
@MainActor
@Observable
final class CodexSupervisor {
    private(set) var phase: CodexPhase = .stopped
    private(set) var wsURL: URL?
    private(set) var message: String = "Idle."

    /// Invoked when the engine terminates *unexpectedly* after a successful
    /// launch (i.e. not via ``stop()``). Lets the orchestrator surface a crash.
    var onUnexpectedExit: (@MainActor (Int32) -> Void)?

    private var process: Process?
    private var stdoutBuffer = ""
    private var stoppedIntentionally = false
    private let logger = Logger(subsystem: "dev.modex.desktop", category: "CodexSupervisor")

    /// Locates the Codex helper binary. In a packaged build it lives inside the
    /// app bundle's Resources; during development we fall back to the repo copy
    /// or an explicit override via `MODEX_CODEX_BINARY`.
    private static func locateBinary() -> URL? {
        if let override = ProcessInfo.processInfo.environment["MODEX_CODEX_BINARY"] {
            return URL(fileURLWithPath: override)
        }
        if let bundled = Bundle.main.url(forResource: "codex-aarch64-apple-darwin", withExtension: nil) {
            return bundled
        }
        // Development fallback: walk up from the bundle to the repo's src-tauri copy.
        let repoCopy = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("src-tauri/binaries/codex-aarch64-apple-darwin")
        return FileManager.default.fileExists(atPath: repoCopy.path) ? repoCopy : nil
    }

    /// Launches the Codex app-server and resolves once it advertises a loopback
    /// WebSocket endpoint, or throws on failure / timeout.
    @discardableResult
    func start() async throws -> URL {
        guard phase == .stopped else {
            if let url = wsURL { return url }
            throw ModexError.sidecarLaunchFailed(detail: "Codex is already starting.")
        }

        guard let binary = Self.locateBinary() else {
            phase = .stopped
            message = "Could not find the Codex engine binary."
            logger.error("Codex engine binary not found in bundle or repo fallback.")
            throw ModexError.codexBinaryMissing()
        }

        // The binary may lose its executable bit when copied as a bundle resource.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: binary.path
        )

        phase = .starting
        message = "Starting the Codex engine…"
        stoppedIntentionally = false
        wsURL = nil
        stdoutBuffer = ""

        let process = Process()
        process.executableURL = binary
        process.arguments = ["app-server", "--listen", "ws://127.0.0.1:0"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        // Stream parsing happens on the file handle's background queue; hop back
        // to the main actor to mutate observable state.
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.ingest(chunk) }
        }

        process.terminationHandler = { [weak self] proc in
            Task { @MainActor in self?.handleTermination(code: proc.terminationStatus) }
        }

        do {
            try process.run()
        } catch {
            phase = .stopped
            message = "Failed to launch Codex: \(error.localizedDescription)"
            logger.error("Codex engine failed to launch: \(error.localizedDescription, privacy: .public)")
            throw ModexError.sidecarLaunchFailed(detail: error.localizedDescription)
        }
        self.process = process

        // Wait (up to 12s) for the `listening on:` line to be parsed.
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            if let url = wsURL {
                phase = .running
                message = "Codex engine is running."
                return url
            }
            if phase == .stopped {
                // The process exited during startup; `message` holds the last stderr line.
                logger.error("Codex engine exited during startup: \(self.message, privacy: .public)")
                throw ModexError.sidecarLaunchFailed(detail: message)
            }
            try await Task.sleep(nanoseconds: 80_000_000)
        }

        logger.error("Codex engine did not advertise a WebSocket endpoint within 12s.")
        stop()
        throw ModexError.sidecarStartTimeout(detail: message)
    }

    func stop() {
        stoppedIntentionally = true
        process?.terminationHandler = nil
        if let pipe = process?.standardOutput as? Pipe {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        process?.terminate()
        process = nil
        phase = .stopped
        wsURL = nil
    }

    // MARK: - Stdout parsing

    private func ingest(_ chunk: String) {
        // The only line we parse is the startup "listening on:" endpoint. Once we
        // have it, stop accumulating: the pipe is already drained by the
        // readability handler (so the engine never blocks on a full pipe), and
        // retaining the rest of the engine's lifetime of stdout would grow without
        // bound.
        guard wsURL == nil else {
            if !stdoutBuffer.isEmpty { stdoutBuffer = "" }
            return
        }
        stdoutBuffer += chunk
        // Guard against a pathological no-newline stream growing unbounded before
        // the endpoint line arrives.
        if stdoutBuffer.utf8.count > 64_000 {
            stdoutBuffer = String(stdoutBuffer.suffix(4_000))
        }
        while let newline = stdoutBuffer.firstIndex(of: "\n") {
            let line = String(stdoutBuffer[..<newline])
            stdoutBuffer.removeSubrange(...newline)
            parse(line: line.trimmingCharacters(in: .whitespaces))
        }
    }

    private func parse(line: String) {
        guard let url = line.components(separatedBy: "listening on:").last.map({
            $0.trimmingCharacters(in: .whitespaces)
        }), line.hasPrefix("listening on:") else {
            if !line.isEmpty, line.hasPrefix("listening on:") == false,
               wsURL == nil, !line.hasPrefix("readyz:"), !line.hasPrefix("healthz:") {
                message = line
            }
            return
        }

        guard isLoopback(url), let parsed = URL(string: url) else {
            message = "Ignored a non-loopback Codex endpoint."
            return
        }
        wsURL = parsed
    }

    private func isLoopback(_ raw: String) -> Bool {
        guard let url = URL(string: raw), url.scheme == "ws", url.port != nil else { return false }
        return ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "")
    }

    private func handleTermination(code: Int32) {
        process = nil
        let wasRunning = phase != .stopped
        if wasRunning {
            phase = .stopped
            message = "Codex engine exited (status \(code))."
        }
        // An exit we didn't ask for, after a successful launch, is a crash.
        if wasRunning && !stoppedIntentionally {
            logger.error("Codex engine exited unexpectedly (status \(code)).")
            onUnexpectedExit?(code)
        }
    }
}

enum CodexError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}
