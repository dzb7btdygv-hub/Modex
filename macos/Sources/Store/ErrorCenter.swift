import Foundation
import Observation
import OSLog

/// Single source of truth for surfaced errors.
///
/// Recoverable failures (`info`/`warning`/`error`) ride the inline ``banner``;
/// startup-fatal failures take over the detail pane via ``fatal`` (a clean
/// recovery screen). Each presented error optionally carries a `retry` closure
/// so the UI can offer a one-tap recovery without knowing how it works.
@MainActor
@Observable
final class ErrorCenter {
    /// An error plus the action that would recover from it.
    struct Presented: Identifiable {
        let id: UUID
        let error: ModexError
        let retry: (() -> Void)?

        init(_ error: ModexError, retry: (() -> Void)?) {
            self.id = error.id
            self.error = error
            self.retry = retry
        }
    }

    private(set) var banner: Presented?
    private(set) var fatal: Presented?

    private let logger = Logger(subsystem: "dev.modex.desktop", category: "Errors")

    /// Routes an error to the banner or the fatal recovery screen by severity.
    /// Always logs (full technical detail) so the Console record is preserved
    /// even though the UI shows the friendly copy.
    func present(_ error: ModexError, retry: (() -> Void)? = nil) {
        logger.error("""
            \(error.kind.rawValue, privacy: .public): \(error.title, privacy: .public) — \
            \(error.technicalDetail ?? error.explanation, privacy: .public)
            """)

        let presented = Presented(error, retry: retry)
        if error.severity == .fatal {
            fatal = presented
        } else {
            banner = presented
        }
    }

    func dismissBanner() {
        banner = nil
    }

    func clearFatal() {
        fatal = nil
    }

    func clearAll() {
        banner = nil
        fatal = nil
    }
}
