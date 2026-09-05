import XCTest
@testable import InferenceBarCLI

final class ChatCompletionTests: XCTestCase {
    func testRequestBodyOmitsModelAndEnablesStreaming() {
        let body = ChatCompletion.requestBody(prompt: "hello there")
        XCTAssertNil(body["model"])
        XCTAssertEqual(body["stream"] as? Bool, true)
        let messages = body["messages"] as? [[String: String]]
        XCTAssertEqual(messages, [["role": "user", "content": "hello there"]])
    }

    func testTokenFromContentDelta() {
        let line = #"data: {"choices":[{"delta":{"content":"Hi"}}]}"#
        XCTAssertEqual(ChatCompletion.token(fromLine: line), "Hi")
    }

    func testTokenFromTextDeltaFallback() {
        let line = #"data: {"choices":[{"delta":{"text":"Hi"}}]}"#
        XCTAssertEqual(ChatCompletion.token(fromLine: line), "Hi")
    }

    func testTokenFromNonDeltaChoiceFallback() {
        // Some servers put content directly on the choice rather than
        // nesting it under "delta" -- token(fromLine:) falls back to the
        // choice itself in that case.
        let line = #"data: {"choices":[{"content":"Hi"}]}"#
        XCTAssertEqual(ChatCompletion.token(fromLine: line), "Hi")
    }

    func testTokenIsNilForDoneSentinel() {
        XCTAssertNil(ChatCompletion.token(fromLine: "data: [DONE]"))
    }

    func testTokenIsNilForNonDataLine() {
        XCTAssertNil(ChatCompletion.token(fromLine: "event: ping"))
        XCTAssertNil(ChatCompletion.token(fromLine: ""))
    }

    func testTokenIsNilForBlankKeepAlivePadding() {
        XCTAssertNil(ChatCompletion.token(fromLine: "data: "))
    }

    func testTokenIsNilForMalformedJSON() {
        XCTAssertNil(ChatCompletion.token(fromLine: "data: {not json"))
    }

    func testTokenIsNilForToolCallOnlyDelta() {
        let line = #"data: {"choices":[{"delta":{"tool_calls":[{"id":"1"}]}}]}"#
        XCTAssertNil(ChatCompletion.token(fromLine: line))
    }

    func testTokenIsNilForEmptyContentString() {
        let line = #"data: {"choices":[{"delta":{"content":""}}]}"#
        XCTAssertNil(ChatCompletion.token(fromLine: line))
    }

    func testTokenIsNilForEmptyChoicesArray() {
        let line = #"data: {"choices":[]}"#
        XCTAssertNil(ChatCompletion.token(fromLine: line))
    }
}
