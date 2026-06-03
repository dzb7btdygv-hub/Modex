import SwiftUI

/// A compact ring at the top-bar's far right that fills with the accent to show
/// how full the model's context window is. Hovering reveals the exact token
/// counts plus the account's 5-hour and weekly usage limits and when they reset,
/// and offers a one-click "Compact" to free the window.
struct UsageRingView: View {
    @Environment(ChatStore.self) private var store
    @Environment(ThemeStore.self) private var theme

    @State private var ringHovered = false
    @State private var cardHovered = false
    @State private var showCard = false

    private var fraction: Double { store.contextUsage?.fraction ?? 0 }
    private var hasData: Bool { store.contextUsage != nil || store.rateLimitPrimary != nil || store.rateLimitSecondary != nil }

    var body: some View {
        Button {
            showCard.toggle()
        } label: {
            UsageRing(fraction: fraction, accent: theme.accentColor, indeterminate: store.isCompacting)
                .frame(width: 22, height: 22)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            ringHovered = hovering
            updateCard()
        }
        .help("Context window usage")
        .accessibilityLabel("Context window usage")
        .accessibilityValue(accessibilityValue)
        .popover(isPresented: $showCard, arrowEdge: .bottom) {
            UsageCard()
                .onHover { cardHovered = $0; updateCard() }
        }
    }

    private var accessibilityValue: String {
        guard let usage = store.contextUsage else { return "Not available yet" }
        return "\(Int((usage.fraction * 100).rounded())) percent of context used"
    }

    /// Opens immediately on hover; closes after a short grace period so the
    /// cursor can travel into the card to read it or click Compact.
    private func updateCard() {
        if ringHovered || cardHovered {
            showCard = true
        } else {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                if !ringHovered && !cardHovered { showCard = false }
            }
        }
    }
}

/// The ring itself: a faint track with an accent arc. Shows a soft pulse while a
/// compaction is running.
private struct UsageRing: View {
    let fraction: Double
    let accent: Color
    var indeterminate: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private var ringColor: Color {
        // Stay on-brand (pink), but warn as the window fills so a near-full
        // context reads at a glance without opening the card.
        if fraction >= 0.9 { return Color(red: 1.0, green: 0.42, blue: 0.30) }
        if fraction >= 0.75 { return Color(red: 1.0, green: 0.62, blue: 0.45) }
        return accent
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.14), lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(0.001, fraction))
                .stroke(ringColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.3), value: fraction)
        }
        .opacity(indeterminate && pulse && !reduceMotion ? 0.45 : 1)
        .onChange(of: indeterminate) { _, running in
            guard !reduceMotion else { return }
            if running {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true }
            } else {
                withAnimation(.default) { pulse = false }
            }
        }
    }
}

// MARK: - Hover card

private struct UsageCard: View {
    @Environment(ChatStore.self) private var store
    @Environment(ThemeStore.self) private var theme

    /// Whether to nudge the user to compact: opted in, near the window, and able.
    private var suggestCompaction: Bool {
        theme.autoCompactNearLimit
            && (store.contextUsage?.fraction ?? 0) >= 0.85
            && store.canCompact
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            contextSection
            Divider()
            limitsSection
        }
        .padding(16)
        .frame(width: 268)
    }

    @ViewBuilder
    private var contextSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Context window", systemImage: "gauge.with.dots.needle.33percent")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let usage = store.contextUsage {
                    Text("\(percent(usage.fraction))%")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if let usage = store.contextUsage {
                UsageBar(fraction: usage.fraction)
                Text("\(tokens(usage.usedTokens)) of \(tokens(usage.windowTokens)) tokens")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                breakdown(usage)
            } else {
                Text("No usage yet — send a message to populate the context window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if suggestCompaction {
                Label("Context is almost full — compacting will free up room.", systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            CompactButton()
                .padding(.top, 2)
        }
    }

    @ViewBuilder
    private func breakdown(_ usage: ContextUsage) -> some View {
        let parts: [(String, Int?)] = [
            ("Input", usage.inputTokens),
            ("Cached", usage.cachedInputTokens),
            ("Output", usage.outputTokens),
            ("Reasoning", usage.reasoningTokens),
        ]
        let shown = parts.compactMap { label, value in value.map { (label, $0) } }
        if !shown.isEmpty {
            VStack(spacing: 3) {
                ForEach(shown, id: \.0) { label, value in
                    HStack {
                        Text(label).font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Text(tokens(value)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private var limitsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Usage limits", systemImage: "clock.arrow.circlepath")
                .font(.subheadline.weight(.semibold))

            if store.rateLimitPrimary == nil && store.rateLimitSecondary == nil {
                Text("Not available yet — limits appear after the first request.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                if let primary = store.rateLimitPrimary {
                    RateLimitRow(window: primary)
                }
                if let secondary = store.rateLimitSecondary {
                    RateLimitRow(window: secondary)
                }
            }
        }
    }

    private func percent(_ fraction: Double) -> Int { Int((fraction * 100).rounded()) }
    private func tokens(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }
}

private struct UsageBar: View {
    let fraction: Double
    @Environment(ThemeStore.self) private var theme

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule()
                    .fill(theme.accentColor)
                    .frame(width: max(3, proxy.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 6)
    }
}

private struct RateLimitRow: View {
    let window: RateLimitWindowInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(window.windowLabel)
                    .font(.caption.weight(.medium))
                Spacer()
                Text("\(Int(window.usedPercent.rounded()))% used")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            UsageBar(fraction: window.usedPercent / 100)
            if let resets = window.resetsAt {
                Text("Resets \(Self.relative(resets))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// "in 2h 14m" / "in 3d" — a compact relative reset time.
    static func relative(_ date: Date) -> String {
        let seconds = date.timeIntervalSinceNow
        guard seconds > 0 else { return "soon" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "in \(max(1, minutes))m" }
        let hours = minutes / 60
        if hours < 24 {
            let mins = minutes % 60
            return mins > 0 ? "in \(hours)h \(mins)m" : "in \(hours)h"
        }
        let days = hours / 24
        return "in \(days)d"
    }
}

private struct CompactButton: View {
    @Environment(ChatStore.self) private var store

    var body: some View {
        Button {
            store.compactContext()
        } label: {
            HStack(spacing: 6) {
                if store.isCompacting {
                    ProgressView().controlSize(.small)
                    Text("Compacting…")
                } else {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                    Text("Compact context")
                }
            }
            .font(.caption.weight(.medium))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
        .controlSize(.small)
        .disabled(!store.canCompact)
        .help("Summarize the conversation to free up the context window")
    }
}
