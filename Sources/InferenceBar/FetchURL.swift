import Foundation

/// Lets InferenceBar's own chat give the model a "fetch_url" tool that
/// retrieves the readable text of a web page it names — the natural
/// complement to WebSearch's `web_search`: search finds pages, fetch_url
/// reads one (a result the model just got back, or a link the user
/// pasted directly). Kept as its own type, independent of AppStore, for
/// the same reason as WebSearch: the URL handling, HTML-to-text
/// extraction, and formatting are all plain, testable functions; only
/// `fetch(urlString:)` itself touches the network.
enum FetchURL {
    enum Outcome {
        case success(finalURL: String, text: String)
        case failure(String)
    }

    static let toolName = "fetch_url"
    /// Cap on how much extracted text is handed back to the model —
    /// plenty for a model to work with, without blowing out the context
    /// window on one page.
    static let maximumCharacters = 6000
    /// Cap on how many raw response bytes are even read before giving up
    /// — protects against being handed a huge binary or streaming
    /// response when only the first chunk of text is ever going to be
    /// used anyway.
    static let maximumBodyBytes = 2_000_000

    /// OpenAI-style function-calling tool definition sent in the `tools`
    /// array of every chat completion request while fetch is enabled —
    /// the model decides whether/when to call it. A computed property,
    /// like WebSearch.toolDefinition, so there's no non-Sendable static
    /// storage to worry about under Swift 6.
    static var toolDefinition: [String: Any] {
        [
            "type": "function",
            "function": [
                "name": toolName,
                "description": "Fetch the text content of a specific web page by URL. Use this to read a page found via web search, or a link the user gave you directly.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "url": ["type": "string", "description": "The full http(s) URL to fetch"]
                    ],
                    "required": ["url"]
                ]
            ]
        ]
    }

    /// Requires an explicit http(s) scheme and host — the same
    /// fail-closed rule as WebSearch.normalizedBaseURL, so a malformed or
    /// non-web URL (`file://`, `javascript:`, a bare hostname) is
    /// rejected rather than guessed at.
    static func normalizedURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil else { return nil }
        return url
    }

    /// Pulls "url" out of a tool call's streamed, now-complete JSON
    /// arguments string (e.g. `{"url": "https://example.com"}`).
    static func url(fromArguments arguments: String) -> String? {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = (object["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !url.isEmpty else { return nil }
        return url
    }

    /// Strips `<script>`/`<style>`/`<noscript>` blocks (their contents
    /// are never page text) and every remaining tag from an HTML
    /// document, decodes entities, and collapses whitespace — a
    /// plain-text approximation that's good enough for a model to read
    /// without pulling in a full HTML parser (or NSAttributedString's
    /// HTML importer, which is slow, main-thread-bound, and not meant for
    /// arbitrary untrusted markup) just to strip tags.
    static func extractText(fromHTML html: String) -> String {
        var text = html
        for tag in ["script", "style", "noscript"] {
            text = text.replacingOccurrences(of: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)>", with: " ", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = decodeEntities(text)
        text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: " *\\n *", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let namedEntities: [String: String] = [
        "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'",
        "&nbsp;": " ", "&mdash;": "—", "&ndash;": "–",
        "&rsquo;": "’", "&lsquo;": "‘", "&rdquo;": "”", "&ldquo;": "“", "&hellip;": "…"
    ]

    /// Decodes the handful of named HTML entities pages actually use,
    /// plus numeric entities (`&#39;`, `&#x27;`) in general — good enough
    /// to turn markup-derived text back into readable prose without a
    /// full HTML entity table.
    static func decodeEntities(_ string: String) -> String {
        var result = string
        for (entity, replacement) in namedEntities { result = result.replacingOccurrences(of: entity, with: replacement) }
        result = replacingNumericEntities(in: result)
        return result
    }

    private static func replacingNumericEntities(in string: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "&#(x[0-9A-Fa-f]+|[0-9]+);") else { return string }
        let nsString = string as NSString
        var result = ""
        var lastIndex = 0
        for match in regex.matches(in: string, range: NSRange(location: 0, length: nsString.length)) {
            result += nsString.substring(with: NSRange(location: lastIndex, length: match.range.location - lastIndex))
            let code = nsString.substring(with: match.range(at: 1))
            let scalarValue: UInt32? = code.hasPrefix("x") ? UInt32(code.dropFirst(), radix: 16) : UInt32(code)
            if let scalarValue, let scalar = Unicode.Scalar(scalarValue) {
                result.append(Character(scalar))
            } else {
                result += nsString.substring(with: match.range)
            }
            lastIndex = match.range.location + match.range.length
        }
        result += nsString.substring(with: NSRange(location: lastIndex, length: nsString.length - lastIndex))
        return result
    }

    /// Truncates already-extracted page text to `maximumCharacters`,
    /// appending a note so the model knows the page ran longer than what
    /// it's seeing rather than assuming this is the whole page.
    static func truncated(_ text: String, limit: Int = maximumCharacters) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n\n[Truncated — the page continues beyond this point.]"
    }

    /// The text fed back to the model as the tool call's result — plain
    /// prose rather than JSON, since it's read by the model, not parsed
    /// by code.
    static func formatForModel(_ outcome: Outcome) -> String {
        switch outcome {
        case .success(let finalURL, let text):
            guard !text.isEmpty else { return "Fetched \(finalURL), but it had no readable text content." }
            return "Content of \(finalURL):\n\n\(text)"
        case .failure(let reason):
            return "Could not fetch that URL: \(reason)"
        }
    }

    /// Runs the actual fetch. Never throws — a failed fetch should tell
    /// the model why it didn't work rather than aborting the whole chat
    /// turn, matching WebSearch.search's behavior.
    static func fetch(urlString: String) async -> Outcome {
        guard let url = normalizedURL(urlString) else { return .failure("not a valid http(s) URL.") }
        var request = URLRequest(url: url)
        request.setValue("text/html,text/plain;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                let status = (response as? HTTPURLResponse)?.statusCode
                return .failure(status.map { "the server returned status \($0)." } ?? "the server returned an unexpected response.")
            }
            let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            guard contentType.isEmpty || contentType.contains("text/") || contentType.contains("html") || contentType.contains("xml") else {
                return .failure("that URL's content type (\(contentType)) isn't text — only web pages and plain text can be fetched.")
            }
            let body = data.count > maximumBodyBytes ? data.prefix(maximumBodyBytes) : data
            guard let raw = String(data: body, encoding: .utf8) ?? String(data: body, encoding: .isoLatin1) else {
                return .failure("the page's content could not be decoded as text.")
            }
            let looksLikeHTML = contentType.contains("html") || raw.range(of: "<html", options: [.caseInsensitive]) != nil
            let text = looksLikeHTML ? extractText(fromHTML: raw) : raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalURL = http.url?.absoluteString ?? url.absoluteString
            return .success(finalURL: finalURL, text: truncated(text))
        } catch {
            return .failure("could not reach that URL: \(error.localizedDescription)")
        }
    }
}
