import Foundation
import XCTest
@testable import InferenceBar

/// Tests for the pure parts of the fetch-URL tool: validating a URL the
/// model asks to fetch, pulling that URL back out of a streamed tool
/// call's JSON arguments, stripping HTML down to readable text, decoding
/// entities, truncating long pages, and formatting a result for the
/// model to read. `fetch(urlString:)` itself touches the network and
/// isn't covered here, matching how the rest of this suite leaves real
/// network calls untested (see WebSearchTests).
final class FetchURLTests: XCTestCase {

    // MARK: - normalizedURL

    func testNormalizedURLAcceptsHTTPAndHTTPS() {
        XCTAssertEqual(FetchURL.normalizedURL("https://example.com/page"), URL(string: "https://example.com/page"))
        XCTAssertEqual(FetchURL.normalizedURL("http://localhost:8080/x"), URL(string: "http://localhost:8080/x"))
    }

    func testNormalizedURLTrimsWhitespace() {
        XCTAssertEqual(FetchURL.normalizedURL("  https://example.com  "), URL(string: "https://example.com"))
    }

    func testNormalizedURLRejectsNonWebSchemesAndMissingHost() {
        XCTAssertNil(FetchURL.normalizedURL("example.com"), "A bare hostname is rejected rather than guessed at")
        XCTAssertNil(FetchURL.normalizedURL("file:///etc/passwd"))
        XCTAssertNil(FetchURL.normalizedURL("javascript:alert(1)"))
        XCTAssertNil(FetchURL.normalizedURL(""))
        XCTAssertNil(FetchURL.normalizedURL("   "))
    }

    // MARK: - url(fromArguments:)

    func testURLFromArgumentsExtractsAndTrimsTheURLField() {
        XCTAssertEqual(FetchURL.url(fromArguments: "{\"url\": \"  https://example.com  \"}"), "https://example.com")
    }

    func testURLFromArgumentsReturnsNilWhenMissingEmptyOrMalformed() {
        XCTAssertNil(FetchURL.url(fromArguments: "{\"other\": \"value\"}"))
        XCTAssertNil(FetchURL.url(fromArguments: "{\"url\": \"\"}"))
        XCTAssertNil(FetchURL.url(fromArguments: "not json"))
        XCTAssertNil(FetchURL.url(fromArguments: ""))
    }

    // MARK: - extractText

    func testExtractTextStripsTagsAndCollapsesWhitespace() {
        let html = "<html><body><h1>Title</h1>\n\n<p>First   paragraph.</p><p>Second paragraph.</p></body></html>"
        XCTAssertEqual(FetchURL.extractText(fromHTML: html), "Title\n\nFirst paragraph. Second paragraph.")
    }

    func testExtractTextDropsScriptAndStyleContents() {
        let html = "<html><head><style>body { color: red; }</style></head><body><script>alert('hi')</script><p>Real content.</p></body></html>"
        XCTAssertEqual(FetchURL.extractText(fromHTML: html), "Real content.")
    }

    func testExtractTextDecodesEntities() {
        XCTAssertEqual(FetchURL.extractText(fromHTML: "<p>Fish &amp; chips &mdash; &ldquo;tasty&rdquo;</p>"), "Fish & chips — “tasty”")
    }

    // MARK: - decodeEntities

    func testDecodeEntitiesHandlesNamedEntities() {
        XCTAssertEqual(FetchURL.decodeEntities("Tom &amp; Jerry"), "Tom & Jerry")
        XCTAssertEqual(FetchURL.decodeEntities("&lt;tag&gt;"), "<tag>")
    }

    func testDecodeEntitiesHandlesNumericEntitiesDecimalAndHex() {
        XCTAssertEqual(FetchURL.decodeEntities("It&#39;s"), "It's")
        XCTAssertEqual(FetchURL.decodeEntities("It&#x27;s"), "It's")
    }

    func testDecodeEntitiesLeavesMalformedNumericEntityUnchanged() {
        XCTAssertEqual(FetchURL.decodeEntities("&#zzz;"), "&#zzz;")
    }

    // MARK: - truncated

    func testTruncatedLeavesShortTextUnchanged() {
        XCTAssertEqual(FetchURL.truncated("short", limit: 100), "short")
    }

    func testTruncatedCutsLongTextAndAddsNote() {
        let text = String(repeating: "a", count: 50)
        let result = FetchURL.truncated(text, limit: 10)
        XCTAssertTrue(result.hasPrefix(String(repeating: "a", count: 10)))
        XCTAssertTrue(result.contains("Truncated"))
    }

    // MARK: - formatForModel

    func testFormatForModelOnSuccessIncludesURLAndText() {
        let text = FetchURL.formatForModel(.success(finalURL: "https://example.com", text: "Hello world."))
        XCTAssertEqual(text, "Content of https://example.com:\n\nHello world.")
    }

    func testFormatForModelOnEmptySuccessSaysNoReadableContent() {
        let text = FetchURL.formatForModel(.success(finalURL: "https://example.com", text: ""))
        XCTAssertEqual(text, "Fetched https://example.com, but it had no readable text content.")
    }

    func testFormatForModelOnFailurePrefixesTheReason() {
        XCTAssertEqual(FetchURL.formatForModel(.failure("the server returned status 404.")), "Could not fetch that URL: the server returned status 404.")
    }

    // MARK: - toolDefinition

    func testToolDefinitionNamesTheFunctionFetchURL() {
        let function = FetchURL.toolDefinition["function"] as? [String: Any]
        XCTAssertEqual(FetchURL.toolDefinition["type"] as? String, "function")
        XCTAssertEqual(function?["name"] as? String, FetchURL.toolName)
        XCTAssertEqual(FetchURL.toolName, "fetch_url")
    }
}
