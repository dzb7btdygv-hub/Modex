import SwiftUI

struct ChatPaneView: View {
    @Environment(ChatStore.self) private var store
    @Binding var search: String

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            .searchable(
                text: $search,
                placement: .toolbar,
                prompt: "Search chats"
            )
    }

    @ViewBuilder
    private var content: some View {
        if store.messages.isEmpty {
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
        VStack(spacing: 10) {
            PromptDockView()
            Label {
                Text("Try something like ") + Text("“Add social login to the auth system”").foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "lightbulb")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
        .padding(.top, 8)
    }
}
