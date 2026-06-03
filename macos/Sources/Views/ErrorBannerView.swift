import AppKit
import SwiftUI

/// Compact, native, glass error banner for recoverable runtime failures.
/// Sits just above the composer. Shows a severity icon, title, one-line
/// explanation, an optional suggested action, a retry control, and a "Details"
/// disclosure that reveals the raw technical text behind a copy button.
struct ErrorBannerView: View {
    @Environment(ErrorCenter.self) private var errors

    let presented: ErrorCenter.Presented
    @State private var showDetails = false

    private var error: ModexError { presented.error }
    private var style: SeverityStyle { SeverityStyle(error.severity) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: style.symbol)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(style.tint)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(error.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(error.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let action = error.suggestedAction {
                        Text(action)
                            .font(.caption)
                            .foregroundStyle(style.tint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 8)

                controls
            }

            if showDetails, let detail = error.technicalDetail {
                detailsArea(detail)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(style.borderColor, lineWidth: 0.75)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(error.title). \(error.explanation)")
    }

    private var controls: some View {
        HStack(spacing: 6) {
            if error.technicalDetail != nil {
                Button {
                    withAnimation(.smooth(duration: 0.18)) { showDetails.toggle() }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .rotationEffect(.degrees(showDetails ? 180 : 0))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(showDetails ? "Hide details" : "Show details")
                .accessibilityLabel(showDetails ? "Hide technical details" : "Show technical details")
            }

            if error.isRetryable, presented.retry != nil {
                Button {
                    errors.dismissBanner()
                    presented.retry?()
                } label: {
                    Text(error.retryLabel ?? "Retry")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
                .tint(style.tint)
            }

            Button {
                errors.dismissBanner()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
    }

    private func detailsArea(_ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView {
                Text(detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 120)
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
            .help("Copy the technical details to the clipboard")
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

/// Maps a severity to the icon + tint used across the banner and recovery screen.
struct SeverityStyle {
    let symbol: String
    let tint: Color
    /// A visible hairline even for `.info`, whose `.secondary` tint would
    /// otherwise render a near-invisible border.
    let borderColor: Color

    init(_ severity: ModexError.Severity) {
        switch severity {
        case .info:
            symbol = "info.circle.fill"
            tint = .secondary
            borderColor = Color.primary.opacity(0.12)
        case .warning:
            symbol = "exclamationmark.triangle.fill"
            tint = .orange
            borderColor = Color.orange.opacity(0.32)
        case .error:
            symbol = "exclamationmark.octagon.fill"
            tint = .red
            borderColor = Color.red.opacity(0.32)
        case .fatal:
            symbol = "bolt.trianglebadge.exclamationmark.fill"
            tint = .red
            borderColor = Color.red.opacity(0.32)
        }
    }
}
