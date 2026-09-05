import Foundation
import XCTest
@testable import InferenceBar

/// Tests for chat export: what "Export as Markdown…" in the chat sidebar
/// context menu actually produces.
///
/// Previously an `InferenceBarUITests` file driving the real Chat window
/// with `XCUIApplication` — as explained in SettingsTests.swift, that
/// could never actually run under `swift test`, and several of its checks
/// (a "Chat input" named text field, a "Server settings" button and
/// "Temperature" slider inside the Chat window, a "Clear chat" button)
/// didn't match how PromptView is actually built: the composer field has
/// no accessibility identifier, there's no per-chat settings panel in the
/// Chat window itself, and the equivalent of "clear" is "New chat"
/// (`store.clearConversation()`), not a dedicated Clear button. Rewritten
/// to test `SavedChat`'s pure export logic instead. Chat tail-follow,
/// composer sizing, and attachment rendering already have coverage in
/// DownloadAndModelTests.swift.
final class ChatTests: XCTestCase {

    func testMarkdownExportLabelsEachSpeaker() {
        let chat = SavedChat(title: "Debugging session", messages: [
            ChatMessage(role: "user", content: "Why does this crash?"),
            ChatMessage(role: "assistant", content: "It's a nil optional."),
            ChatMessage(role: "system", content: "Session restored.")
        ])
        let export = chat.markdownExport
        XCTAssertTrue(export.hasPrefix("# Debugging session\n\n"))
        XCTAssertTrue(export.contains("_Exported from InferenceBar ·"))
        XCTAssertTrue(export.contains("**You:**\n\nWhy does this crash?"))
        XCTAssertTrue(export.contains("**Assistant:**\n\nIt's a nil optional."))
        XCTAssertTrue(export.contains("**System:**\n\nSession restored."), "An unrecognized role should fall back to its capitalized name")
    }

    func testMarkdownExportOfAnEmptyChatStillHasAHeader() {
        let chat = SavedChat(title: "Untitled", messages: [])
        XCTAssertTrue(chat.markdownExport.hasPrefix("# Untitled\n\n"))
    }

    func testSuggestedExportFilenameSanitizesPathCharacters() {
        let chat = SavedChat(title: "Q3 Report / Draft: v2\\final", messages: [])
        XCTAssertEqual(chat.suggestedExportFilename, "Q3 Report - Draft- v2-final.md")
    }

    func testSuggestedExportFilenameFallsBackToChatWhenTitleIsBlank() {
        XCTAssertEqual(SavedChat(title: "   ", messages: []).suggestedExportFilename, "Chat.md")
        XCTAssertEqual(SavedChat(title: "", messages: []).suggestedExportFilename, "Chat.md")
    }

    func testSuggestedExportFilenameTrimsSurroundingWhitespace() {
        XCTAssertEqual(SavedChat(title: "  Release Notes  ", messages: []).suggestedExportFilename, "Release Notes.md")
    }

    // MARK: - ChatRegenerationPolicy.trailingAssistantTurnRange (regenerate)

    func testTrailingAssistantTurnRangeCoversTheAnswerAfterTheLastUserMessage() {
        let messages = [
            ChatMessage(role: "user", content: "Q1"),
            ChatMessage(role: "assistant", content: "A1"),
            ChatMessage(role: "user", content: "Q2"),
            ChatMessage(role: "assistant", content: "A2")
        ]
        XCTAssertEqual(ChatRegenerationPolicy.trailingAssistantTurnRange(in: messages), 3..<4, "Only the reply to the most recent question should be dropped")
    }

    func testTrailingAssistantTurnRangeIncludesToolNotesAfterTheLastUserMessage() {
        let messages = [
            ChatMessage(role: "user", content: "What's the weather?"),
            ChatMessage(role: "assistant", content: "🔎 Searched the web for “weather”"),
            ChatMessage(role: "assistant", content: "It's sunny.")
        ]
        XCTAssertEqual(ChatRegenerationPolicy.trailingAssistantTurnRange(in: messages), 1..<3, "The search note is part of the answer being regenerated, not the question")
    }

    func testTrailingAssistantTurnRangeIsNilWithNoUserMessageYet() {
        XCTAssertNil(ChatRegenerationPolicy.trailingAssistantTurnRange(in: [ChatMessage(role: "assistant", content: "Hi, how can I help?")]))
    }

    func testTrailingAssistantTurnRangeIsNilWhenTheUserMessageIsAlreadyLast() {
        let messages = [ChatMessage(role: "user", content: "Q1"), ChatMessage(role: "assistant", content: "A1"), ChatMessage(role: "user", content: "Q2")]
        XCTAssertNil(ChatRegenerationPolicy.trailingAssistantTurnRange(in: messages), "Nothing after the last question to regenerate yet")
    }

    func testTrailingAssistantTurnRangeIsNilForAnEmptyTranscript() {
        XCTAssertNil(ChatRegenerationPolicy.trailingAssistantTurnRange(in: []))
    }

    // MARK: - ChatRegenerationPolicy.editTruncationIndex (edit & resend)

    func testEditTruncationIndexFindsAnEarlierUserMessageByID() {
        let target = ChatMessage(role: "user", content: "Q1")
        let messages = [target, ChatMessage(role: "assistant", content: "A1"), ChatMessage(role: "user", content: "Q2"), ChatMessage(role: "assistant", content: "A2")]
        XCTAssertEqual(ChatRegenerationPolicy.editTruncationIndex(for: target.id, in: messages), 0)
    }

    func testEditTruncationIndexIsNilForAnAssistantMessageID() {
        let assistantMessage = ChatMessage(role: "assistant", content: "A1")
        XCTAssertNil(ChatRegenerationPolicy.editTruncationIndex(for: assistantMessage.id, in: [ChatMessage(role: "user", content: "Q1"), assistantMessage]), "Only user messages can be edited and resent")
    }

    func testEditTruncationIndexIsNilForAnUnknownID() {
        XCTAssertNil(ChatRegenerationPolicy.editTruncationIndex(for: UUID(), in: [ChatMessage(role: "user", content: "Q1")]))
    }
}
