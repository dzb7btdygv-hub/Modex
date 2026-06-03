import AppKit
import Foundation
import Observation
import OSLog

/// Self-updater: periodically compares the installed app build against
/// `origin/main` and, when behind, lets the user pull + rebuild + relaunch in
/// one click — the "Update" affordance near the account row.
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

    /// Whether this copy can honestly update itself. The updater rebuilds from a
    /// source checkout, so it only works when Modex is running from one with the
    /// build toolchain (xcodegen + xcodebuild) and the install script present. A
    /// shipped/standalone bundle can't, so the Update affordance stays hidden.
    private(set) var canSelfUpdate = false

    /// User-facing update failure, shown as a compact chip near the update
    /// control rather than the app-wide error banner. `nil` when healthy.
    private(set) var updateError: ModexError?

    private let logger = Logger(subsystem: "dev.modex.desktop", category: "UpdateStore")

    /// Dynamic version, e.g. "v1.53". Derived from how much source has actually
    /// changed (cumulative git lines ÷ 1000): a tiny edit nudges the decimals, a
    /// big feature jumps the whole number. No manual bumping, no flat +1.
    private(set) var versionString = ""

    private var repoRoot: URL?
    private var checkTask: Task<Void, Never>?

    /// Polls for upstream changes every 5 minutes. This spawns `git fetch` plus a
    /// few `rev-parse` subprocesses, so it stays in the minutes range rather than
    /// hammering the remote; it only runs at all on a self-updatable source build.
    private let pollIntervalNanos: UInt64 = 300_000_000_000

    private static let toolPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    private static let installedCommitKey = "ModexSourceCommit"

    func start() {
        guard checkTask == nil else { return }
        checkTask = Task {
            await refreshCapability()
            await computeVersion()
            // Don't poll the remote at all unless this build can actually update
            // itself — a shipped copy has no honest update path.
            guard canSelfUpdate else { return }
            await checkForUpdates()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: pollIntervalNanos)
                await checkForUpdates()
            }
        }
    }

    /// Determines whether self-update is possible in this environment: a source
    /// checkout (install script present) plus the build toolchain on PATH.
    private func refreshCapability() async {
        let repo = try? await resolveRepoRoot()
        let hasScript = repo.map {
            FileManager.default.fileExists(atPath: $0.appending(path: "script/install_macos_app.sh").path)
        } ?? false
        canSelfUpdate = hasScript && Self.toolExists("xcodegen") && Self.toolExists("xcodebuild")
    }

    private static func toolExists(_ name: String) -> Bool {
        toolPath.split(separator: ":").contains {
            FileManager.default.isExecutableFile(atPath: String($0) + "/" + name)
        }
    }

    /// Recomputes the displayed version from the current checkout's git history.
    func computeVersion() async {
        do {
            let repo = try await resolveRepoRoot()
            let out = try await runGit(
                ["log", "--pretty=format:", "--numstat", "--", "macos/Sources", "macos/project.yml"],
                in: repo
            )
            var total = 0
            for line in out.split(separator: "\n") {
                let cols = line.split(separator: "\t")
                guard cols.count >= 2, let added = Int(cols[0]), let deleted = Int(cols[1]) else { continue }
                total += added + deleted
            }
            if total > 0 {
                versionString = String(format: "v%.2f", Double(total) / 1000.0)
            }
        } catch {
            // Leave the previous value; the version label simply stays hidden.
        }
    }

    func stop() {
        checkTask?.cancel()
        checkTask = nil
    }

    func checkForUpdates() async {
        guard !isUpdating, canSelfUpdate else { return }
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

            if let installed = installedSourceCommit() {
                isUpdateAvailable = installed != remote
            } else {
                // No build stamp to compare against — fall back to the checkout's
                // own HEAD vs its upstream, instead of assuming every unstamped
                // build is out of date (which nagged on each plain xcodebuild).
                isUpdateAvailable = local != remote
            }
            message = nil
            updateError = nil
        } catch {
            isUpdateAvailable = false
            message = error.localizedDescription
            logger.error("Update check failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func installUpdate() {
        guard !isUpdating else { return }
        updateError = nil
        Task {
            do {
                let repo = try await resolveRepoRoot()
                try launchUpdater(in: repo)
                isUpdating = true
                NSApp.terminate(nil)
            } catch {
                isUpdating = false
                message = error.localizedDescription
                updateError = .updateInstallFailed(detail: error.localizedDescription)
                logger.error("Update install failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Re-runs whichever update step last failed. Backs the chip's retry control.
    func retryAfterError() {
        guard let updateError else { return }
        self.updateError = nil
        if updateError.kind == .updateInstallFailed {
            installUpdate()
        } else {
            Task { await checkForUpdates() }
        }
    }

    func dismissError() {
        updateError = nil
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

    private func installedSourceCommit() -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: Self.installedCommitKey) as? String else {
            return nil
        }
        let commit = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return commit.isEmpty ? nil : commit
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
