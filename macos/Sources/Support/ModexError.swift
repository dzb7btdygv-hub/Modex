import Foundation

/// A typed, user-facing error description.
///
/// `ModexError` is the single vocabulary the app uses to talk about failure. It
/// is intentionally framework-light (Foundation only) and purely descriptive —
/// it carries copy + severity, never a callback. Retry *behaviour* is supplied
/// by whoever presents the error through ``ErrorCenter``.
struct ModexError: Identifiable, Error {
    /// How loud the failure is, and therefore how it surfaces.
    /// `info`/`warning`/`error` ride an inline banner; `fatal` takes over the
    /// detail pane with a recovery screen.
    enum Severity: Int, Comparable {
        case info, warning, error, fatal
        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Stable internal identity for each failure path. Drives logging and lets
    /// callers reason about the error without string-matching the copy.
    enum Kind: String {
        case codexBinaryMissing
        case sidecarLaunchFailed
        case sidecarStartTimeout
        case sidecarCrashed
        case rpcConnectionFailed
        case rpcInitializeFailed
        case threadStartFailed
        case turnSendFailed
        case streamInterrupted
        case folderRequired
        case folderMissing
        case permissionDenied
        case notAuthenticated
        case updateCheckFailed
        case updateInstallFailed
        case sessionDataCorrupt
        case engineError
        case gitSwitchFailed
    }

    let id = UUID()
    var kind: Kind
    var title: String
    var explanation: String
    var suggestedAction: String?
    /// Raw underlying detail (error text / stderr). Kept out of the main UI and
    /// only revealed behind a disclosure + copy control.
    var technicalDetail: String?
    var severity: Severity
    var isRetryable: Bool
    /// Verb for the retry control, e.g. "Restart Codex", "Resend", "Try Again".
    var retryLabel: String?

