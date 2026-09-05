import Foundation

/// Building and reading an OpenAI-style streaming chat-completions
/// exchange for a one-shot `ask` — the pure parts, kept separate from
/// CLI.swift's actual networking so they're unit-testable without a
/// running server.
enum ChatCompletion {
    /// The request body for a one-shot ask. `model` is deliberately
    /// omitted: llama-server ignores an absent model field and just
    /// answers with whatever's loaded, and mlx_lm.server falls back to
    /// its launch-time default the same way (see the matching comment on
    /// this same choice in AppStore.sendPrompt). This CLI has no way to
    /// know which profile is running anyway — see ServerSettings — so
    /// there's no alias it could send even if it wanted to.
    static func requestBody(prompt: String) -> [String: Any] {
        [
            "messages": [["role": "user", "content": prompt]],
            "stream": true,
        ]
    }

    /// Pulls the incremental text out of one SSE `data: ...` line from a
    /// streaming chat-completions response, mirroring AppStore.sendPrompt's
    /// own inline parsing (delta.content, falling back to delta.text for
    /// servers that use that key instead). Returns nil for anything that
    /// isn't a content token to print: a non-"data:" line, blank
    /// keep-alive padding, the "[DONE]" sentinel, a tool-call-only delta,
    /// malformed JSON, or an empty token.
    static func token(fromLine line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty, payload != "[DONE]", let data = payload.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (event["choices"] as? [[String: Any]])?.first else { return nil }
        let delta = choice["delta"] as? [String: Any] ?? choice
        guard let token = (delta["content"] as? String) ?? (delta["text"] as? String), !token.isEmpty else { return nil }
        return token
    }
}
