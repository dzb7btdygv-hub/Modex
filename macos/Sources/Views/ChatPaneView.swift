import SwiftUI

struct ChatPaneView: View {
    @Environment(ChatStore.self) private var store
    @Environment(ErrorCenter.self) private var errors
    /// Live height of the composer (incl. its padding), measured so the
    /// conversation can fade out exactly where the selector pills float.
    @State private var composerHeight: CGFloat = 0

    /// Extra fade beyond the composer's measured height so text dissolves a touch
    /// before reaching the floating pills.
    private let fadeOverhang: CGFloat = 12

    var body: some View {
        VStack(spacing: 0) {
            TopChatBarView()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Float the banner just above the composer. Using an overlay
                // (not the safe-area inset) keeps it out of the window's
                // content-size calculation, so it never resizes the window.
                .overlay(alignment: .bottom) { bannerOverlay }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ModexDetailSurface().ignoresSafeArea())
        // The top bar always rides up into the transparent titlebar strip so it
        // stays pinned to the very top. When the sidebar is collapsed the traffic
        // lights move into this pane's top-left, but the centered title column
        // clears them, so we no longer drop the whole bar below them.
        .ignoresSafeArea(.container, edges: .top)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Hide the composer behind the fatal recovery screen — there's
            // nothing to send until the engine is back.
            if errors.fatal == nil {
                composer
            }
        }
        .onPreferenceChange(ComposerHeightKey.self) { composerHeight = $0 }
    }

    @ViewBuilder
    private var bannerOverlay: some View {
        if errors.fatal == nil, let banner = errors.banner {
            ErrorBannerView(presented: banner)
                .id(banner.id)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.smooth(duration: 0.2), value: banner.id)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let fatal = errors.fatal {
            FatalErrorView(presented: fatal)
        } else if store.messages.isEmpty {
            emptyState
        } else {
            // Fade the conversation to transparent across the composer band so
            // user/assistant text dissolves before it slides behind the
            // (background-less) permission · model · reasoning pills.
            ConversationView()
                .mask {
                    VStack(spacing: 0) {
                        Rectangle().fill(Color.black)
                        LinearGradient(
                            gradient: Gradient(colors: [Color.black, Color.clear]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: max(0, composerHeight + fadeOverhang))
                    }
                }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Text("What would you like to build?")
                .font(.largeTitle.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(store.isReady ? "Modex is ready to plan, build, and ship with you." : store.status)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
    }

    // MARK: - Composer

    private var composer: some View {
        PromptDockView()
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.bottom, 18)
            .padding(.top, 8)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: ComposerHeightKey.self, value: proxy.size.height)
                }
            )
    }
}

/// Reports the composer's laid-out height so the conversation fade can track it.
private struct ComposerHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
