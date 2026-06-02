import SwiftUI

struct ChatPaneView: View {
    @Environment(ChatStore.self) private var store
    @Environment(ErrorCenter.self) private var errors

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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Hide the composer behind the fatal recovery screen — there's
            // nothing to send until the engine is back.
            if errors.fatal == nil {
                composer
            }
        }
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
            ConversationView()
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Text("What would you like to build?")
                .font(.largeTitle.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(store.isReady ? "Modex is ready to plan, build, and ship with you." : store.status)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
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
    }
}