    private static func trimmed(_ detail: String?) -> String? {
        guard let detail else { return nil }
        let value = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

// MARK: - Factories
//
// Copy lives here so every failure path reads the same way and stays easy to
// audit. Keep titles short, explanations one sentence, actions actionable.

extension ModexError {
    static func codexBinaryMissing(detail: String? = nil) -> ModexError {
        ModexError(
            kind: .codexBinaryMissing,
            title: "Codex engine not found",
            explanation: "Modex couldn’t locate the bundled Codex engine, so it can’t start a session.",
            suggestedAction: "Reinstall Modex, or set MODEX_CODEX_BINARY to a valid codex binary.",
            technicalDetail: trimmed(detail),
            severity: .fatal,
            isRetryable: true,
            retryLabel: "Try Again"
        )
    }

    static func sidecarLaunchFailed(detail: String?) -> ModexError {
        ModexError(
            kind: .sidecarLaunchFailed,
            title: "Couldn’t start the Codex engine",
            explanation: "The Codex engine failed to launch.",
            suggestedAction: "Try again. If it keeps failing, reinstall Modex.",
            technicalDetail: trimmed(detail),
            severity: .fatal,
            isRetryable: true,
            retryLabel: "Try Again"
        )
    }

    static func sidecarStartTimeout(detail: String? = nil) -> ModexError {
        ModexError(
            kind: .sidecarStartTimeout,
            title: "Codex engine didn’t respond",
            explanation: "The Codex engine started but never reported it was ready.",
            suggestedAction: "Try starting it again.",
            technicalDetail: trimmed(detail),
            severity: .fatal,
            isRetryable: true,
            retryLabel: "Try Again"
        )
    }

    static func sidecarCrashed(detail: String?) -> ModexError {
        ModexError(
            kind: .sidecarCrashed,
            title: "Lost connection to Codex",
            explanation: "The Codex engine stopped unexpectedly. Your chats are safe.",
            suggestedAction: "Restart the engine to keep working.",
            technicalDetail: trimmed(detail),
            severity: .error,
            isRetryable: true,
            retryLabel: "Restart Codex"
        )
    }

    static func rpcConnectionFailed(detail: String?) -> ModexError {
        ModexError(
            kind: .rpcConnectionFailed,
            title: "Couldn’t connect to Codex",
            explanation: "Modex started the engine but couldn’t open a connection to it.",
            suggestedAction: "Try connecting again.",
            technicalDetail: trimmed(detail),
            severity: .fatal,
            isRetryable: true,
            retryLabel: "Try Again"
        )
    }

    static func rpcInitializeFailed(detail: String?) -> ModexError {
        ModexError(
            kind: .rpcInitializeFailed,
            title: "Couldn’t initialize Codex",
            explanation: "The connection opened, but the Codex engine rejected the handshake.",
            suggestedAction: "Try again. If it persists, update Modex.",
            technicalDetail: trimmed(detail),
            severity: .fatal,
            isRetryable: true,
            retryLabel: "Try Again"
        )
    }

    static func threadStartFailed(detail: String?) -> ModexError {
        ModexError(
            kind: .threadStartFailed,
            title: "Couldn’t start the chat",
            explanation: "Codex couldn’t create a new conversation thread.",
            suggestedAction: "Send your message again.",
            technicalDetail: trimmed(detail),
            severity: .error,
            isRetryable: true,
            retryLabel: "Resend"
        )
    }

    static func turnSendFailed(detail: String?) -> ModexError {
        ModexError(
            kind: .turnSendFailed,
            title: "Message not sent",
            explanation: "Modex couldn’t deliver your message to Codex.",
            suggestedAction: "Send it again.",
            technicalDetail: trimmed(detail),
            severity: .error,
            isRetryable: true,
            retryLabel: "Resend"
        )
    }

    static func streamInterrupted(detail: String?) -> ModexError {
        ModexError(
            kind: .streamInterrupted,
            title: "Response interrupted",
            explanation: "The connection to Codex dropped while it was replying.",
            suggestedAction: "Restart the engine, then resend if needed.",
            technicalDetail: trimmed(detail),
            severity: .error,
            isRetryable: true,
            retryLabel: "Restart Codex"
        )
    }

    static func folderRequired() -> ModexError {
        ModexError(
            kind: .folderRequired,
            title: "Choose a project folder",
            explanation: "Write and Full access need a workspace folder so Codex knows where to work.",
            suggestedAction: "Pick a folder, or switch to Read only.",
            technicalDetail: nil,
            severity: .warning,
            isRetryable: true,
            retryLabel: "Choose Folder"
        )
    }

    static func folderMissing(path: String?) -> ModexError {
        ModexError(
            kind: .folderMissing,
            title: "Project folder is missing",
            explanation: "This project’s folder has been moved or deleted, so Codex has nowhere to work.",
            suggestedAction: "Choose the folder again to reconnect the project.",
            technicalDetail: trimmed(path),
            severity: .warning,
            isRetryable: true,
            retryLabel: "Choose Folder"
        )
    }

    static func permissionDenied(detail: String?) -> ModexError {
        ModexError(
            kind: .permissionDenied,
            title: "Action blocked by permissions",
            explanation: "Codex was prevented from doing this by the current sandbox mode.",
            suggestedAction: "Raise permissions (Write or Full access) in the composer, then try again.",
            technicalDetail: trimmed(detail),
            severity: .warning,
            isRetryable: true,
            retryLabel: "Resend"
        )
    }

    static func notAuthenticated(detail: String? = nil) -> ModexError {
        ModexError(
            kind: .notAuthenticated,
            title: "Sign in to Codex",
            explanation: "Codex isn’t signed in, so it can’t answer yet. Modex uses your local Codex credentials.",
            suggestedAction: "Run “codex login” in Terminal (or set an API key Codex supports), then resend.",
            technicalDetail: trimmed(detail),
            severity: .warning,
            isRetryable: true,
            retryLabel: "Resend"
        )
    }

    static func updateCheckFailed(detail: String?) -> ModexError {
        ModexError(
            kind: .updateCheckFailed,
            title: "Update check failed",
            explanation: "Modex couldn’t check for a newer version.",
            suggestedAction: "Check your network, then try again.",
            technicalDetail: trimmed(detail),
            severity: .info,
            isRetryable: true,
            retryLabel: "Retry"
        )
    }

    static func updateInstallFailed(detail: String?) -> ModexError {
        ModexError(
            kind: .updateInstallFailed,
            title: "Update failed",
            explanation: "Modex couldn’t install the latest version.",
            suggestedAction: "Try again, or update from the terminal.",
            technicalDetail: trimmed(detail),
            severity: .warning,
            isRetryable: true,
            retryLabel: "Retry"
        )
    }

    static func sessionDataCorrupt(detail: String?) -> ModexError {
        ModexError(
            kind: .sessionDataCorrupt,
            title: "Couldn’t restore your last session",
            explanation: "Saved chats were unreadable and have been set aside, so Modex started fresh.",
            suggestedAction: nil,
            technicalDetail: trimmed(detail),
            severity: .warning,
            isRetryable: false,
            retryLabel: nil
        )
    }

    static func engineError(detail: String?) -> ModexError {
        ModexError(
            kind: .engineError,
            title: "Codex reported an error",
            explanation: "Something went wrong while Codex was working on your request.",
            suggestedAction: "Try sending again.",
            technicalDetail: trimmed(detail),
            severity: .error,
            isRetryable: true,
            retryLabel: "Resend"
        )
    }

    static func gitSwitchFailed(detail: String?) -> ModexError {
        ModexError(
            kind: .gitSwitchFailed,
            title: "Couldn’t switch branch",
            explanation: "Git wouldn’t switch branches — there may be uncommitted changes that conflict.",
            suggestedAction: "Commit or stash your changes, then try again.",
            technicalDetail: trimmed(detail),
            severity: .warning,
            isRetryable: false,
            retryLabel: nil
        )
    }
}
