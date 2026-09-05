import Foundation
import XCTest
@testable import InferenceBar

/// Tests for the pure parts of the web-search tool: normalizing the
/// SearXNG URL a user pastes into Settings, building the actual search
/// request URL, parsing SearXNG's JSON response, formatting a result set
/// for the model to read, and pulling the query back out of a streamed
/// tool call's JSON arguments. `search(query:baseURLString:)` itself
/// touches the network and isn't covered here, matching how the rest of
/// this suite leaves real network calls untested.
final class WebSearchTests: XCTestCase {

    // MARK: - normalizedBaseURL

    func testNormalizedBaseURLAcceptsHTTPAndHTTPS() {
        XCTAssertEqual(WebSearch.normalizedBaseURL("https://searxng.example.com"), URL(string: "https://searxng.example.com"))
        XCTAssertEqual(WebSearch.normalizedBaseURL("http://localhost:8080"), URL(string: "http://localhost:8080"))
    }

    func testNormalizedBaseURLTrimsWhitespaceAndTrailingSlash() {
        XCTAssertEqual(WebSearch.normalizedBaseURL("  https://searxng.example.com/  "), URL(string: "https://searxng.example.com"))
    }

    func testNormalizedBaseURLRejectsMissingSchemeOrHost() {
        XCTAssertNil(WebSearch.normalizedBaseURL("searxng.example.com"), "A bare hostname is rejected rather than guessed at")
        XCTAssertNil(WebSearch.normalizedBaseURL("ftp://searxng.example.com"), "Only http/https are accepted")
        XCTAssertNil(WebSearch.normalizedBaseURL(""))
        XCTAssertNil(WebSearch.normalizedBaseURL("   "))
    }

    // MARK: - searchURL

    func testSearchURLIncludesQueryAndJSONFormat() {
        let base = URL(string: "https://searxng.example.com")!
        let url = WebSearch.searchURL(base: base, query: "weather in Stockholm")
        let components = URLComponents(url: url!, resolvingAgainstBaseURL: false)
        XCTAssertEqual(components?.path, "/search")
        XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "q" })?.value, "weather in Stockholm")
        XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "format" })?.value, "json")
    }

    // MARK: - parseResults

    func testParseResultsReadsTitleURLAndSnippet() {
        let json = """
        {"results": [{"title": "Example", "url": "https://example.com", "content": "An example site"}]}
        """.data(using: .utf8)!
        let results = WebSearch.parseResults(json)
        XCTAssertEqual(results, [WebSearch.Result(title: "Example", url: "https://example.com", snippet: "An example site")])
    }

    func testParseResultsSkipsEntriesMissingTitleOrURL() {
        let json = """
        {"results": [{"title": "", "url": "https://example.com"}, {"title": "No URL"}, {"title": "Good", "url": "https://good.example"}]}
        """.data(using: .utf8)!
        XCTAssertEqual(WebSearch.parseResults(json).map(\.title), ["Good"])
    }

    func testParseResultsRespectsLimit() {
        let entries = (1...10).map { "{\"title\": \"Result \($0)\", \"url\": \"https://example.com/\($0)\"}" }.joined(separator: ",")
        let json = "{\"results\": [\(entries)]}".data(using: .utf8)!
        XCTAssertEqual(WebSearch.parseResults(json, limit: 3).count, 3)
    }

    func testParseResultsOnMalformedOrMissingResultsReturnsEmpty() {
        XCTAssertEqual(WebSearch.parseResults("not json".data(using: .utf8)!), [])
        XCTAssertEqual(WebSearch.parseResults("{\"query\": \"x\"}".data(using: .utf8)!), [], "No 'results' key at all")
    }

    // MARK: - formatForModel

    func testFormatForModelNumbersMultipleResults() {
        let results = [
            WebSearch.Result(title: "First", url: "https://a.example", snippet: "About A"),
            WebSearch.Result(title: "Second", url: "https://b.example", snippet: "")
        ]
        let text = WebSearch.formatForModel(.success(results), query: "test")
        XCTAssertEqual(text, "1. First\nhttps://a.example\nAbout A\n\n2. Second\nhttps://b.example")
    }

    func testFormatForModelOnEmptySuccessSaysNoResults() {
        XCTAssertEqual(WebSearch.formatForModel(.success([]), query: "obscure query"), "No results found for “obscure query”.")
    }

    func testFormatForModelOnFailurePrefixesTheReason() {
        XCTAssertEqual(WebSearch.formatForModel(.failure("could not reach the server."), query: "test"), "Web search failed: could not reach the server.")
    }

    // MARK: - query(fromArguments:)

    func testQueryFromArgumentsExtractsAndTrimsTheQueryField() {
        XCTAssertEqual(WebSearch.query(fromArguments: "{\"query\": \"  weather in Stockholm  \"}"), "weather in Stockholm")
    }

    func testQueryFromArgumentsReturnsNilWhenMissingEmptyOrMalformed() {
        XCTAssertNil(WebSearch.query(fromArguments: "{\"other\": \"value\"}"))
        XCTAssertNil(WebSearch.query(fromArguments: "{\"query\": \"\"}"))
        XCTAssertNil(WebSearch.query(fromArguments: "not json"))
        XCTAssertNil(WebSearch.query(fromArguments: ""))
    }

    // MARK: - toolDefinition

    func testToolDefinitionNamesTheFunctionWebSearch() {
        let function = WebSearch.toolDefinition["function"] as? [String: Any]
        XCTAssertEqual(WebSearch.toolDefinition["type"] as? String, "function")
        XCTAssertEqual(function?["name"] as? String, WebSearch.toolName)
        XCTAssertEqual(WebSearch.toolName, "web_search")
    }
}
