import Foundation

/// Lets InferenceBar's own chat give the model a "web_search" tool backed
/// by a SearXNG instance the user points at (self-hosted or public) — no
/// API key required, unlike most commercial search APIs. Kept as its own
/// type, independent of AppStore, so the URL handling, response parsing,
/// and result formatting are all plain, testable functions; only
/// `search(query:baseURLString:)` itself touches the network.
enum WebSearch {
    struct Result: Equatable {
        let title: String
        let url: String
        let snippet: String
    }

    enum Outcome {
        case success([Result])
        case failure(String)
    }

    static let maximumResults = 5
    static let toolName = "web_search"

    /// OpenAI-style function-calling tool definition sent in the
    /// `tools` array of every chat completion request while web search is
    /// enabled and configured — the model decides whether/when to call it.
    /// A computed property rather than a stored `static let`: `[String:
    /// Any]` isn't Sendable, and Swift 6 treats a stored static of a
    /// non-Sendable type as unsafe shared global state. Building it fresh
    /// on each access has no such storage, so there's nothing to share.
    static var toolDefinition: [String: Any] {
        [
            "type": "function",
            "function": [
                "name": toolName,
                "description": "Search the public web for current information. Use this for anything that may have changed since training, anything you're not confident about, or anything the user explicitly asks you to look up.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "The search query"]
                    ],
                    "required": ["query"]
                ]
            ]
        ]
    }

    /// Normalizes what a user pastes into Settings into something safe to
    /// append "/search" onto: trims whitespace, drops a trailing slash,
    /// and requires an explicit http(s) scheme and host — a bare hostname
    /// is rejected rather than guessed at, since guessing wrong would mean
    /// silently searching (or leaking queries to) the wrong place.
    static func normalizedBaseURL(_ raw: String) -> URL? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty, let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil else { return nil }
        return url
    }

    /// SearXNG's JSON API is `GET <base>/search?q=<query>&format=json` —
    /// the instance must have `json` added to `formats` in its own
    /// settings.yml, or it refuses the request with 403 Forbidden.
    static func searchURL(base: URL, query: String) -> URL? {
        var components = URLComponents(url: base.appendingPathComponent("search"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "format", value: "json")]
        return components?.url
    }

    /// Pure parsing of SearXNG's JSON response body
    /// (`{"results": [{"title": ..., "url": ..., "content": ...}, ...]}`),
    /// capped to the first `limit` entries in whatever order SearXNG
    /// already ranked them. A malformed body, or one missing `results`
    /// entirely, parses to an empty array rather than throwing.
    static func parseResults(_ data: Data, limit: Int = maximumResults) -> [Result] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawResults = json["results"] as? [[String: Any]] else { return [] }
        return rawResults.prefix(limit).compactMap { entry in
            guard let title = entry["title"] as? String, let url = entry["url"] as? String,
                  !title.isEmpty, !url.isEmpty else { return nil }
            return Result(title: title, url: url, snippet: (entry["content"] as? String) ?? "")
        }
    }

    /// The text fed back to the model as the tool call's result — plain
    /// and numbered rather than JSON, since it's read by the model, not
    /// parsed by code.
    static func formatForModel(_ outcome: Outcome, query: String) -> String {
        switch outcome {
        case .success(let results):
            guard !results.isEmpty else { return "No results found for “\(query)”." }
            return results.enumerated().map { index, result in
                "\(index + 1). \(result.title)\n\(result.url)" + (result.snippet.isEmpty ? "" : "\n\(result.snippet)")
            }.joined(separator: "\n\n")
        case .failure(let reason):
            return "Web search failed: \(reason)"
        }
    }

    /// Pulls "query" out of a tool call's streamed, now-complete JSON
    /// arguments string (e.g. `{"query": "weather in Stockholm"}`).
    static func query(fromArguments arguments: String) -> String? {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = (object["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty else { return nil }
        return query
    }

    /// Runs the actual search against the user's configured SearXNG
    /// instance. Never throws — a failed search should tell the model
    /// (and, via Settings' "Test" button, the user) why it didn't work
    /// rather than aborting the whole chat turn.
    static func search(query: String, baseURLString: String) async -> Outcome {
        guard let base = normalizedBaseURL(baseURLString) else { return .failure("not configured with a valid SearXNG URL.") }
        guard let url = searchURL(base: base, query: query) else { return .failure("could not build a search URL for that query.") }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                return .failure("the search server returned an error. If this keeps happening, check that the SearXNG instance has JSON output enabled (`json` added to `formats` in its settings.yml).")
            }
            return .success(parseResults(data))
        } catch {
            return .failure("could not reach the configured search server: \(error.localizedDescription)")
        }
    }
}
