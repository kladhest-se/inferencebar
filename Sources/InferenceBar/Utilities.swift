import AppKit
import CryptoKit
import Foundation

// Pure logic behind several small features, kept apart from AppStore and the
// views so each piece can be unit-tested without a running server, a network
// or a window: the disk-space check before a download, the speed test, the
// "Open OpenCode in a project" launcher, the OpenCode sync status, and the
// in-app update download.

// MARK: - Disk space before a download

enum DiskSpaceAdvisor {
    /// Kept free on top of the download itself: macOS needs room to work, and
    /// a disk filled to the last byte makes the whole Mac misbehave.
    static let reserveBytes: Int64 = 5 * 1_073_741_824

    /// nil when the download fits (or its size is unknown); otherwise a
    /// message ready to show the user. `alreadyPresentBytes` is what a resumed
    /// download has on disk already, which does not need room again.
    static func problem(requiredBytes: Int64, alreadyPresentBytes: Int64 = 0, availableBytes: Int64?, reserveBytes: Int64 = DiskSpaceAdvisor.reserveBytes) -> String? {
        guard requiredBytes > 0, let availableBytes else { return nil }
        let stillNeeded = max(requiredBytes - max(alreadyPresentBytes, 0), 0)
        guard stillNeeded + reserveBytes > availableBytes else { return nil }
        func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: max(bytes, 0), countStyle: .file) }
        return "Not enough free disk space for this download: \(size(stillNeeded)) still has to be fetched and \(size(reserveBytes)) is kept free for macOS, but only \(size(availableBytes)) is available on the disk that holds the model folder. Free some space, or choose another model location in Settings."
    }

    /// Free space on the volume holding `url`, which need not exist yet (the
    /// nearest folder that does is asked). nil if the system cannot say.
    static func availableBytes(at url: URL) -> Int64? {
        var probe = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        guard let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) else { return nil }
        return values.volumeAvailableCapacityForImportantUsage
    }
}

// MARK: - Speed test

struct SpeedMeasurement: Equatable, Sendable {
    var promptTokens: Int
    var generatedTokens: Int
    var promptTokensPerSecond: Double?
    var generationTokensPerSecond: Double?
    /// True when the server reported its own timings; false when the speeds
    /// were estimated from wall-clock time (so they include request overhead).
    var reportedByServer: Bool
}

struct SpeedTestSummary: Equatable, Sendable {
    var profileName: String
    var promptTokens: Int
    var promptTokensPerSecond: Double?
    var generationTokensPerSecond: Double?
    var estimated: Bool
    var finishedAt: Date
}

enum SpeedTest {
    static let generationTokenLimit = 128
    static let generationPrompt = "Write a short story about a lighthouse keeper who finds a message in a bottle."
    /// Roughly how many tokens one repetition of the filler sentence takes.
    private static let tokensPerFillerSentence = 22
    private static let fillerSentence = "The quick brown fox jumps over the lazy dog while the engineer reads another line of the log file. "

    /// How long the prompt-processing test prompt should be: long enough for
    /// the speed to be meaningful, short enough to fit the slot's context.
    /// llama.cpp splits its context between parallel slots.
    static func promptTokenTarget(contextSize: Int, parallel: Int) -> Int {
        let perSlot = contextSize / max(parallel, 1)
        return max(200, min(2000, perSlot / 2))
    }

    /// A deterministic filler prompt of about `approximateTokens` tokens. The
    /// nonce goes first so no server-side prompt cache can answer it from an
    /// earlier run, which would report an absurdly fast prompt speed.
    static func longPrompt(approximateTokens: Int, nonce: String) -> String {
        let repetitions = max(approximateTokens / tokensPerFillerSentence, 1)
        return "Reference \(nonce).\n" + String(repeating: fillerSentence, count: repetitions) + "\nIn one word, what animal was mentioned?"
    }

