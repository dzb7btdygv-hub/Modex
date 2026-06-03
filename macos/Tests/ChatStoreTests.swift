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

    // MARK: - Error classification (honest auth vs. permission vs. generic)

    func testAuthErrorsAreRecognized() {
        XCTAssertTrue(ChatStore.isAuthError("401 Unauthorized"))
        XCTAssertTrue(ChatStore.isAuthError("You are not logged in. Run codex login."))
        XCTAssertTrue(ChatStore.isAuthError("authentication failed: invalid api key"))
        XCTAssertTrue(ChatStore.isAuthError("token has expired"))
    }

    func testNonAuthErrorsAreNotMisclassifiedAsAuth() {
        XCTAssertFalse(ChatStore.isAuthError("Operation not permitted (sandbox)"))
        XCTAssertFalse(ChatStore.isAuthError("the model returned a malformed response"))
        XCTAssertFalse(ChatStore.isAuthError("network timeout"))
    }

    func testPermissionAndAuthErrorsAreDistinct() {
        // A sandbox rejection is a permission problem, not an auth problem, so the
        // user is told to raise access — not to sign in.
        let sandbox = "operation not permitted: read-only sandbox blocked the write"
        XCTAssertTrue(ChatStore.isPermissionError(sandbox))
        XCTAssertFalse(ChatStore.isAuthError(sandbox))
    }

    // MARK: - Sandbox policy mapping (security-relevant wire payload)

    func testReadOnlySandboxPolicyDeniesNetworkAndWrites() {
        let policy = PermissionMode.readOnly.sandboxPolicy(folderPath: "/tmp/project")
        XCTAssertEqual(policy["type"] as? String, "readOnly")
        XCTAssertEqual(policy["networkAccess"] as? Bool, false)
        XCTAssertNil(policy["writableRoots"])
    }

    func testWriteSandboxPolicyScopesWritesToTheFolder() {
        let policy = PermissionMode.write.sandboxPolicy(folderPath: "/tmp/project")
        XCTAssertEqual(policy["type"] as? String, "workspaceWrite")
        XCTAssertEqual(policy["networkAccess"] as? Bool, false)
        XCTAssertEqual(policy["writableRoots"] as? [String], ["/tmp/project"])
    }

    func testWriteSandboxPolicyHasNoWritableRootsWithoutAFolder() {
        let policy = PermissionMode.write.sandboxPolicy(folderPath: nil)
        XCTAssertEqual(policy["writableRoots"] as? [String], [])
    }

    func testFullAccessSandboxPolicy() {
        let policy = PermissionMode.fullAccess.sandboxPolicy(folderPath: "/tmp/project")
        XCTAssertEqual(policy["type"] as? String, "dangerFullAccess")
    }

    // MARK: - Reasoning round-trip

    func testReasoningEffortLabelRoundTrips() {
        for effort in ReasoningEffort.allCases {
            XCTAssertEqual(ReasoningEffort(label: effort.label), effort)
        }
        XCTAssertNil(ReasoningEffort(label: "Bogus"))
    }

    // MARK: - Markdown parsing (callout vs. code fence)

    func testCalloutFenceParsesAsCalloutNotCode() {
        let blocks = MarkdownParser.parse("```tip Quick tip\nbe careful\n```")
        guard case .callout(let kind, let title, let content)? = blocks.first else {
            return XCTFail("expected a callout block, got \(blocks)")
        }
        XCTAssertEqual(kind, .tip)
        XCTAssertEqual(title, "Quick tip")
        XCTAssertEqual(content, "be careful")
    }

    func testLanguageFenceParsesAsCode() {
        let blocks = MarkdownParser.parse("```swift\nlet x = 1\n```")
        guard case .code(let language, let code)? = blocks.first else {
            return XCTFail("expected a code block, got \(blocks)")
        }
        XCTAssertEqual(language, "swift")
        XCTAssertEqual(code, "let x = 1")
    }

    func testParsesHeadingBulletAndNumberedBlocks() {
        let blocks = MarkdownParser.parse("# Title\n\n- one\n- two\n\n1. first\n2. second")
        XCTAssertTrue(blocks.contains { if case .heading(1, "Title") = $0 { return true }; return false })
        XCTAssertTrue(blocks.contains { if case .bulleted(let items) = $0 { return items == ["one", "two"] }; return false })
        XCTAssertTrue(blocks.contains { if case .numbered(let items) = $0 { return items == ["first", "second"] }; return false })
    }
}
