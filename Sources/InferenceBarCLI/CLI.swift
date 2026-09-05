import Darwin
import Foundation

/// `inferencebar ask "..."` — pipes a one-off prompt to whatever
/// InferenceBar profile is currently running and prints the answer, so
/// the local model is reachable from a terminal or another script
/// without going through the Chat window. Deliberately minimal: no
/// system prompt, no conversation history, no tool calls — exactly one
/// question, streamed straight to stdout as it's generated.
///
/// Finds the running server the same way InferenceBar's own Chat window
/// would: reads host/port/TLS/auth from the app's own
/// server-settings.json (see ServerSettings) and, when authentication is
/// on, the API key from the Keychain (see APIKeyKeychain) or
/// INFERENCEBAR_API_KEY. It has no way to know *which* profile is
/// running — that's in-memory-only app state, never written to disk —
/// but doesn't need to: only one server is ever running at a time, on
/// whatever host/port InferenceBar's network settings say, and the
/// request just omits `model` the same way InferenceBar's own chat
/// effectively does for MLX runtimes.
@main
struct CLI {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        switch AskArguments.parse(arguments) {
        case .help:
            printUsage()
            exit(0)
        case .noCommand:
            printUsage()
            exit(1)
        case .unknownCommand(let command):
            standardError("inferencebar: unknown command \"\(command)\"\n")
            printUsage()
            exit(1)
        case .ask(let promptFromArguments):
            let prompt = promptFromArguments ?? readStdin()
            guard !prompt.isEmpty else {
                standardError("inferencebar ask: no prompt given — pass it as an argument or pipe one in on stdin.\n")
                exit(1)
            }
            exit(await ask(prompt))
        }
    }

    private static func readStdin() -> String {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func ask(_ prompt: String) async -> Int32 {
        let environment = ProcessInfo.processInfo.environment
        let settings = ServerSettings.load()
        let apiKey = environment["INFERENCEBAR_API_KEY"]
            ?? (settings.authenticationEnabled ? APIKeyKeychain.load() : "")
        let candidates = settings.candidateBaseURLs(
            host: environment["INFERENCEBAR_HOST"],
            port: environment["INFERENCEBAR_PORT"].flatMap(Int.init)
        )
        guard !candidates.isEmpty else {
            standardError("inferencebar ask: could not build a request URL from the configured host/port.\n")
            return 1
        }

        var lastFailure: String?
        for base in candidates {
            switch await send(prompt: prompt, to: base, apiKey: apiKey) {
            case .success:
                return 0
            case .serverResponded(let message):
                // A real server answered and it wasn't happy — that's
                // the definitive outcome, not a reason to try the next
                // candidate scheme.
                standardError("inferencebar ask: \(message)\n")
                return 1
            case .couldNotConnect(let message):
                lastFailure = message
                continue
            }
        }
        standardError("inferencebar ask: could not reach a running InferenceBar profile at \(settings.clientHost):\(settings.port)\(lastFailure.map { " (\($0))" } ?? "").\n")
        return 1
    }

    private enum SendOutcome {
        case success
        case serverResponded(message: String)
        case couldNotConnect(message: String)
    }

    private static func send(prompt: String, to base: URL, apiKey: String) async -> SendOutcome {
        var request = URLRequest(url: base.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try? JSONSerialization.data(withJSONObject: ChatCompletion.requestBody(prompt: prompt))

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .couldNotConnect(message: "unexpected response")
            }
            guard 200..<300 ~= http.statusCode else {
                var body = ""
                for try await line in bytes.lines { body += line + "\n" }
                let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
                return .serverResponded(message: "server error \(http.statusCode)\(trimmed.isEmpty ? "" : ": \(trimmed)")")
            }
            var printedAnything = false
            for try await line in bytes.lines {
                guard let token = ChatCompletion.token(fromLine: line) else { continue }
                print(token, terminator: "")
                printedAnything = true
            }
            if printedAnything { print("") }
            return .success
        } catch {
            return .couldNotConnect(message: error.localizedDescription)
        }
    }

    private static func standardError(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }

    private static func printUsage() {
        print("""
        Usage: inferencebar ask "<prompt>"
               echo "<prompt>" | inferencebar ask

        Sends a one-off prompt to whatever InferenceBar profile is currently
        running and prints the answer. Reads the server's host, port, and
        (if enabled) API key from InferenceBar's own settings automatically
        — nothing to configure for the common case of asking on the same
        Mac InferenceBar is running on.

        Environment overrides:
          INFERENCEBAR_HOST      talk to a different host (e.g. another Mac on your network)
          INFERENCEBAR_PORT      talk to a different port
          INFERENCEBAR_API_KEY   use this key instead of reading it from the Keychain
        """)
    }
}