    static func requestBody(model: String?, prompt: String, maxTokens: Int, llamaCPP: Bool) -> [String: Any] {
        var body: [String: Any] = [
            "messages": [["role": "user", "content": prompt]],
            "max_tokens": maxTokens,
            "temperature": 0,
            "stream": false
        ]
        if let model { body["model"] = model }
        // A llama.cpp extension; other servers would ignore or reject it.
        if llamaCPP { body["cache_prompt"] = false }
        return body
    }

    /// Reads an OpenAI-style completion. llama.cpp adds a `timings` object
    /// with its own per-second figures, which are preferred; without them the
    /// speeds are estimated from the token counts and the elapsed time.
    static func parse(_ data: Data, elapsedSeconds: Double) -> SpeedMeasurement? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let usage = object["usage"] as? [String: Any]
        let timings = object["timings"] as? [String: Any]
        func number(_ dictionary: [String: Any]?, _ key: String) -> Double? {
            (dictionary?[key] as? NSNumber)?.doubleValue
        }
        let promptTokens = Int(number(usage, "prompt_tokens") ?? number(timings, "prompt_n") ?? 0)
        let generated = Int(number(usage, "completion_tokens") ?? number(timings, "predicted_n") ?? 0)
        guard promptTokens > 0 || generated > 0 else { return nil }
        let promptRate = number(timings, "prompt_per_second")
        let generationRate = number(timings, "predicted_per_second")
        if promptRate != nil || generationRate != nil {
            return SpeedMeasurement(promptTokens: promptTokens, generatedTokens: generated, promptTokensPerSecond: promptRate, generationTokensPerSecond: generationRate, reportedByServer: true)
        }
        let elapsed = max(elapsedSeconds, 0.001)
        return SpeedMeasurement(
            promptTokens: promptTokens,
            generatedTokens: generated,
            promptTokensPerSecond: promptTokens > 0 ? Double(promptTokens) / elapsed : nil,
            generationTokensPerSecond: generated > 0 ? Double(generated) / elapsed : nil,
            reportedByServer: false
        )
    }

    static func summary(profileName: String, prompt: SpeedMeasurement?, generation: SpeedMeasurement?, now: Date = Date()) -> SpeedTestSummary? {
        guard prompt != nil || generation != nil else { return nil }
        let estimated = !((prompt?.reportedByServer ?? true) && (generation?.reportedByServer ?? true))
        return SpeedTestSummary(
            profileName: profileName,
            promptTokens: prompt?.promptTokens ?? 0,
            promptTokensPerSecond: prompt?.promptTokensPerSecond,
            generationTokensPerSecond: generation?.generationTokensPerSecond,
            estimated: estimated,
            finishedAt: now
        )
    }
}

// MARK: - OpenCode sync status and launcher

/// What the last OpenCode sync did, kept on the store so it is visible on the
/// Settings card however the sync was triggered (including the automatic one
/// when a coding preset is added), not only after pressing "Sync now".
struct OpenCodeSyncStatus: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case synced, noCodingProfiles, openCodeNotSetUp, failed }
    var kind: Kind
    var message: String
    /// Display names of the profiles that were written to OpenCode's config.
    var models: [String]
    var date: Date

    var isSuccess: Bool { kind == .synced }
}

enum OpenCodeLauncher {
    enum Plan: Equatable {
        case useRunning(UUID)
        case startProfile(UUID)
        case blocked(String)
        case noProfile
    }

    /// Which profile "Open OpenCode" should use. A server that is already up
    /// is never switched away from silently: it is used if it is a coding
    /// profile and otherwise the user is asked to stop it. A stopped server is
    /// started with the default coding profile, or the first coding profile.
    static func plan(codingProfileIDs: [UUID], runningProfileID: UUID?, serverIsActive: Bool, defaultProfileID: UUID?) -> Plan {
        guard !codingProfileIDs.isEmpty else { return .noProfile }
        if serverIsActive {
            if let runningProfileID, codingProfileIDs.contains(runningProfileID) { return .useRunning(runningProfileID) }
            return .blocked("The server is running a profile that is not a coding profile. Stop it first, or start one of your coding profiles, then try again.")
        }
        if let defaultProfileID, codingProfileIDs.contains(defaultProfileID) { return .startProfile(defaultProfileID) }
        return .startProfile(codingProfileIDs[0])
    }

