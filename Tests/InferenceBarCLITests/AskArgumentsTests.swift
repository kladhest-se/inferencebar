import XCTest
@testable import InferenceBarCLI

final class AskArgumentsTests: XCTestCase {
    func testNoArgumentsIsNoCommand() {
        XCTAssertEqual(AskArguments.parse([]), .noCommand)
    }

    func testHelpFlagLong() {
        XCTAssertEqual(AskArguments.parse(["--help"]), .help)
    }

    func testHelpFlagShort() {
        XCTAssertEqual(AskArguments.parse(["-h"]), .help)
    }

    func testUnknownCommand() {
        XCTAssertEqual(AskArguments.parse(["frobnicate"]), .unknownCommand("frobnicate"))
    }

    func testAskWithSingleQuotedPrompt() {
        XCTAssertEqual(AskArguments.parse(["ask", "what time is it"]), .ask(prompt: "what time is it"))
    }

    func testAskJoinsMultipleUnquotedWords() {
        XCTAssertEqual(AskArguments.parse(["ask", "what", "time", "is", "it"]), .ask(prompt: "what time is it"))
    }

    func testAskTrimsWhitespace() {
        XCTAssertEqual(AskArguments.parse(["ask", "  hello  "]), .ask(prompt: "hello"))
    }

    func testAskWithNoFollowingArgumentsReadsFromStdin() {
        XCTAssertEqual(AskArguments.parse(["ask"]), .ask(prompt: nil))
    }

    func testAskWithDashPlaceholderReadsFromStdin() {
        XCTAssertEqual(AskArguments.parse(["ask", "-"]), .ask(prompt: nil))
    }

    func testAskWithOnlyWhitespaceReadsFromStdin() {
        XCTAssertEqual(AskArguments.parse(["ask", "   "]), .ask(prompt: nil))
    }
}
