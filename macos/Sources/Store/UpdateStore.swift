import AppKit
import Foundation
import Observation

/// Self-updater: periodically compares the local checkout against `origin/main`
/// and, when behind, lets the user pull + rebuild + relaunch in one click —
/// the "Update" affordance near the account row.
///
/// Adapted from the engine direction Codex prototyped; hardened with an explicit
/// PATH so `git`/`xcodegen`/`xcodebuild` resolve even when launched from Finder.
@MainActor
@Observable
final class UpdateStore {
    private(set) var isUpdateAvailable = false
    private(set) var isChecking = false
    private(set) var isUpdating = false
    private(set) var message: String?

    private var repoRoot: URL?
    private var checkTask: Task<Void, Never>?

    /// Tightened from 5 min → 20 s so a freshly-pushed change is noticed quickly.
    private let pollIntervalNanos: UInt64 = 20_000_000_000

    private static let toolPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

    func start() {
        guard checkTask == nil else { return }
        checkTask = Task {
            await checkForUpdates()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: pollIntervalNanos)
                await checkForUpdates()
            }
        }
    }

    func stop() {
        checkTask?.cancel()
        checkTask = nil
    }

    func checkForUpdates() async {
        guard !isUpdating else { return }
        isChecking = true
        defer { isChecking = false }

        do {
            let repo = try await resolveRepoRoot()
            repoRoot = repo
            try await runGit(["fetch", "origin"], in: repo)

            let upstream = try await runGit(
                ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], in: repo
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            let local = try await runGit(["rev-parse", "HEAD"], in: repo)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let remote = try await runGit(["rev-parse", upstream], in: repo)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            isUpdateAvailable = local != remote
            message = nil
        } catch {
            isUpdateAvailable = false
            message = error.localizedDescription
        }
    }

    func installUpdate() {
        guard !isUpdating else { return }
        Task {
            do {
                let repo = try await resolveRepoRoot()
                try launchUpdater(in: repo)
                isUpdating = true
                NSApp.terminate(nil)
            } catch {
                isUpdating = false
                message = error.localizedDescription
            }
        }
    }

    // MARK: - Repo discovery

    private func resolveRepoRoot() async throws -> URL {
        if let repoRoot { return repoRoot }

        let env = ProcessInfo.processInfo.environment
        var candidates: [URL] = []
        if let path = env["MODEX_REPO_PATH"], !path.isEmpty {
            candidates.append(URL(fileURLWithPath: path))
        }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        candidates.append(Bundle.main.bundleURL)
        candidates.append(FileManager.default.homeDirectoryForCurrentUser.appending(path: "Desktop/Modex"))

        for candidate in candidates {
            if let repo = repoRoot(containing: candidate) { return repo }
        }
        throw UpdateError.repoNotFound
    }

    private func repoRoot(containing candidate: URL) -> URL? {
        var current = candidate.standardizedFileURL
        while current.path != "/" {
            if FileManager.default.fileExists(atPath: current.appending(path: ".git").path) {
                return current
            }
            current.deleteLastPathComponent()
        }
        return nil
    }

    // MARK: - Process helpers

    @discardableResult
    private func runGit(_ arguments: [String], in directory: URL) async throws -> String {
        try await runProcess("/usr/bin/git", arguments: arguments, in: directory)
    }

    private func launchUpdater(in repo: URL) throws {
        let script = repo.appending(path: "script/install_macos_app.sh")
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw UpdateError.updaterMissing
        }

        let logURL = URL(fileURLWithPath: "/tmp/modex-update.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        log.seekToEndOfFile()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [script.path, "--pull", "--relaunch", "--delay", "1"]
        process.currentDirectoryURL = repo
        process.environment = environment(repo: repo)
        process.standardOutput = log
        process.standardError = log
        try process.run()
    }

    private func environment(repo: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(Self.toolPath):\(env["PATH"] ?? "")"
        env["MODEX_REPO_PATH"] = repo.path
        return env
    }

    private func runProcess(_ executable: String, arguments: [String], in directory: URL) async throws -> String {
        let env = environment(repo: directory)
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let output = Pipe()
            let error = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = directory
            process.environment = env
            process.standardOutput = output
            process.standardError = error
            process.terminationHandler = { proc in
                let outText = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let errText = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: outText)
                } else {
                    continuation.resume(throwing: UpdateError.commandFailed(errText.isEmpty ? outText : errText))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}

private enum UpdateError: LocalizedError {
    case repoNotFound, updaterMissing, commandFailed(String)
    var errorDescription: String? {
        switch self {
        case .repoNotFound: return "Could not find the Modex git repository."
        case .updaterMissing: return "Could not find the Modex updater script."
        case .commandFailed(let m): return m.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
