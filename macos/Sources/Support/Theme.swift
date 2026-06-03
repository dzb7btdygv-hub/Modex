import AppKit
import Observation
import SwiftUI

extension Color {
    /// Modex's brand pink — the single source of truth for the default accent.
    /// Defined once here so light/dark tuning is a one-line change and no view
    /// hard-codes the RGB (Apple HIG: don't scatter brand hex for UI roles).
    static let modexPink = Color(red: 1.0, green: 0.42, blue: 0.72)

    /// The danger tint for Full access / destructive affordances. Centralized so
    /// the composer's permission controls stop duplicating the literal.
    static let modexDanger = Color(red: 1.0, green: 0.31, blue: 0.18)
}

/// Reduce-Motion-aware animation helpers. Apple's motion guidance says to swap
/// scale/spring/parallax motion for a quick dissolve (not delete feedback)
/// when the user prefers reduced motion; these return a fast cross-fade in that
/// case so every interactive control honors the setting, not just the shimmer.
enum ModexMotion {
    /// A micro-interaction curve (~0.18s), collapsing to a near-instant fade
    /// under Reduce Motion.
    static func micro(_ reduce: Bool) -> Animation {
        reduce ? .easeInOut(duration: 0.08) : .easeInOut(duration: 0.18)
    }

    /// A springy curve for presses/hover lifts, or `nil` (no animation, just a
    /// state cut) under Reduce Motion.
    static func spring(_ reduce: Bool) -> Animation? {
        reduce ? nil : .spring(response: 0.3, dampingFraction: 0.7)
    }

    /// The hover/selection scale factor — flattened to 1.0 under Reduce Motion so
    /// motion-sensitive users get a tint change instead of a grow.
    static func hoverScale(_ reduce: Bool, _ scale: CGFloat) -> CGFloat {
        reduce ? 1.0 : scale
    }
}

/// Appearance preference exposed in Settings → System follows macOS, Light and
/// Dark force a fixed appearance. Drives both SwiftUI (`preferredColorScheme`)
/// and AppKit vibrancy (`NSApp.appearance`) so the system materials flip too.
enum AppearancePreference: String, CaseIterable, Identifiable, Codable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var systemImage: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// The app's accent (primary) colour. Pink is Modex's default brand colour; the
/// rest let the user retint the whole app from Settings. Colours are tuned to
/// read well in both light and dark mode and to clear Apple's 3:1 non-text
/// contrast bar against the app's surfaces.
enum AccentOption: String, CaseIterable, Identifiable, Codable {
    case pink, rose, purple, blue, teal, green, orange, graphite

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pink: return "Pink"
        case .rose: return "Rose"
        case .purple: return "Purple"
        case .blue: return "Blue"
        case .teal: return "Teal"
        case .green: return "Green"
        case .orange: return "Orange"
        case .graphite: return "Graphite"
        }
    }

    var color: Color {
        switch self {
        case .pink: return .modexPink
        case .rose: return Color(red: 0.96, green: 0.28, blue: 0.45)
        case .purple: return Color(red: 0.69, green: 0.44, blue: 0.96)
        case .blue: return Color(red: 0.30, green: 0.55, blue: 1.0)
        case .teal: return Color(red: 0.18, green: 0.74, blue: 0.78)
        case .green: return Color(red: 0.30, green: 0.74, blue: 0.46)
        case .orange: return Color(red: 1.0, green: 0.55, blue: 0.22)
        case .graphite: return Color(red: 0.50, green: 0.52, blue: 0.56)
        }
    }
}

/// Single source of truth for appearance + accent + a few honest composer
/// preferences. `@Observable` so any view re-renders when the user retints the
/// app or flips light/dark. Persisted to `UserDefaults`; no account, no cloud.
@MainActor
@Observable
final class ThemeStore {
    var appearance: AppearancePreference {
        didSet {
            guard appearance != oldValue else { return }
            defaults.set(appearance.rawValue, forKey: Keys.appearance)
            applyAppearance()
        }
    }

    var accent: AccentOption {
        didSet {
            guard accent != oldValue else { return }
            defaults.set(accent.rawValue, forKey: Keys.accent)
        }
    }

    /// When true, ⏎ sends and ⇧⏎ inserts a newline (the default). When false,
    /// ⏎ inserts a newline and ⌘⏎ sends — for users who paste multi-line prompts.
    var returnSends: Bool {
        didSet { defaults.set(returnSends, forKey: Keys.returnSends) }
    }

    /// Offer to compact the conversation automatically as it nears the model's
    /// context window, instead of waiting for the user to run `/compact`.
    var autoCompactNearLimit: Bool {
        didSet { defaults.set(autoCompactNearLimit, forKey: Keys.autoCompact) }
    }

    var accentColor: Color { accent.color }

    /// Transient (not persisted): whether the in-window Settings overlay is up.
    /// Lives here so the sidebar gear, the `/settings` command, and ⌘, can all
    /// drive one shared presentation flag.
    var isSettingsPresented = false

    private let defaults: UserDefaults

    private enum Keys {
        static let appearance = "modex.appearance"
        static let accent = "modex.accent"
        static let returnSends = "modex.returnSends"
        static let autoCompact = "modex.autoCompactNearLimit"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.appearance = defaults.string(forKey: Keys.appearance)
            .flatMap(AppearancePreference.init) ?? .system
        self.accent = defaults.string(forKey: Keys.accent)
            .flatMap(AccentOption.init) ?? .pink
        self.returnSends = defaults.object(forKey: Keys.returnSends) as? Bool ?? true
        self.autoCompactNearLimit = defaults.object(forKey: Keys.autoCompact) as? Bool ?? false
        applyAppearance()
    }

    /// Pushes the chosen appearance onto AppKit so `NSVisualEffectView` materials
    /// (sidebar, window vibrancy) flip with it, not just SwiftUI's own views.
    func applyAppearance() {
        NSApp?.appearance = appearance.nsAppearance
    }
}