    /// Wraps text for a POSIX shell in single quotes, so spaces, `$` and
    /// backticks in a folder name mean nothing to the shell.
    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The Terminal script: wait for the server, then run OpenCode in the
    /// project folder. The API key is deliberately never written into it.
    static func script(directory: String, healthURL: String, authenticationEnabled: Bool) -> String {
        var lines: [String] = [
            "#!/bin/zsh",
            #"export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.opencode/bin:$PATH""#,
            "cd \(shellQuote(directory)) || { echo 'Could not open the project folder.'; sleep 5; exit 1; }",
            "if ! command -v opencode >/dev/null 2>&1; then",
            "  echo 'OpenCode is not installed. Install it from InferenceBar > Settings > OpenCode.'",
            "  sleep 8",
            "  exit 1",
            "fi",
            "echo \"Waiting for InferenceBar's server...\"",
            "i=0",
            "while [ $i -lt 600 ]; do",
            "  code=$(curl -k -s -o /dev/null -w '%{http_code}' --max-time 2 \(shellQuote(healthURL)) 2>/dev/null)",
            "  case \"$code\" in 200|401|403) break ;; esac",
            "  i=$((i+1))",
            "  sleep 1",
            "done"
        ]
        if authenticationEnabled {
            lines.append(#"[ -n "$INFERENCE_API_KEY" ] || echo "Note: API-key authentication is on; export INFERENCE_API_KEY in your shell profile so OpenCode can use it.""#)
        }
        lines.append("exec opencode")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes the script to a private temporary folder and opens it, which
    /// macOS hands to Terminal. Scripts older than a day are cleaned up.
    @MainActor
    static func launch(script: String) throws {
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory.appendingPathComponent("InferenceBar-opencode", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        for old in (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let modified = (try? old.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantFuture
            if modified < cutoff { try? fileManager.removeItem(at: old) }
        }
        let file = folder.appendingPathComponent("opencode-\(UUID().uuidString).command")
        try script.write(to: file, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        NSWorkspace.shared.open(file)
    }
}

// MARK: - In-app update download

enum UpdateDownload {
    static let repository = "kladhest-se/inferencebar"

    /// "v0.7.1" -> "0.7.1". Only a v followed by a digit is a prefix.
    static func version(fromTag tag: String) -> String {
        var value = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = value.first, first == "v" || first == "V", value.dropFirst().first?.isNumber == true {
            value.removeFirst()
        }
        return value
    }

    /// The file name `make macos-package` gives the DMG.
    static func dmgFilename(tag: String) -> String {
        "InferenceBar-\(version(fromTag: tag))-macos.dmg"
    }

    /// Where a release asset lives on GitHub. nil for a tag that cannot be a
    /// single path component (a slash would change which URL this builds).
    static func assetURL(tag: String, filename: String) -> URL? {
        guard !tag.isEmpty, !tag.contains("/"), !filename.contains("/"),
              let encodedTag = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let encodedName = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "https://github.com/\(repository)/releases/download/\(encodedTag)/\(encodedName)")
    }

    /// The hash from a `shasum -a 256` line ("<64 hex>  <name>"), lowercased.
    static func expectedSHA256(fromChecksumFile text: String) -> String? {
        for token in text.split(whereSeparator: { $0.isWhitespace }) {
            let candidate = token.lowercased()
            if candidate.count == 64, candidate.allSatisfy({ $0.isHexDigit }) { return candidate }
        }
        return nil
    }

    static func sha256Hex(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
