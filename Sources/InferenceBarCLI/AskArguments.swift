import Foundation

/// What `inferencebar <args>` should do, decided from argv alone — kept
/// separate from CLI.swift so it's testable without touching stdin, the
/// network, or the process exit path.
enum AskArguments {
    enum Outcome: Equatable {
        /// A prompt was given on the command line, already joined and
        /// trimmed. nil means "read the prompt from stdin instead" —
        /// either nothing followed `ask`, or the sole argument was `-`,
        /// the conventional "read from stdin" placeholder.
        case ask(prompt: String?)
        case help
        case noCommand
        case unknownCommand(String)
    }

    /// `arguments` is CommandLine.arguments with the executable name
    /// already dropped.
    static func parse(_ arguments: [String]) -> Outcome {
        guard let first = arguments.first else { return .noCommand }
        if first == "--help" || first == "-h" { return .help }
        guard first == "ask" else { return .unknownCommand(first) }
        let rest = Array(arguments.dropFirst())
        // Joining multiple words lets an unquoted "inferencebar ask
        // what time is it" work the same as one quoted argument — a
        // small convenience with no real downside, since a prompt with
        // meaningful newlines or leading/trailing whitespace can still
        // always be piped in on stdin instead.
        let joined = rest.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return .ask(prompt: (joined.isEmpty || joined == "-") ? nil : joined)
    }
}
