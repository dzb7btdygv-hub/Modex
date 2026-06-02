import XCTest
@testable import Modex

@MainActor
final class ChatStoreTests: XCTestCase {
    func testGeneratedTitleUsesFirstUsefulPhrase() {
        XCTAssertEqual(ChatStore.generatedTitle(from: "fix the install script signing issue"), "fix install script signing")
        XCTAssertEqual(ChatStore.generatedTitle(from: "can you add project persistence"), "add project persistence")
        XCTAssertEqual(ChatStore.generatedTitle(from: "review this swiftui sidebar bug"), "review swiftui sidebar bug")
    }

    func testGeneratedTitleStripsRepeatedFillerAndPreservesCodeTerms() {
        XCTAssertEqual(ChatStore.generatedTitle(from: "can you please fix `CodexRPCClient` stream parsing"), "fix CodexRPCClient stream parsing")
        XCTAssertEqual(ChatStore.generatedTitle(from: "help me with GPT-5.5 model slugs"), "GPT-5.5 model slugs")
        XCTAssertNil(ChatStore.generatedTitle(from: "```swift\nlet value = 1\n```"))
    }

    func testMessageDecodesOlderPersistedShape() throws {
        let json = """
        {
          "id": "assistant-1",
          "role": "assistant",
          "text": "Done",
          "pending": true
        }
        """

        let message = try JSONDecoder().decode(ChatMessage.self, from: Data(json.utf8))

        XCTAssertEqual(message.id, "assistant-1")
        XCTAssertEqual(message.role, .assistant)
        XCTAssertEqual(message.text, "Done")
        XCTAssertTrue(message.pending)
        XCTAssertNil(message.reasoningText)
        XCTAssertNil(message.reasoningSummaryText)
        XCTAssertNil(message.toolOutputText)
    }

    func testConversationActivityOnlyShowsInlineUsefulStates() {
        XCTAssertTrue(ChatTaskStatus.thinking.isConversationActivity)
        XCTAssertTrue(ChatTaskStatus.runningCommand.isConversationActivity)
        XCTAssertTrue(ChatTaskStatus.editingFiles.isConversationActivity)
        XCTAssertTrue(ChatTaskStatus.waitingForPermission.isConversationActivity)
        XCTAssertFalse(ChatTaskStatus.streamingResponse.isConversationActivity)
        XCTAssertFalse(ChatTaskStatus.ready.isConversationActivity)
        XCTAssertFalse(ChatTaskStatus.failed("Error").isConversationActivity)
    }
}
