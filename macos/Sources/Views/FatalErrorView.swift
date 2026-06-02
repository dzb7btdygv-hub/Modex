import AppKit
import SwiftUI

/// Clean, centered recovery screen for startup-fatal failures (engine missing,
/// failed to launch, couldn’t connect/initialize). Takes over the detail pane
/// instead of crashing, and offers a single obvious recovery action.
struct FatalErrorView: View {
    @Environment(ErrorCenter.self) private var errors

    let presented: ErrorCenter.Presented
    @State private var showDetails = false

    private var error: ModexError { presented.error }
    private var style: SeverityStyle { SeverityStyle(error.severity) }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: style.symbol)
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(style.tint)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(error.title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(error.explanation)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let action = error.suggestedAction {
                    Text(action)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: 420)

            if error.isRetryable, presented.retry != nil {
                Button {
                    errors.clearFatal()
                    presented.retry?()
                } label: {
                    Text(error.retryLabel ?? "Try Again")
                        .frame(minWidth: 120)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .tint(style.tint)
                .keyboardShortcut(.defaultAction)
            }

            if let detail = error.technicalDetail {
                detailsDisclosure(detail)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func detailsDisclosure(_ detail: String) -> some View {
        VStack(spacing: 10) {
            Button {
                withAnimation(.smooth(duration: 0.18)) { showDetails.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text(showDetails ? "Hide details" : "Show details")
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(showDetails ? 180 : 0))
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if showDetails {
                VStack(alignment: .leading, spacing: 8) {
                    ScrollView {
                        Text(detail)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(maxHeight: 140)
                    .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 8))

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(detail, forType: .string)
                    } label: {
                        Label("Copy details", systemImage: "doc.on.doc")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 480)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}
