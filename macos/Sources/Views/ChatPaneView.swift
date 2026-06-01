import SwiftUI

struct ChatPaneView: View {
    @Environment(ChatStore.self) private var store

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            .toolbar {
                // Both pills live in ONE leading item so the toolbar doesn't wrap
                // them in a shared glass platter (which read as "two boxes in one
                // pill"). They sit on the left, where the title used to be.
                ToolbarItem(placement: .navigation) {
                    HStack(spacing: 8) {
                        SelectorPill(
                            systemImage: "cpu",
                            title: store.selectedModel,
                            options: store.availableModels,
                            selected: store.selectedModel
                        ) { store.selectedModel = $0 }

                        SelectorPill(
                            systemImage: "brain",
                            title: store.reasoning.label,
                            options: ReasoningEffort.allCases.map(\.label),
                            selected: store.reasoning.label
                        ) { if let level = ReasoningEffort(label: $0) { store.reasoning = level } }
                    }
                }
            }
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
        PromptDockView()
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.bottom, 18)
            .padding(.top, 8)
    }
}
