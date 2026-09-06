import Foundation
import Darwin

enum ModelFit: String {
    case comfortable = "Comfortable"
    case tight = "Tight"
    case unsupported = "Unsupported"
}

struct MacHardwareProfile {
    let chip: String
    let physicalMemory: Int64
    let availableDisk: Int64

    static func current(modelDirectory: String) -> Self {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        let chipBytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let chip = String(decoding: chipBytes, as: UTF8.self).replacingOccurrences(of: "Apple ", with: "")
        let requested = URL(fileURLWithPath: NSString(string: modelDirectory).expandingTildeInPath, isDirectory: true)
        var probe = requested
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" { probe.deleteLastPathComponent() }
        let disk = (try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? 0
        return .init(chip: chip.isEmpty ? "Apple Silicon" : chip, physicalMemory: Int64(ProcessInfo.processInfo.physicalMemory), availableDisk: disk)
    }
}

struct ModelFitAssessment {
    let fit: ModelFit
    let requiredMemory: Int64
    let kvCache: Int64
    let contextSize: Int
    let reason: String
}

enum ModelHardwareAdvisor {
    static func assess(fileSize: Int64, filename: String, contextSize: Int, hardware: MacHardwareProfile, alreadyDownloaded: Bool) -> ModelFitAssessment {
        let parametersB = parameterCountBillions(from: filename) ?? max(Double(fileSize) / 0.65 / 1_000_000_000, 1)
        let kvCache = Int64(parametersB * Double(max(contextSize, 1)) * 1_536)
        let runtimeOverhead = max(Int64(Double(fileSize) * 0.10), 2_000_000_000)
        let required = fileSize + kvCache + runtimeOverhead
        if !alreadyDownloaded, hardware.availableDisk > 0, fileSize > Int64(Double(hardware.availableDisk) * 0.92) {
            return .init(fit: .unsupported, requiredMemory: required, kvCache: kvCache, contextSize: contextSize, reason: "Not enough available disk space")
        }
        let ratio = hardware.physicalMemory > 0 ? Double(required) / Double(hardware.physicalMemory) : 1
        if ratio <= 0.72 {
            return .init(fit: .comfortable, requiredMemory: required, kvCache: kvCache, contextSize: contextSize, reason: "Good memory headroom")
        }
        if ratio <= 0.92 {
            return .init(fit: .tight, requiredMemory: required, kvCache: kvCache, contextSize: contextSize, reason: "Limited memory headroom")
        }
        return .init(fit: .unsupported, requiredMemory: required, kvCache: kvCache, contextSize: contextSize, reason: "Estimated memory exceeds safe unified-memory capacity")
    }

    private static func parameterCountBillions(from filename: String) -> Double? {
        guard let expression = try? NSRegularExpression(pattern: #"(?i)(\d+(?:\.\d+)?)B(?:-|_|\b)"#),
              let match = expression.firstMatch(in: filename, range: NSRange(filename.startIndex..., in: filename)),
              let range = Range(match.range(at: 1), in: filename) else { return nil }
        return Double(filename[range])
    }
}

/// How full a profile's fixed context window is, coarsened into three
/// bands so the UI can color-code it instead of showing a raw percentage
/// everywhere: `normal` needs no attention, `elevated` is worth noticing,
/// `critical` means the next few turns risk the model silently losing
/// earlier context (llama.cpp/MLX servers just drop or shift the oldest
/// tokens once the window is full — there's no error, only degraded
/// answers).
enum ContextUsageLevel: Equatable {
    case normal, elevated, critical
}

struct RuntimeHealth: Equatable {
    var pid: Int32?
    var memoryBytes: Int64 = 0
    var activeRequests = 0
    var tokensPerSecond: Double?
    var contextTokens = 0
    var contextLimit = 0
    var uptime: TimeInterval = 0
    var loadingProgress: Double?

    /// 0...1, or 0 when the limit isn't known yet (nothing parsed from
    /// the logs so far, or no profile is running).
    var contextFraction: Double { contextLimit > 0 ? min(Double(contextTokens) / Double(contextLimit), 1) : 0 }

    /// Thresholds match the memory-headroom bands ModelHardwareAdvisor
    /// already uses elsewhere in the app (comfortable/tight cutoffs at
    /// 0.72/0.92), rounded to easier-to-read numbers for a token count a
    /// user will actually watch climb during a conversation.
    var contextUsageLevel: ContextUsageLevel {
        guard contextLimit > 0 else { return .normal }
        if contextFraction >= 0.92 { return .critical }
        if contextFraction >= 0.75 { return .elevated }
        return .normal
    }
}

enum RuntimeTelemetryParser {
    static func parse(_ logs: String, contextLimit: Int) -> RuntimeHealth {
        var health = RuntimeHealth(contextLimit: contextLimit)
        var launched = Set<String>()
        var released = Set<String>()
        for line in logs.split(separator: "\n").suffix(2_000).map(String.init) {
            if let task = capture(#"task\s+(\d+)"#, in: line) {
                if line.contains("launch_slot") { launched.insert(task) }
                if line.contains("release") || line.contains("stop processing") { released.insert(task) }
            }
            if let value = capture(#"(?:tg|tg_3s)\s*=\s*([0-9.]+)\s*t/s"#, in: line).flatMap(Double.init) { health.tokensPerSecond = value }
            if let value = capture(#"n_tokens\s*=\s*(\d+)"#, in: line).flatMap(Int.init) { health.contextTokens = value }
            if let value = capture(#"progress\s*=\s*([0-9.]+)"#, in: line).flatMap(Double.init) { health.loadingProgress = min(max(value, 0), 1) }
        }
        health.activeRequests = launched.subtracting(released).count
        return health
    }

    private static func capture(_ pattern: String, in value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }
}

struct ModelPreflightReport: Equatable {
    var architecture: String?
    var formatVersion: Int?
    var errors: [String] = []
    var warnings: [String] = []
    var isCompatible: Bool { errors.isEmpty }
    var message: String { (errors + warnings).joined(separator: "\n") }
}

enum ModelCompatibilityValidator {
    private static let llamaArchitectures: Set<String> = ["llama", "llava", "qwen2", "qwen2vl", "qwen3", "qwen3moe", "qwen35", "qwen35moe", "qwen3next", "qwen3nextmoe", "qwen3vl", "mistral", "mixtral", "gemma", "gemma2", "gemma3", "phi2", "phi3", "deepseek", "deepseek2", "starcoder", "starcoder2", "command-r", "granite", "cohere2", "internlm2", "baichuan", "falcon", "gpt2", "gptneox", "bert", "nomic-bert", "mamba", "rwkv6", "jais", "chatglm", "minicpm"]
    private static let mlxArchitectures: Set<String> = ["llama", "qwen2", "qwen3", "qwen3_moe", "mistral", "mixtral", "gemma", "gemma2", "gemma3", "phi3", "deepseek_v2", "deepseek_v3", "starcoder2", "cohere", "granite", "internlm2"]

    static func inspectGGUF(at url: URL, contextSize: Int, hardware: MacHardwareProfile) -> ModelPreflightReport {
        var report = ModelPreflightReport()
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count >= 24 else {
            report.errors.append("The GGUF file cannot be read or is truncated."); return report
        }
        guard String(decoding: data.prefix(4), as: UTF8.self) == "GGUF" else {
            report.errors.append("The selected file is not a valid GGUF model."); return report
        }
        var reader = GGUFReader(data: data)
        guard let metadata = reader.metadata() else { report.errors.append("The GGUF metadata header is damaged or unsupported."); return report }
        report.formatVersion = metadata.version
        report.architecture = metadata.strings["general.architecture"]
        if metadata.version > 3 { report.errors.append("GGUF version \(metadata.version) is newer than this runtime supports (maximum: 3).") }
        if let architecture = report.architecture, !supportsGGUFArchitecture(architecture) {
            // Advisory, not blocking: this list is a snapshot of what
            // llama.cpp supported when InferenceBar shipped, and new
            // architectures land in llama.cpp faster than this list gets
            // updated. The readiness probe after actually starting the
            // server is the real, current answer — a hard block here would
            // reject models the runtime you just upgraded already handles.
            report.warnings.append("\"\(architecture)\" is not in InferenceBar's known-compatible list — that list may just be out of date. If llama-server fails to start, that confirms it doesn't support it yet; if it starts fine, this warning can be ignored.")
        } else if report.architecture == nil { report.errors.append("The GGUF does not declare general.architecture.") }
        let name = url.lastPathComponent.lowercased()
        let looksMultimodal = ["llava", "vision", "-vl-", "_vl_"].contains { name.contains($0) }
        if looksMultimodal && !name.contains("mmproj") {
            let siblings = (try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? []
            if MultimodalProjector.projectorFilename(forModel: url.lastPathComponent, siblingFilenames: siblings) == nil {
                report.errors.append("This multimodal model requires a matching mmproj projector GGUF in the same folder.")
            }
        }
        let fit = ModelHardwareAdvisor.assess(fileSize: Int64(data.count), filename: url.lastPathComponent, contextSize: contextSize, hardware: hardware, alreadyDownloaded: true)
        if fit.fit == .unsupported { report.errors.append("Insufficient unified memory: about \(ByteCountFormatter.string(fromByteCount: fit.requiredMemory, countStyle: .memory)) is required for the model and KV cache.") }
        else if fit.fit == .tight { report.warnings.append("Memory will be tight at the selected context size; estimated requirement is \(ByteCountFormatter.string(fromByteCount: fit.requiredMemory, countStyle: .memory)).") }
        return report
    }

    static func supportsGGUFArchitecture(_ architecture: String) -> Bool {
        let normalized = architecture
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
        return llamaArchitectures.contains(normalized)
    }

    static func inspectMLX(at directory: URL) -> ModelPreflightReport {
        var report = ModelPreflightReport()
        let configURL = directory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            report.errors.append("Missing or invalid MLX config.json."); return report
        }
        let architecture = (json["model_type"] as? String) ?? (json["architectures"] as? [String])?.first
        report.architecture = architecture
        if let architecture {
            let normalized = architecture.lowercased().replacingOccurrences(of: "forcausallm", with: "").replacingOccurrences(of: "_", with: "")
            if !mlxArchitectures.contains(where: { normalized.contains($0.replacingOccurrences(of: "_", with: "")) }) {
                // Same reasoning as the GGUF check above: advisory, since
                // this list goes stale faster than mlx-lm itself does.
                report.warnings.append("\"\(architecture)\" is not in InferenceBar's known-compatible list — that list may just be out of date. If mlx-lm fails to start, that confirms it doesn't support it yet; if it starts fine, this warning can be ignored.")
            }
        } else { report.errors.append("The MLX config does not declare model_type or architectures.") }
        let weights = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        if !weights.contains(where: { $0.hasSuffix(".safetensors") }) { report.errors.append("No MLX .safetensors weight files were found.") }
        return report
    }
}

// llama-server needs an mmproj projector file passed explicitly via
// --mmproj to actually accept image input for a multimodal GGUF -- it
// does not auto-discover one sitting next to the model on its own.
// ModelCompatibilityValidator.inspectGGUF above only validates that a
// projector exists before a multimodal model is considered runnable at
// all; this is what finds its actual path so ServerProfile.arguments(network:)
// can launch llama-server with it.
enum MultimodalProjector {
    /// Picks the sibling projector file for a model, given the other
    /// filenames in its directory. Pure and testable on its own —
    /// path(forModelPath:) below does the actual directory listing.
    ///
    /// Candidates are additionally required to share the model's own
    /// "family" tokens (see familyTokens below) unless the candidate's
    /// own name carries no family tokens at all (a generically-named
    /// projector like "mmproj-f16.gguf", with nothing to disagree with).
    /// This app's model folder is flat and shared across every
    /// downloaded model (see the preset auto-download comments
    /// elsewhere in this file), so once it holds projectors for more
    /// than one vision model family, matching "any mmproj file in the
    /// folder" (the original, simpler rule) can hand llama-server a
    /// projector built for a completely different model -- which
    /// crashes it outright on a tensor-shape mismatch rather than just
    /// failing to see images. Matching by family keeps the common case
    /// (one model, one same-named projector, or a generic unnamed one)
    /// working exactly as before, while refusing to pair, say,
    /// "Qwen3.6-35B-A3B-Q5_K_M.gguf" with "mmproj-Qwen3VL-32B-Instruct-F16.gguf"
    /// just because both happen to live in ~/ai-models.
    static func projectorFilename(forModel modelFilename: String, siblingFilenames: [String]) -> String? {
        let modelName = modelFilename.lowercased()
        let modelFamily = Set(familyTokens(modelFilename, isProjector: false))
        let candidates = siblingFilenames.filter { candidate in
            let lower = candidate.lowercased()
            guard lower.hasSuffix(".gguf"), lower.contains("mmproj"), lower != modelName else { return false }
            let projectorFamily = Set(familyTokens(candidate, isProjector: true))
            return projectorFamily.isEmpty || projectorFamily == modelFamily
        }
        // More than one projector in the same folder is unusual (a model
        // swapped in without cleaning up the old one) but not impossible
        // -- sorted() keeps the choice deterministic rather than
        // depending on directory-enumeration order.
        return candidates.sorted().first
    }

    /// Splits a GGUF filename (its stem, extension dropped) into
    /// lowercase alphanumeric tokens on any run of separator characters,
    /// so "Qwen_Qwen3.6-35B" and "Qwen-Qwen3-6-35B" tokenize identically
    /// regardless of which separator convention a given quantizer used.
    private static func tokenize(_ filename: String) -> [String] {
        let stem = (filename as NSString).deletingPathExtension.lowercased()
        return stem.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// Whether a token looks like a quantization/precision marker (Q4,
    /// Q5_K_M's "q5", Q8_0's "q8", F16, F32, BF16, IQ4_XS's "iq4", ...)
    /// rather than part of the model's actual name -- once one of these
    /// turns up, everything after it in the filename is quant/precision
    /// detail, not model identity.
    private static func isQuantOrPrecisionMarker(_ token: String) -> Bool {
        if ["f16", "f32", "bf16", "fp16", "fp32"].contains(token) { return true }
        return token.range(of: #"^i?q\d+$"#, options: .regularExpression) != nil
    }

    /// The tokens identifying which model family/size a filename names,
    /// stopping at the first quant/precision marker -- ["qwen3vl", "32b",
    /// "instruct"] out of "Qwen3VL-32B-Instruct-Q4_K_M.gguf", not the
    /// quant tail. A projector filename has its leading "mmproj" token
    /// dropped first, since that prefix is naming convention, not model
    /// identity.
    private static func familyTokens(_ filename: String, isProjector: Bool) -> [String] {
        var tokens = tokenize(filename)
        if isProjector, tokens.first == "mmproj" { tokens.removeFirst() }
        var family: [String] = []
        for token in tokens {
            if isQuantOrPrecisionMarker(token) { break }
            family.append(token)
        }
        return family
    }

    /// Whether a *remote* Hugging Face repo's sibling filenames include a
    /// vision projector -- unlike projectorFilename above (which picks
    /// one sibling for an already-chosen local model file), this just
    /// asks "does this repo ship one at all", to judge a repo before
    /// anything from it is downloaded. Hugging Face's own pipeline_tag
    /// metadata on a GGUF requant repo is frequently just
    /// "text-generation" even when the repo is a straight vision-model
    /// conversion -- whoever requantized it often doesn't bother
    /// re-tagging it -- so this file-presence check is the reliable
    /// signal for "can this GGUF repo actually see images", not the tag.
    static func hasProjectorSibling(among siblingFilenames: [String]) -> Bool {
        siblingFilenames.contains { candidate in
            let lower = candidate.lowercased()
            return lower.hasSuffix(".gguf") && lower.contains("mmproj")
        }
    }

    static func path(forModelPath modelPath: String, fileManager: FileManager = .default) -> String? {
        let expanded = NSString(string: modelPath).expandingTildeInPath
        let modelURL = URL(fileURLWithPath: expanded)
        guard fileManager.fileExists(atPath: modelURL.path) else { return nil }
        let directory = modelURL.deletingLastPathComponent()
        guard let siblings = try? fileManager.contentsOfDirectory(atPath: directory.path),
              let match = projectorFilename(forModel: modelURL.lastPathComponent, siblingFilenames: siblings) else { return nil }
        return directory.appendingPathComponent(match).path
    }
}

private struct GGUFReader {
    let data: Data
    var offset = 4
    mutating func metadata() -> (version: Int, strings: [String: String])? {
        guard let version: UInt32 = read(), let _: UInt64 = read(), let count: UInt64 = read(), count < 1_000_000 else { return nil }
        var values: [String: String] = [:]
        for _ in 0..<count {
            guard let key = string(), let type: UInt32 = read() else { return nil }
            if type == 8 { guard let value = string() else { return nil }; values[key] = value }
            else if !skip(type: type) { return nil }
        }
        return (Int(version), values)
    }
    mutating func read<T: FixedWidthInteger>() -> T? {
        let size = MemoryLayout<T>.size; guard offset + size <= data.count else { return nil }
        let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
        offset += size; return T(littleEndian: value)
    }
    mutating func string() -> String? {
        guard let length: UInt64 = read(), length <= 16_777_216, offset + Int(length) <= data.count else { return nil }
        defer { offset += Int(length) }
        return String(data: data[offset..<(offset + Int(length))], encoding: .utf8)
    }
    mutating func skip(type: UInt32) -> Bool {
        let sizes: [UInt32: Int] = [0:1, 1:1, 2:2, 3:2, 4:4, 5:4, 6:4, 7:1, 10:8, 11:8, 12:8]
        if let size = sizes[type] { guard offset + size <= data.count else { return false }; offset += size; return true }
        if type == 9 {
            guard let element: UInt32 = read(), let count: UInt64 = read(), count < 100_000_000 else { return false }
            for _ in 0..<count { if element == 8 { guard string() != nil else { return false } } else if !skip(type: element) { return false } }
            return true
        }
        return false
    }
}

enum DownloadResumeStore {
    static func url(for destination: URL) -> URL {
        destination.appendingPathExtension("resumeData")
    }

    static func load(for destination: URL) -> Data? {
        try? Data(contentsOf: url(for: destination))
    }

    static func save(_ data: Data, for destination: URL) throws {
        try data.write(to: url(for: destination), options: .atomic)
    }

    static func remove(for destination: URL) {
        try? FileManager.default.removeItem(at: url(for: destination))
    }
}

/// Pure math for splitting one file into several contiguous byte ranges
/// so DownloadController (AppStore.swift) can fetch them concurrently
/// over separate HTTP Range requests instead of one connection end to
/// end -- Hugging Face's CDN serves these from S3/CloudFront, which
/// (unlike the origin git server) comfortably serves several
/// simultaneous ranged reads of the same object at full speed each, so
/// splitting turns one connection's throughput ceiling into several.
/// Kept separate from DownloadController so the range math is
/// unit-testable without spinning up URLSession. Ranges are inclusive
/// on both ends, matching HTTP's own "Range: bytes=start-end" header.
enum ParallelDownloadPlanner {
    static let chunkCount = 4
    /// Below this, connection setup overhead for extra parallel streams
    /// isn't worth it -- a preset's ~4 GB quant clears this easily, but a
    /// tiny file (or a probe that only turned up a small resource) stays
    /// on the plain single-stream path instead.
    static let minimumBytesToSplit: Int64 = 32 * 1024 * 1024

    static func shouldSplit(totalBytes: Int64) -> Bool {
        totalBytes >= minimumBytesToSplit
    }

    /// `chunkCount` contiguous ranges spanning `0...(totalBytes - 1)`,
    /// each as close to equal size as integer division allows (the last
    /// range absorbs the remainder). Never returns more ranges than
    /// there are bytes, so a small `totalBytes` degrades to fewer,
    /// still-valid single-byte-or-larger ranges instead of an empty one.
    static func chunkRanges(totalBytes: Int64, chunkCount: Int = chunkCount) -> [ClosedRange<Int64>] {
        guard totalBytes > 0, chunkCount > 0 else { return [] }
        let count = totalBytes < Int64(chunkCount) ? Int(totalBytes) : chunkCount
        let size = totalBytes / Int64(count)
        var ranges: [ClosedRange<Int64>] = []
        var start: Int64 = 0
        for index in 0..<count {
            let end = index == count - 1 ? totalBytes - 1 : start + size - 1
            ranges.append(start...max(start, end))
            start = end + 1
        }
        return ranges
    }
}

enum MLXSnapshotResolver {
    static func resolve(modelID: String, root: URL) -> URL? {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~"), trimmed.contains("/") else { return nil }
        let repo = "models--" + trimmed.replacingOccurrences(of: "/", with: "--")
        let snapshots = root.appendingPathComponent("\(repo)/snapshots")
        guard let revisions = try? FileManager.default.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        return revisions.filter { revision in
            guard FileManager.default.fileExists(atPath: revision.appendingPathComponent("config.json").path),
                  let files = try? FileManager.default.contentsOfDirectory(at: revision, includingPropertiesForKeys: nil) else { return false }
            return files.contains { $0.pathExtension.lowercased() == "safetensors" && FileManager.default.fileExists(atPath: $0.path) }
        }.max { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left < right
        }
    }
}

struct ModelManifestEntry: Codable, Identifiable, Hashable {
    var id: String { "\(sourceModelID)|\(filename)" }
    let sourceModelID: String
    let revision: String?
    let filename: String
    let checksumSHA256: String?
    var checksumVerified: Bool? = nil
    var license: String? = nil
    var quantization: String? = nil
    let format: String
    let localPath: String
    let size: Int64
    let downloadedAt: Date
}

enum ModelProvenance {
    static func license(from tags: [String]?) -> String? {
        tags?.first(where: { $0.lowercased().hasPrefix("license:") }).map { String($0.dropFirst("license:".count)) }
    }

    static func quantization(from filename: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: #"(?i)(?:^|[-_.])(IQ\d+(?:_[A-Z0-9]+)*|Q\d+(?:_[A-Z0-9]+)*)(?:[-_.]|$)"#),
              let match = expression.firstMatch(in: filename, range: NSRange(filename.startIndex..., in: filename)),
              let range = Range(match.range(at: 1), in: filename) else { return nil }
        return String(filename[range]).uppercased()
    }

    static func repositoryURL(for modelID: String) -> URL? {
        guard modelID.split(separator: "/").count == 2 else { return nil }
        return URL(string: "https://huggingface.co/\(modelID)")
    }

    static func revisionURL(for entry: ModelManifestEntry) -> URL? {
        guard let revision = entry.revision, !revision.isEmpty,
              let repository = repositoryURL(for: entry.sourceModelID) else { return nil }
        return repository.appendingPathComponent("tree").appendingPathComponent(revision)
    }
}

enum ModelMetadataManifest {
    static let filename = ".inferencebar-model-manifest.json"

    static func load(from root: URL) -> [ModelManifestEntry] {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(filename)) else { return [] }
        return (try? JSONDecoder().decode([ModelManifestEntry].self, from: data)) ?? []
    }

    static func save(_ entries: [ModelManifestEntry], to root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entries).write(to: root.appendingPathComponent(filename), options: .atomic)
    }
}

enum InferenceBackend: String, Codable, CaseIterable, Identifiable {
    case llamaCPP
    case mlxLM
    case vllmMLX

    var id: String { rawValue }
    var title: String {
        switch self {
        case .llamaCPP: "llama.cpp · GGUF"
        case .mlxLM: "Apple MLX · mlx-lm"
        case .vllmMLX: "vLLM-MLX"
        }
    }
    var defaultExecutable: String {
        switch self {
        case .llamaCPP: "llama-server"
        case .mlxLM: "mlx_lm.server"
        case .vllmMLX: "vllm-mlx"
        }
    }
    var usesGGUF: Bool { self == .llamaCPP }
}

struct ServerProfile: Codable, Identifiable, Hashable {
    var id = UUID()
    var backend: InferenceBackend? = nil
    var name = "New profile"
    var executable = "llama-server"
    var modelPath = ""
    var alias = "local-model"
    var contextSize = 4096
    var parallel = 1
    var flashAttention = true
    var jinja = true
    var cacheRAM = 0
    var reasoning = "auto"
    var reasoningBudget = 0
    var reasoningFormat = "deepseek"
    var reasoningPreserve = false
    var maximumOutputTokens: Int? = nil
    var extraArguments = ""
    // Advanced llama.cpp cache controls. Optional (rather than a plain Int
    // / Bool with a default) so an existing profiles.json saved before
    // these fields existed still decodes: Swift's synthesized Decodable
    // only tolerates a missing JSON key for an Optional property, not a
    // non-Optional one with a default value.
    var cacheReuse: Int? = nil
    var swaFull: Bool? = nil
    // When true, skip the defensive "erase every slot and disable
    // cache_prompt on every turn" behavior InferenceBar's own chat
    // otherwise always applies (see AppStore.sendPrompt) — only safe to
    // turn on if nothing else ever talks to this same running server.
    var exclusiveToInferenceBar: Bool? = nil
    // Optional (rather than a plain String default) for the same reason
    // as cacheReuse/swaFull above: an existing profiles.json predates
    // this field. nil, or all-whitespace, means "use the app-wide
    // default system prompt from Settings" — set it to give just this
    // profile a persona, coding-specific instructions, or a language
    // preference. See effectiveSystemPrompt(fallback:).
    var systemPrompt: String? = nil

    var runtime: InferenceBackend { backend ?? .llamaCPP }
    var effectiveMaximumOutputTokens: Int { min(max(maximumOutputTokens ?? 8_192, 256), 65_536) }
    // The system prompt actually sent to the model for this profile:
    // this profile's own override when it has one, otherwise the
    // app-wide default passed in from Settings.
    func effectiveSystemPrompt(fallback: String) -> String {
        let trimmed = (systemPrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
    var chatDisplayName: String {
        let genericAliases = ["default", "default_model", "local-model", "local_model"]
        let normalizedAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return genericAliases.contains(normalizedAlias) || normalizedAlias.isEmpty ? name : alias
    }

    func arguments(network: GlobalServerSettings) -> [String] {
        let model = NSString(string: modelPath).expandingTildeInPath
        var result: [String]
        switch runtime {
        case .llamaCPP:
            result = ["--model", model,
                      "--alias", alias,
                      "--ctx-size", String(contextSize),
                      "--parallel", String(parallel),
                      "--flash-attn", flashAttention ? "on" : "off",
                      "--slots",
                      "--host", network.effectiveListenAddress, "--port", String(network.port)]
            if jinja { result.append("--jinja") }
            if cacheRAM > 0 { result += ["--cache-ram", String(cacheRAM)] }
            if !reasoning.isEmpty { result += ["--reasoning", reasoning] }
            if reasoningBudget > 0 { result += ["--reasoning-budget", String(reasoningBudget)] }
            if !reasoningFormat.isEmpty { result += ["--reasoning-format", reasoningFormat] }
            if reasoningPreserve { result.append("--reasoning-preserve") }
            if network.authenticationEnabled && !network.apiKey.isEmpty { result += ["--api-key", network.apiKey] }
            if let cacheReuse, cacheReuse > 0 { result += ["--cache-reuse", String(cacheReuse)] }
            if swaFull == true { result.append("--swa-full") }
            if !network.sslCertPath.isEmpty && !network.sslKeyPath.isEmpty {
                result += ["--ssl-cert-file", NSString(string: network.sslCertPath).expandingTildeInPath,
                           "--ssl-key-file", NSString(string: network.sslKeyPath).expandingTildeInPath]
            }
            // A vision-capable GGUF (Qwen3-VL and similar) is useless for
            // image input without this -- llama-server ignores any image
            // content in a request unless it was launched with its
            // projector loaded. Detected from whatever mmproj GGUF sits
            // next to the model, the same file ModelCompatibilityValidator
            // already requires be there before such a model is considered
            // runnable at all.
            if let mmproj = MultimodalProjector.path(forModelPath: modelPath) { result += ["--mmproj", mmproj] }
        case .mlxLM:
            result = ["--model", model, "--host", network.effectiveListenAddress, "--port", String(network.port)]
            if parallel > 0 {
                result += ["--decode-concurrency", String(parallel), "--prompt-concurrency", String(parallel)]
            }
            if cacheRAM > 0 { result += ["--prompt-cache-size", String(cacheRAM)] }
        case .vllmMLX:
            result = ["serve", model, "--host", network.effectiveListenAddress, "--port", String(network.port)]
            if cacheRAM > 0 { result += ["--cache-memory-mb", String(cacheRAM)] }
            if network.authenticationEnabled && !network.apiKey.isEmpty { result += ["--api-key", network.apiKey] }
        }
        result += extraArguments.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return result
    }
}

struct DownloadedModelOption: Identifiable, Hashable {
    enum Format: String { case gguf = "GGUF", mlx = "MLX" }
    var id: String { path }
    let name: String
    let path: String
    let format: Format
    let size: Int64
    func supports(_ runtime: InferenceBackend) -> Bool { runtime.usesGGUF ? format == .gguf : format == .mlx }
}

enum DownloadedModelCatalog {
    static func scan(root: URL) -> [DownloadedModelOption] {
        let fm = FileManager.default
        var found: [DownloadedModelOption] = []
        if let enumerator = fm.enumerator(atPath: root.path) {
            for case let relative as String in enumerator where relative.lowercased().hasSuffix(".gguf") {
                let url = root.appendingPathComponent(relative)
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                found.append(.init(name: url.lastPathComponent, path: url.path, format: .gguf, size: size))
            }
        }
        if let repos = try? fm.contentsOfDirectory(atPath: root.path) {
            for repo in repos where repo.hasPrefix("models--") {
                let modelID = String(repo.dropFirst(8)).replacingOccurrences(of: "--", with: "/")
                let snapshots = root.appendingPathComponent(repo).appendingPathComponent("snapshots")
                guard let revisions = try? fm.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
                for revision in revisions where fm.fileExists(atPath: revision.appendingPathComponent("config.json").path) {
                    guard let files = try? fm.contentsOfDirectory(at: revision, includingPropertiesForKeys: nil),
                          files.contains(where: { $0.pathExtension.lowercased() == "safetensors" }) else { continue }
                    found.append(.init(name: modelID, path: revision.path, format: .mlx, size: directorySize(revision)))
                }
            }
        }
        return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func directorySize(_ root: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0; var targets = Set<String>()
        for case let url as URL in enumerator {
            let target = url.resolvingSymlinksInPath()
            guard targets.insert(target.path).inserted, let values = try? target.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}

struct GlobalServerSettings: Codable, Equatable {
    var networkEnabled = false
    var listenAddress = "0.0.0.0"
    var port = 8080
    var authenticationEnabled = false
    // Lives in the keychain (APIKeyKeychain in AppStore.swift), never in
    // the plain-JSON settings file on disk — see the hand-written
    // init(from:)/encode(to:) below, which never touches this field.
    var apiKey = ""
    var sslCertPath = ""
    var sslKeyPath = ""

    init() {}

    private enum CodingKeys: String, CodingKey {
        case networkEnabled, listenAddress, port, authenticationEnabled, sslCertPath, sslKeyPath
    }

    // Hand-written rather than synthesized so there is no ambiguity about
    // whether apiKey (deliberately absent from CodingKeys) round-trips: it
    // never does. Decoding always leaves it at "" — AppStore fills it in
    // from the keychain right after — and encoding never writes it out.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        networkEnabled = try c.decodeIfPresent(Bool.self, forKey: .networkEnabled) ?? false
        listenAddress = try c.decodeIfPresent(String.self, forKey: .listenAddress) ?? "0.0.0.0"
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 8080
        authenticationEnabled = try c.decodeIfPresent(Bool.self, forKey: .authenticationEnabled) ?? false
        sslCertPath = try c.decodeIfPresent(String.self, forKey: .sslCertPath) ?? ""
        sslKeyPath = try c.decodeIfPresent(String.self, forKey: .sslKeyPath) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(networkEnabled, forKey: .networkEnabled)
        try c.encode(listenAddress, forKey: .listenAddress)
        try c.encode(port, forKey: .port)
        try c.encode(authenticationEnabled, forKey: .authenticationEnabled)
        try c.encode(sslCertPath, forKey: .sslCertPath)
        try c.encode(sslKeyPath, forKey: .sslKeyPath)
    }

    var effectiveListenAddress: String { networkEnabled ? listenAddress : "127.0.0.1" }
    // Network access reaches beyond this Mac (or at least isn't limited to
    // loopback), with nothing requiring an API key to use it — surfaced to
    // the UI so starting a profile in this configuration can ask "are you
    // sure?" instead of only showing a caption that's easy to miss.
    var exposedWithoutAuthentication: Bool { networkEnabled && !authenticationEnabled }
    var clientHost: String {
        let address = effectiveListenAddress
        return address == "0.0.0.0" || address == "::" ? "127.0.0.1" : address
    }
    // TLS is only wired up for the llama.cpp backend (see
    // ServerProfile.arguments(network:)) — mlx_lm.server and vllm-mlx
    // aren't asked to enable it, so a request to either of those always
    // stays http regardless of these settings.
    var tlsConfigured: Bool { !sslCertPath.isEmpty && !sslKeyPath.isEmpty }
    func baseURL(runtime: InferenceBackend) -> URL? {
        let scheme = (runtime == .llamaCPP && tlsConfigured) ? "https" : "http"
        return URL(string: "\(scheme)://\(clientHost):\(port)")
    }
}

enum EndpointFormatter {
    static func endpoint(address: String, port: Int, scheme: String = "http") -> String {
        "\(scheme)://\(address):\(String(port))"
    }
}

struct BrewDependency: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let executables: [String]

    static let required: [Self] = [
        .init(id: "llama.cpp", title: "llama.cpp", detail: "GGUF inference through llama-server", executables: ["llama-server"]),
        .init(id: "mlx-lm", title: "MLX LM", detail: "Native Apple Silicon MLX inference", executables: ["mlx_lm.server"]),
        .init(id: "uv", title: "uv", detail: "Installer and environment manager required by vLLM-MLX", executables: ["uv"])
    ]

    // Not one of InferenceBar's own runtime dependencies -- an optional
    // companion tool (see GlobalServerSettingsView's dedicated "OpenCode"
    // card, and AppStore.syncCodingProfilesToOpenCode), so it's kept out
    // of `required` and installed/detected on its own.
    static let opencode = Self(id: "opencode", title: "OpenCode", detail: "AI coding agent for the terminal", executables: ["opencode"])
}

/// Merges InferenceBar's coding-tagged profiles into a local OpenCode
/// config (~/.config/opencode/opencode.json) as a custom OpenAI-compatible
/// provider, so they show up as selectable models in OpenCode without
/// hand-editing that file. Pure JSON-merge logic, kept separate from the
/// actual file read/write (AppStore.syncCodingProfilesToOpenCode) so it's
/// unit-testable without touching disk -- and so it never clobbers
/// anything else already in that file (other providers, $schema, model
/// aliases the user added by hand, ...): only the "provider.inferencebar"
/// key is ever replaced.
enum OpenCodeConfigSync {
    static let providerID = "inferencebar"

    struct ProfileEntry: Equatable {
        let alias: String
        let name: String
        let contextSize: Int
        let maximumOutputTokens: Int
    }

    /// Builds the merged config, given whatever top-level JSON object
    /// already existed in opencode.json (an empty dictionary if the file
    /// didn't exist yet or failed to parse) and the profiles to expose.
    /// baseURL should already include the "/v1" suffix OpenCode's
    /// openai-compatible provider expects.
    /// defaultModelAlias, when set, becomes opencode.json's top-level
    /// "model" field (as "inferencebar/<alias>") -- OpenCode's own default
    /// across its interfaces unless someone picks a different one in its
    /// /models picker. When nil, any "model" value this sync previously
    /// wrote is cleared back out (recognized by its "inferencebar/"
    /// prefix); a "model" pointing at some other provider is left alone,
    /// since that's a choice this sync has no business overriding.
    static func mergedConfig(existing: [String: Any], baseURL: String, apiKey: String, profiles: [ProfileEntry], defaultModelAlias: String? = nil) -> [String: Any] {
        var config = existing
        if config["$schema"] == nil { config["$schema"] = "https://opencode.ai/config.json" }
        var providers = config["provider"] as? [String: Any] ?? [:]
        var models: [String: Any] = [:]
        for profile in profiles {
            models[profile.alias] = [
                "name": profile.name,
                "limit": ["context": profile.contextSize, "output": profile.maximumOutputTokens]
            ] as [String: Any]
        }
        providers[providerID] = [
            "npm": "@ai-sdk/openai-compatible",
            "name": "InferenceBar (local)",
            "options": ["baseURL": baseURL, "apiKey": apiKey],
            "models": models
        ] as [String: Any]
        config["provider"] = providers
        if let defaultModelAlias {
            config["model"] = "\(providerID)/\(defaultModelAlias)"
        } else if let existingModel = config["model"] as? String, existingModel.hasPrefix("\(providerID)/") {
            config.removeValue(forKey: "model")
        }
        return config
    }
}

enum HomebrewRuntimeManager {
    static let candidateBrewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    static func brewURL(fileManager: FileManager = .default) -> URL? {
        candidateBrewPaths.first(where: fileManager.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))
    }

    static func isInstalled(_ dependency: BrewDependency, fileManager: FileManager = .default) -> Bool {
        let prefixes = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/homebrew/opt/\(dependency.id)/libexec/bin", "/usr/local/opt/\(dependency.id)/libexec/bin"]
        return dependency.executables.contains { executable in
            prefixes.contains { fileManager.isExecutableFile(atPath: "\($0)/\(executable)") }
        }
    }

    static func install(_ dependency: BrewDependency, using brewURL: URL) async -> (succeeded: Bool, output: String) {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = brewURL
            process.arguments = ["install", dependency.id]
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(decoding: data, as: UTF8.self)
                return (process.terminationStatus == 0, output.isEmpty ? "Homebrew exited with status \(process.terminationStatus)." : output)
            } catch {
                return (false, "Could not launch Homebrew: \(error.localizedDescription)")
            }
        }.value
    }
}

enum RuntimeAvailability {
    static func supports(_ backend: InferenceBackend, installedExecutables: Set<String>) -> Bool {
        switch backend {
        case .llamaCPP: installedExecutables.contains("llama-server")
        case .mlxLM: installedExecutables.contains("mlx_lm.server")
        case .vllmMLX: installedExecutables.contains("vllm-mlx")
        }
    }

    static func installedExecutables(fileManager: FileManager = .default) -> Set<String> {
        let names = ["llama-server", "mlx_lm.server", "vllm-mlx"]
        let home = fileManager.homeDirectoryForCurrentUser.path
        var directories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "\(home)/.local/bin", "\(home)/.venvs/mlx/bin", "\(home)/.venv/bin", "/opt/homebrew/opt/mlx-lm/libexec/bin", "/usr/local/opt/mlx-lm/libexec/bin"]
        if let path = ProcessInfo.processInfo.environment["PATH"] { directories += path.split(separator: ":").map(String.init) }
        return Set(names.filter { name in directories.contains { fileManager.isExecutableFile(atPath: "\($0)/\(name)") } })
    }
}

enum DownloadCompletionReconciler {
    static func shouldFinalize(progress: Double, snapshotComplete: Bool, hasIncompleteFiles: Bool, stableChecks: Int) -> Bool {
        progress >= 1 && snapshotComplete && !hasIncompleteFiles && stableChecks >= 6
    }
}

enum ServerLifecycle: Equatable {
    case stopped
    case stopping
    case starting
    case downloading
    case running
    case failed(String)

    var label: String {
        switch self {
        case .stopped: "Stopped"
        case .stopping: "Stopping…"
        case .starting: "Starting…"
        case .downloading: "Downloading model…"
        case .running: "Running"
        case .failed(let reason): "Failed: \(reason)"
        }
    }
}

enum MenuBarLifecyclePresentation {
    static func locksProfileSelection(_ lifecycle: ServerLifecycle) -> Bool {
        switch lifecycle {
        case .starting, .downloading, .running, .stopping: true
        case .stopped, .failed: false
        }
    }

    static func profileTitle(name: String, lifecycle: ServerLifecycle, activity: EngineActivity, isSending: Bool) -> String {
        if lifecycle == .stopping { return "Stopping… · \(name)" }
        if lifecycle == .starting { return "Starting… · \(name)" }
        if lifecycle == .downloading { return "Downloading… · \(name)" }
        if isSending { return "\(activity.label.isEmpty ? "Working" : activity.label) · \(name)" }
        return name
    }

    /// A dropdown line for requests hitting the running server that
    /// aren't InferenceBar's own chat -- the CLI tool, opencode, anything
    /// else on the OpenAI-compatible endpoint. nil when there's nothing
    /// to show: not running, InferenceBar's own chat is the one sending
    /// (that already has its own status line above), or the count is
    /// zero. activeRequests is RuntimeTelemetryParser's count, which
    /// already reflects every client hitting the server, not just this
    /// app's own requests.
    static func externalRequestLabel(lifecycle: ServerLifecycle, isSending: Bool, activeRequests: Int) -> String? {
        guard lifecycle == .running, !isSending, activeRequests > 0 else { return nil }
        return activeRequests == 1 ? "1 external request active" : "\(activeRequests) external requests active"
    }
}

/// The Profiles list's per-row status dot and (indirectly, via
/// ContentView's color mapping) the profile editor's disabled "Start
/// server" state. Kept as plain data here -- no SwiftUI Color -- so the
/// decision logic is testable the same way as CLIInstallPolicy/
/// ChatColumnLayout above; ContentView.swift owns the actual colors.
enum ProfileStatus: Equatable {
    case failed
    case running
    case starting
    case downloading
    case modelMissing
    case ready

    static func status(
        isFailed: Bool,
        isRunningProfile: Bool,
        serverLifecycleIsRunning: Bool,
        isDownloadingThisProfile: Bool,
        modelAvailable: Bool
    ) -> ProfileStatus {
        if isFailed { return .failed }
        if isRunningProfile { return serverLifecycleIsRunning ? .running : .starting }
        if isDownloadingThisProfile { return .downloading }
        if !modelAvailable { return .modelMissing }
        return .ready
    }
}

/// The menu-bar dropdown's one-line summary for an in-progress model
/// download -- kept pure (no AppStore, no NSMenuItem) so it's testable
/// the same way as MenuBarLifecyclePresentation above. Read fresh every
/// time the dropdown opens (menuNeedsUpdate in InferenceBarApp.swift),
/// so unlike the per-profile progress view in ProfileEditor, it doesn't
/// disappear when you navigate away from the profile that started the
/// download -- and it needs no polling of its own, since it only ever
/// reflects AppStore's existing download-progress properties at the
/// instant the menu opens.
enum DownloadMenuBarPresentation {
    static func summary(modelName: String, isResolving: Bool, status: String, progress: Double, totalBytes: Int64, bytesPerSecond: Double) -> String {
        let shortName = modelName.split(separator: "/").last.map(String.init) ?? modelName
        if isResolving {
            return shortName.isEmpty ? "Resolving download…" : "Resolving \(shortName)…"
        }
        guard totalBytes > 0 else {
            return shortName.isEmpty ? status : "\(shortName): \(status)"
        }
        let percent = progress.formatted(.percent.precision(.fractionLength(1)))
        let speed = ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file)
        return shortName.isEmpty ? "\(percent) · \(speed)/s" : "\(shortName): \(percent) · \(speed)/s"
    }
}

enum DefaultProfileStartupPolicy {
    static func shouldStart(enabled: Bool, defaultProfileExists: Bool, lifecycle: ServerLifecycle) -> Bool {
        enabled && defaultProfileExists && !MenuBarLifecyclePresentation.locksProfileSelection(lifecycle)
    }
}

/// Where Settings' "Install command-line tool" button should place the
/// bundled `inference` CLI binary (see Sources/InferenceBarCLI) —
/// decided from what's actually on this Mac, not assumed.
enum CLIInstallPolicy {
    /// macOS's own default PATH (see /etc/paths) always includes this
    /// directory for every standard login shell, with no profile edits
    /// needed — tried first (with a one-time admin-privileges prompt
    /// if it isn't already writable) so "Install" doesn't routinely
    /// leave someone needing to edit PATH by hand afterward.
    static let systemDirectory = "/usr/local/bin"

    /// Homebrew's own bin directory — tried next since InferenceBar
    /// already requires Homebrew for its GGUF/MLX runtimes, so most
    /// users already have it writable without elevation. It only ends
    /// up on PATH, though, once Homebrew's own `shellenv` line has
    /// actually run in that shell's profile — and never for a GUI app's
    /// own process environment, which is why `isOnPATH` below needs the
    /// user's real login-shell PATH, not this process's own.
    static let homebrewDirectory = "/opt/homebrew/bin"

    /// Falls back to a per-user directory that never needs elevated
    /// privileges to create or write to, when neither of the above can
    /// be used even with an elevation prompt (declined, sandboxed, etc).
    static func destinationDirectory(homebrewBinIsWritableDirectory: Bool, homeDirectory: String) -> String {
        homebrewBinIsWritableDirectory ? homebrewDirectory : "\(homeDirectory)/.local/bin"
    }

    /// Whether the chosen destination is already somewhere a shell will
    /// find it without the user editing PATH — checked against $PATH
    /// itself (colon-separated), not assumed from which directory was
    /// picked, since a customized shell profile might already add
    /// ~/.local/bin, or might have removed /opt/homebrew/bin.
    ///
    /// Callers must pass the user's real *login shell* PATH here, not
    /// `ProcessInfo.processInfo.environment["PATH"]` — launchd hands a
    /// GUI app a bare-bones default PATH that omits Homebrew's bin and
    /// often even /usr/local/bin, regardless of what the same user's
    /// actual Terminal sees, which used to make this check report a
    /// false "not on PATH" for nearly every install.
    static func isOnPATH(_ directory: String, pathEnvironmentVariable: String) -> Bool {
        pathEnvironmentVariable.split(separator: ":").map(String.init).contains(directory)
    }
}

struct AppVersion: Comparable, Equatable {
    let components: [Int]

    init?(_ value: String) {
        let normalized = value.lowercased().replacingOccurrences(of: "release-", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "v"))
        let values = normalized.split(separator: ".").compactMap { part -> Int? in
            let digits = part.prefix(while: \.isNumber)
            return digits.isEmpty ? nil : Int(digits)
        }
        guard !values.isEmpty else { return nil }
        components = values
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

struct GitHubTag: Decodable {
    let name: String
}

enum AppUpdatePolicy {
    static let checkInterval: TimeInterval = 60 * 60

    static func newestUpdate(tags: [String], currentVersion: String) -> String? {
        guard let current = AppVersion(currentVersion) else { return nil }
        return tags.compactMap { tag in AppVersion(tag).map { ($0, tag) } }
            .filter { $0.0 > current }
            .max { $0.0 < $1.0 }?.1
    }
}

enum EngineActivity: String, CaseIterable, Equatable {
    case idle = ""
    case thinking = "Thinking"
    case reasoning = "Reasoning"
    case searching = "Searching"
    case browsing = "Browsing"
    case executingCode = "Executing Code"
    case toolCalling = "Tool Calling"
    case functionCalling = "Function Calling"
    case compacting = "Compacting"
    case summarizing = "Summarizing"
    case generating = "Generating"
    case streaming = "Streaming"

    var label: String { rawValue }
}

enum ChatTailPolicy {
    static func shouldFollow(currentlyFollowing: Bool, bottomIsVisible: Bool, userScrolledUp: Bool) -> Bool {
        if userScrolledUp { return false }
        if bottomIsVisible { return true }
        return currentlyFollowing
    }
}

/// Pure logic behind "regenerate" and "edit & resend": both decide which
/// suffix of the transcript to discard so AppStore can resend from
/// what's left — AppStore itself only mutates `messages` and touches the
/// network.
enum ChatRegenerationPolicy {
    /// The range regenerateLastResponse() should remove: the answer
    /// after the most recent user message (and any tool-call notes that
    /// went with it), leaving that user message as the new end of the
    /// conversation. Nil when there's nothing to regenerate — no user
    /// message yet, or it's already the last thing in the transcript.
    static func trailingAssistantTurnRange(in messages: [ChatMessage]) -> Range<Int>? {
        guard let lastUserIndex = messages.lastIndex(where: { $0.role == "user" }), lastUserIndex < messages.count - 1 else { return nil }
        return (lastUserIndex + 1)..<messages.count
    }

    /// The index editAndResend(messageID:) should truncate the
    /// transcript to (removing that message and everything after it, so
    /// the edited text can take its place as a new final turn) — nil if
    /// that id doesn't name a user message currently in the transcript.
    static func editTruncationIndex(for messageID: UUID, in messages: [ChatMessage]) -> Int? {
        messages.firstIndex(where: { $0.id == messageID && $0.role == "user" })
    }
}

struct ProcessLogLineBuffer {
    private var pending = Data()

    mutating func append(_ byte: UInt8) -> String? {
        pending.append(byte)
        guard byte == 0x0A || byte == 0x0D else { return nil }
        let line = String(decoding: pending, as: UTF8.self)
        pending.removeAll(keepingCapacity: true)
        return line
    }

    mutating func flush() -> String? {
        guard !pending.isEmpty else { return nil }
        let line = String(decoding: pending, as: UTF8.self)
        pending.removeAll()
        return line
    }
}

enum AppSection: Hashable {
    case profiles, models, logs, prompt, settings
}

/// Use-case tags for grouping ProfilePreset.all in the "Add preset" menu.
/// Mirrors ModelCategory's five curated categories below (same
/// titles/icons) so the vocabulary is consistent between "browse Hugging
/// Face" and "add a hardware preset". A preset can carry more than one
/// tag -- the real models these presets wrap already show up in more than
/// one of ModelCategory's recommendedModelIDs lists, so forcing a single
/// tag per preset would misrepresent that overlap.
enum PresetUseCase: String, CaseIterable, Hashable {
    case coding
    case chat
    case visionChat
    case homeAutomation
    case systems

    var title: String {
        switch self {
        case .coding: return "Coding"
        case .chat: return "Chat"
        case .visionChat: return "Chat with Images"
        case .homeAutomation: return "Home Automation"
        case .systems: return "Systems Management"
        }
    }

    var icon: String {
        switch self {
        case .coding: return "chevron.left.forwardslash.chevron.right"
        case .chat: return "bubble.left.and.bubble.right.fill"
        case .visionChat: return "photo.on.rectangle.angled"
        case .homeAutomation: return "house.and.flag.fill"
        case .systems: return "server.rack"
        }
    }
}

struct ProfilePreset: Identifiable {
    let id: String
    let title: String
    let hardware: String
    let summary: String
    let profile: ServerProfile
    /// The Hugging Face repo a GGUF preset's model (and mmproj, if any)
    /// can be downloaded from -- set only where the repo's real
    /// filename has been confirmed to match this preset's expected
    /// local filename (case-insensitively; see expectedGGUFFilename),
    /// so "Add all presets" can request that exact file successfully.
    /// nil means this GGUF preset's source repo isn't confirmed yet:
    /// it can still be added by hand, it just won't auto-download.
    /// Always nil for MLX/vLLM-MLX presets, which resolve their own
    /// source directly from `profile.modelPath` instead (see
    /// `downloadSourceModelID`).
    var ggufSourceModelID: String? = nil
    /// Which PresetUseCase(s) this preset's model is well-suited for, so
    /// the "Add preset" menu can group by task instead of one long list.
    /// Assigned primarily from ModelCategory's five curated
    /// recommendedModelIDs lists where this preset's
    /// downloadSourceModelID matches an entry there, and by informed
    /// judgment (title, summary, known model-family strengths) where it
    /// doesn't appear in any of them. Defaults to empty rather than
    /// requiring every preset to opt in, but every preset below sets it
    /// explicitly.
    var useCases: Set<PresetUseCase> = []
    /// The mmproj projector GGUF filename this preset's auto-download
    /// should also fetch from the same `ggufSourceModelID` repo, once
    /// the main model file is confirmed present -- llama.cpp needs this
    /// file sitting alongside the model (see MultimodalProjector) to
    /// actually accept image input; without it a `.visionChat` preset's
    /// model downloads and runs fine but every image attachment gets
    /// refused. nil for every non-vision preset, and for a vision preset
    /// whose exact projector filename isn't confirmed yet (still taggable
    /// `.visionChat` and addable by hand, it just won't auto-fetch the
    /// projector).
    var mmprojFilename: String? = nil

    /// Whether this preset needs no further action to support image
    /// input: trivially true for a non-vision preset (nothing to check),
    /// or a `.visionChat` preset that already has *some* mmproj
    /// projector GGUF sitting in `modelRoot` -- every model in this
    /// app's shared, flat model folder is checked against the same
    /// directory listing (see MultimodalProjector.path(forModelPath:)),
    /// so any projector already there satisfies this preset's own
    /// --mmproj wiring too, not only the exact file downloaded
    /// alongside it. Used to avoid re-fetching a projector that's
    /// already on disk under a different quant or name.
    func hasProjectorAvailable(modelRoot: URL) -> Bool {
        guard mmprojFilename != nil else { return true }
        guard let siblings = try? FileManager.default.contentsOfDirectory(atPath: modelRoot.path) else { return false }
        return MultimodalProjector.hasProjectorSibling(among: siblings)
    }

    static var mlxDefaults: [ProfilePreset] {
        all.filter { $0.profile.runtime == .mlxLM }
    }

    /// Where this preset's model can be auto-downloaded from, unifying
    /// the GGUF (`ggufSourceModelID`) and MLX/vLLM-MLX case (whose
    /// `profile.modelPath` already *is* a Hugging Face repo ID).
    var downloadSourceModelID: String? {
        profile.runtime.usesGGUF ? ggufSourceModelID : profile.modelPath
    }

    /// The exact filename this GGUF preset expects locally -- also the
    /// filename requested from `ggufSourceModelID`'s repo when
    /// auto-downloading. Its real casing on Hugging Face may differ
    /// (isAvailable's directory scan matches case-insensitively either
    /// way).
    var expectedGGUFFilename: String? {
        guard profile.runtime.usesGGUF else { return nil }
        return URL(fileURLWithPath: NSString(string: profile.modelPath).expandingTildeInPath).lastPathComponent
    }

    func isAvailable(modelRoot: URL) -> Bool {
        let configured = NSString(string: profile.modelPath).expandingTildeInPath
        if profile.runtime.usesGGUF {
            if FileManager.default.fileExists(atPath: configured) { return true }
            let expected = URL(fileURLWithPath: configured).lastPathComponent.lowercased()
            guard !expected.isEmpty, let enumerator = FileManager.default.enumerator(atPath: modelRoot.path) else { return false }
            for case let relative as String in enumerator where URL(fileURLWithPath: relative).lastPathComponent.lowercased() == expected { return true }
            return false
        }
        if FileManager.default.fileExists(atPath: configured) {
            return MLXSnapshotResolver.resolve(modelID: profile.modelPath, root: modelRoot) != nil
                || FileManager.default.fileExists(atPath: (configured as NSString).appendingPathComponent("config.json"))
        }
        return MLXSnapshotResolver.resolve(modelID: profile.modelPath, root: modelRoot) != nil
    }

    /// The lowest unified-memory figure mentioned in `hardware` -- e.g.
    /// "M2/M3/M4 Pro or Max · 36–48 GB" -> 36, "Mac Studio Ultra / Mac
    /// Pro · 192 GB+" -> 192. A range or a "+" always means this preset
    /// was sized for at least that much, so the low end is the floor to
    /// compare against, not an average. nil when the string doesn't
    /// mention a GB figure at all (true of no current preset, but a
    /// preset that fails to parse is never filtered out sight unseen --
    /// see isSupported below).
    var minimumUnifiedMemoryGB: Int? {
        guard let expression = try? NSRegularExpression(pattern: #"(\d+)(?:[-–]\d+)?\s*GB"#),
              let match = expression.firstMatch(in: hardware, range: NSRange(hardware.startIndex..., in: hardware)),
              let range = Range(match.range(at: 1), in: hardware) else { return nil }
        return Int(hardware[range])
    }

    /// Whether this preset's stated hardware tier fits a Mac with
    /// `physicalMemoryGB` of unified memory -- used to keep "Add all
    /// presets" and the "Not yet downloaded" menu from recommending (or
    /// silently downloading) a model sized for a bigger Mac than this
    /// one. Always true when minimumUnifiedMemoryGB can't be parsed, so
    /// a description this doesn't understand is shown rather than
    /// hidden.
    func isSupported(physicalMemoryGB: Int) -> Bool {
        guard let minimumUnifiedMemoryGB else { return true }
        return physicalMemoryGB >= minimumUnifiedMemoryGB
    }

    static let all: [ProfilePreset] = [
        ProfilePreset(
            id: "gguf-qwen25-coder-7b-8",
            title: "Qwen 2.5 Coder 7B · Q4_K_M",
            hardware: "Mac mini / MacBook Air · 8 GB",
            summary: "Entry-level coding preset with a conservative 4K context and limited agent headroom",
            profile: ServerProfile(name: "Qwen 2.5 Coder 7B · 8 GB Mac", modelPath: "~/ai-models/qwen2.5-coder-7b-instruct-q4_k_m.gguf", alias: "qwen2.5-coder-7b", contextSize: 4096, parallel: 1, flashAttention: true, jinja: true, cacheRAM: 256, reasoning: "", reasoningBudget: 0, reasoningFormat: "", reasoningPreserve: false),
            ggufSourceModelID: "bartowski/Qwen2.5-Coder-7B-Instruct-GGUF",
            useCases: [.coding]
        ),
        ProfilePreset(
            id: "mlx-qwen3-4b-home-8",
            title: "Qwen 3 4B · Home Automation",
            hardware: "Mac mini / MacBook Air · 8 GB",
            summary: "Lightweight direct tool calling; use ha-mcp deferred discovery with an 8K context",
            profile: ServerProfile(backend: .mlxLM, name: "Home Assistant · Qwen 3 4B · 8 GB", executable: "mlx_lm.server", modelPath: "mlx-community/Qwen3-4B-4bit", alias: "qwen3-4b-ha", contextSize: 8192, parallel: 1, flashAttention: false, jinja: false, cacheRAM: 10, reasoning: "", reasoningBudget: 0, reasoningFormat: "", reasoningPreserve: false),
            useCases: [.homeAutomation]
        ),
        ProfilePreset(
            id: "mlx-qwen35-9b-home-16",
            title: "Qwen 3.5 9B · Home Automation",
            hardware: "Mac mini M4 / iMac M4 / MacBook Air · 16 GB+",
            summary: "Low-latency tool calling with a 16K context; use ha-mcp deferred tool search",
            profile: ServerProfile(backend: .mlxLM, name: "Home Assistant · Qwen 3.5 9B", executable: "mlx_lm.server", modelPath: "mlx-community/Qwen3.5-9B-MLX-4bit", alias: "qwen3.5-9b-ha", contextSize: 16384, parallel: 1, flashAttention: false, jinja: false, cacheRAM: 10, reasoning: "", reasoningBudget: 0, reasoningFormat: "", reasoningPreserve: false),
            useCases: [.homeAutomation]
        ),
        ProfilePreset(
            id: "mlx-qwen3-vl-8b-home-16",
            title: "Qwen3 VL 8B · Home Automation + Vision",
            hardware: "Mac mini M4 / iMac M4 · 16 GB+",
            summary: "Tool calling plus camera-image understanding with a 16K context",
            profile: ServerProfile(backend: .mlxLM, name: "Home Assistant · Qwen3 VL 8B", executable: "mlx_lm.server", modelPath: "mlx-community/Qwen3-VL-8B-Instruct-4bit", alias: "qwen3-vl-8b-ha", contextSize: 16384, parallel: 1, flashAttention: false, jinja: false, cacheRAM: 10, reasoning: "", reasoningBudget: 0, reasoningFormat: "", reasoningPreserve: false),
            useCases: [.homeAutomation, .visionChat]
        ),
        ProfilePreset(
            id: "mlx-devstral-small2-24b-24",
            title: "Devstral Small 2 24B · MLX 4-bit",
            hardware: "iMac M4 / Mac mini M4 Pro / MacBook Pro · 24 GB",
            summary: "Dense coding and agent model; about 14 GB with a conservative 16K context",
            profile: ServerProfile(backend: .mlxLM, name: "MLX · Devstral Small 2 · iMac/mini 24 GB", executable: "mlx_lm.server", modelPath: "mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit", alias: "devstral-small-2", contextSize: 16384, parallel: 1, flashAttention: false, jinja: false, cacheRAM: 10, reasoning: "", reasoningBudget: 0, reasoningFormat: "", reasoningPreserve: false),
            useCases: [.coding, .systems]
        ),
        ProfilePreset(
            id: "mlx-qwen36-27b-24",
            title: "Qwen 3.6 27B · MLX 4-bit",
            hardware: "iMac M4 / Mac mini M4 Pro / MacBook Pro · 24 GB",
            summary: "Dense general and coding model; about 16 GB with a conservative 16K context",
            profile: ServerProfile(backend: .mlxLM, name: "MLX · Qwen 3.6 27B · iMac/mini 24 GB", executable: "mlx_lm.server", modelPath: "mlx-community/Qwen3.6-27B-4bit", alias: "qwen3.6-27b", contextSize: 16384, parallel: 1, flashAttention: false, jinja: false, cacheRAM: 10, reasoning: "", reasoningBudget: 0, reasoningFormat: "", reasoningPreserve: false),
            useCases: [.coding, .chat, .systems]
        ),
        ProfilePreset(
            id: "gguf-qwen36-27b-q4-32",
            title: "Qwen 3.6 27B · Q4_K_M",
            hardware: "MacBook Pro Max / Mac Studio · 32 GB+",
            summary: "Dense 27B GGUF preset; approximately 19 GB with a 16K context",
            profile: ServerProfile(name: "Qwen 3.6 27B · 32 GB Mac", modelPath: "~/ai-models/Qwen3.6-27B-Q4_K_M.gguf", alias: "qwen3.6-27b", contextSize: 16384, parallel: 1, flashAttention: true, jinja: true, cacheRAM: 2048, reasoning: "auto", reasoningBudget: 512, reasoningFormat: "deepseek", reasoningPreserve: true),
            ggufSourceModelID: "ggml-org/Qwen3.6-27B-GGUF",
            useCases: [.coding, .chat]
        ),
        ProfilePreset(
            id: "gguf-glm47-flash-q4-32",
            title: "GLM-4.7 Flash · Q4_K_M",
            hardware: "MacBook Pro Max / Mac Studio · 32 GB+",
            summary: "Fast 31B MoE model; approximately 18 GB with a 16K context",
            profile: ServerProfile(name: "GLM-4.7 Flash · 32 GB Mac", modelPath: "~/ai-models/GLM-4.7-Flash-Q4_K_M.gguf", alias: "glm-4.7-flash", contextSize: 16384, parallel: 1, flashAttention: true, jinja: true, cacheRAM: 2048, reasoning: "auto", reasoningBudget: 512, reasoningFormat: "deepseek", reasoningPreserve: true),
            ggufSourceModelID: "DhruvalLabs/GLM-4.7-Flash-GGUF",
            useCases: [.coding, .chat, .systems]
        ),
        ProfilePreset(
            id: "mlx-gpt-oss-20b-q4-16",
            title: "GPT-OSS 20B · MXFP4 Q4",
            hardware: "Mac mini M4 / iMac M4 / MacBook Air · 16 GB+",
            summary: "Memory-conscious tool-calling preset with a conservative 16K context",
            profile: ServerProfile(backend: .mlxLM, name: "MLX · GPT-OSS 20B · 16 GB", executable: "mlx_lm.server", modelPath: "mlx-community/gpt-oss-20b-MXFP4-Q4", alias: "gpt-oss-20b", contextSize: 16384, parallel: 1, flashAttention: false, jinja: false, cacheRAM: 10, reasoning: "", reasoningBudget: 0, reasoningFormat: "", reasoningPreserve: false),
            useCases: [.coding, .chat, .systems, .homeAutomation]
        ),
        ProfilePreset(
            id: "mlx-gpt-oss-20b-q8-24",
            title: "GPT-OSS 20B · MXFP4 Q8",
            hardware: "iMac M4 / Mac mini M4 Pro / MacBook Pro · 24 GB",
            summary: "Tool-calling focused MLX preset; roughly 12–16 GB before context cache",
            profile: ServerProfile(backend: .mlxLM, name: "MLX · GPT-OSS 20B · iMac/mini 24 GB", executable: "mlx_lm.server", modelPath: "mlx-community/gpt-oss-20b-MXFP4-Q8", alias: "gpt-oss-20b", contextSize: 16384, parallel: 1, flashAttention: false, jinja: false, cacheRAM: 10, reasoning: "", reasoningBudget: 0, reasoningFormat: "", reasoningPreserve: false),
            useCases: [.coding, .chat, .systems, .homeAutomation]
        ),
        ProfilePreset(
            id: "mlx-qwen36-m3max-48",
            title: "Qwen 3.6 35B A3B · MLX 4-bit",
            hardware: "MacBook Pro M3 Max · 48 GB",
            summary: "Native Apple MLX runtime; avoids the current GGUF MTP loader issue",
            profile: ServerProfile(backend: .mlxLM, name: "MLX · Qwen 3.6 35B · M3 Max 48 GB", executable: "mlx_lm.server", modelPath: "mlx-community/Qwen3.6-35B-A3B-4bit", alias: "default_model", contextSize: 65536, parallel: 1, flashAttention: false, jinja: false, cacheRAM: 10, reasoning: "", reasoningBudget: 0, reasoningFormat: "", reasoningPreserve: false),
            useCases: [.coding, .chat, .homeAutomation]
        ),
        ProfilePreset(
            id: "vllm-mlx-qwen36-m3max-48",
            title: "Qwen 3.6 35B A3B · vLLM-MLX",
            hardware: "MacBook Pro M3 Max · 48 GB",
            summary: "MLX with continuous batching and an OpenAI-compatible server",
            profile: ServerProfile(backend: .vllmMLX, name: "vLLM-MLX · Qwen 3.6 35B · 48 GB", executable: "vllm-mlx", modelPath: "mlx-community/Qwen3.6-35B-A3B-4bit", alias: "default", contextSize: 65536, parallel: 1, flashAttention: false, jinja: false, cacheRAM: 0, reasoning: "", reasoningBudget: 0, reasoningFormat: "", reasoningPreserve: false),
            useCases: [.coding, .chat, .homeAutomation, .systems]
        ),
        ProfilePreset(
            id: "mlx-deepseek-r1-7b-16",
            title: "DeepSeek R1 Distill Qwen 7B · MLX 4-bit",
            hardware: "Mac mini M4 / iMac M4 / MacBook Air · 16 GB",
            summary: "Compact reasoning model; approximately 4.3 GB of MLX weights",
            profile: ServerProfile(backend: .mlxLM, name: "MLX · DeepSeek R1 7B · 16 GB", executable: "mlx_lm.server", modelPath: "mlx-community/DeepSeek-R1-Distill-Qwen-7B-4bit", alias: "default_model", contextSize: 32768, parallel: 1, flashAttention: false, jinja: false, cacheRAM: 10, reasoning: "", reasoningBudget: 0, reasoningFormat: "", reasoningPreserve: false),
            useCases: [.chat, .coding]
        ),
        ProfilePreset(
            id: "mlx-gemma3-12b-24",
            title: "Gemma 3 12B Instruct · MLX 4-bit",
            hardware: "iMac M4 / Mac mini M4 Pro / MacBook Pro · 24 GB",
            summary: "Balanced everyday assistant with multimodal-capable model weights",
            profile: ServerProfile(backend: .mlxLM, name: "MLX · Gemma 3 12B · 24 GB", executable: "mlx_lm.server", modelPath: "mlx-community/gemma-3-12b-it-4bit", alias: "default_model", contextSize: 32768, parallel: 1, flashAttention: false, jinja: false, cacheRAM: 10, reasoning: "", reasoningBudget: 0, reasoningFormat: "", reasoningPreserve: false),
            useCases: [.chat]
        ),
        ProfilePreset(
            id: "mlx-qwen3-coder-30b-32",
            title: "Qwen3 Coder 30B A3B · MLX 4-bit",
            hardware: "Mac mini M4 Pro / Mac Studio / MacBook Pro · 32 GB+",
            summary: "Coding-focused MoE model; approximately 17.2 GB of MLX weights",
            profile: ServerProfile(backend: .mlxLM, name: "MLX · Qwen3 Coder 30B · 32 GB", executable: "mlx_lm.server", modelPath: "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit", alias: "default_model", contextSize: 65536, parallel: 1, flashAttention: false, jinja: false, cacheRAM: 10, reasoning: "", reasoningBudget: 0, reasoningFormat: "", reasoningPreserve: false),
            useCases: [.coding, .systems, .homeAutomation]
        ),
        ProfilePreset(
            id: "mlx-qwen3-coder-30b-8bit-48",
            title: "Qwen3 Coder 30B A3B · MLX 8-bit",
            hardware: "MacBook Pro Max / Mac Studio · 48 GB+",
            summary: "Higher-fidelity coding preset with a conservative 32K context",
            profile: ServerProfile(backend: .mlxLM, name: "MLX · Qwen3 Coder 30B 8-bit · 48 GB", executable: "mlx_lm.server", modelPath: "mlx-community/Qwen3-Coder-30B-A3B-Instruct-8bit", alias: "qwen3-coder-30b", contextSize: 32768, parallel: 1, flashAttention: false, jinja: false, cacheRAM: 10, reasoning: "", reasoningBudget: 0, reasoningFormat: "", reasoningPreserve: false),
            useCases: [.coding]
        ),
        ProfilePreset(
            id: "mlx-qwen36-6bit-48",
            title: "Qwen 3.6 35B A3B · MLX 6-bit",
            hardware: "MacBook Pro Max / Mac Studio · 48 GB+",
            summary: "Quality-focused middle quantization with a 32K context",
            profile: ServerProfile(backend: .mlxLM, name: "MLX · Qwen 3.6 35B 6-bit · 48 GB", executable: "mlx_lm.server", modelPath: "mlx-community/Qwen3.6-35B-A3B-6bit", alias: "qwen3.6-35b", contextSize: 32768, parallel: 1, flashAttention: false, jinja: false, cacheRAM: 10, reasoning: "", reasoningBudget: 0, reasoningFormat: "", reasoningPreserve: false),
            useCases: [.coding, .chat]
        ),
        ProfilePreset(
            id: "mlx-qwen36-8bit-64",
            title: "Qwen 3.6 35B A3B · MLX 8-bit",
            hardware: "Mac Studio Max / Ultra · 64 GB+",
            summary: "High-quality MLX quantization with room for a 64K context",
            profile: ServerProfile(backend: .mlxLM, name: "MLX · Qwen 3.6 35B 8-bit · 64 GB", executable: "mlx_lm.server", modelPath: "mlx-community/Qwen3.6-35B-A3B-8bit", alias: "qwen3.6-35b", contextSize: 65536, parallel: 1, flashAttention: false, jinja: false, cacheRAM: 10, reasoning: "", reasoningBudget: 0, reasoningFormat: "", reasoningPreserve: false),
            useCases: [.coding, .chat]
        ),
        ProfilePreset(
            id: "phi4-16-developer",
            title: "Phi-4 14B · Q4_K_M",
            hardware: "MacBook Air / Pro / mini · 16 GB",
            summary: "Strong reasoning per parameter; 16K native context",
            profile: ServerProfile(name: "Recommended · Phi-4 14B · 16 GB", modelPath: "~/ai-models/Phi-4-Q4_K_M.gguf", alias: "phi-4", contextSize: 16384, parallel: 1, flashAttention: true, jinja: true, cacheRAM: 1024, reasoning: "", reasoningBudget: 0, reasoningFormat: "", reasoningPreserve: false),
            ggufSourceModelID: "bartowski/phi-4-GGUF",
            useCases: [.coding, .chat]
        ),
        ProfilePreset(
            id: "deepseek-r1-7b-16",
            title: "DeepSeek R1 Distill Qwen 7B · Q5_K_M",
            hardware: "Apple Silicon · 16 GB",
            summary: "MIT-licensed reasoning preset with a 32K context",
            profile: ServerProfile(name: "Recommended · DeepSeek R1 7B · 16 GB", modelPath: "~/ai-models/DeepSeek-R1-Distill-Qwen-7B-Q5_K_M.gguf", alias: "deepseek-r1-7b", contextSize: 32768, parallel: 1, flashAttention: true, jinja: true, cacheRAM: 1024, reasoning: "auto", reasoningBudget: 1024, reasoningFormat: "deepseek", reasoningPreserve: true),
            ggufSourceModelID: "bartowski/DeepSeek-R1-Distill-Qwen-7B-GGUF",
            useCases: [.chat, .coding]
        ),
        ProfilePreset(
            id: "gemma4-8b-opencode",
            title: "Gemma 4 8B · Q5_K_M · OpenCode",
            hardware: "Apple Silicon · 16–24 GB",
            summary: "Coding-agent preset with the recommended 32K context",
            profile: ServerProfile(name: "Recommended · Gemma 4 8B · OpenCode", modelPath: "~/ai-models/google_gemma-4-E4B-it-Q5_K_M.gguf", alias: "gemma-4-8b", contextSize: 32768, parallel: 1, flashAttention: true, jinja: true, cacheRAM: 2048, reasoning: "", reasoningBudget: 0, reasoningFormat: "", reasoningPreserve: false),
            // Google's own size name is "E4B" (4.5B effective / 8B with
            // embeddings) -- this preset's "8B" title is that same model.
            ggufSourceModelID: "bartowski/google_gemma-4-E4B-it-GGUF",
            useCases: [.coding]
        ),
        ProfilePreset(
            id: "gemma4-26b-opencode",
            title: "Gemma 4 26B MoE · Q4_K_M · OpenCode",
            hardware: "Apple Silicon · 32 GB+",
            summary: "MoE coding-agent sweet spot with a 32K context",
            profile: ServerProfile(name: "Recommended · Gemma 4 26B · OpenCode", modelPath: "~/ai-models/gemma-4-26B-A4B-it-UD-Q4_K_M.gguf", alias: "gemma-4-26b", contextSize: 32768, parallel: 1, flashAttention: true, jinja: true, cacheRAM: 4096, reasoning: "", reasoningBudget: 0, reasoningFormat: "", reasoningPreserve: false),
            // 25.2B total / 3.8B active MoE -- no plain (non-"UD") Q4_K_M
            // exists for this one; Unsloth's "UD" dynamic-quant Q4_K_M is
            // the standard offering at this quant level.
            ggufSourceModelID: "unsloth/gemma-4-26B-A4B-it-GGUF",
            useCases: [.coding]
        ),
        ProfilePreset(
            id: "mistral-small31-32",
            title: "Mistral Small 3.1 24B · Q4_K_M",
            hardware: "M2/M3/M4 Max or Pro · 32 GB+",
            summary: "Apache-licensed function calling and coding preset",
            profile: ServerProfile(name: "Recommended · Mistral Small 3.1 · 32 GB", modelPath: "~/ai-models/mistralai_Mistral-Small-3.1-24B-Instruct-2503-Q4_K_M.gguf", alias: "mistral-small-3.1", contextSize: 32768, parallel: 1, flashAttention: true, jinja: true, cacheRAM: 4096, reasoning: "", reasoningBudget: 0, reasoningFormat: "", reasoningPreserve: false),
            // Confirmed vision-capable: bartowski's repo also ships
            // mmproj-mistralai_Mistral-Small-3.1-24B-Instruct-2503-*.gguf
            // projector files, and llama.cpp auto-wires --mmproj from a
            // sibling in the model folder (see MultimodalProjector) --
            // same mechanism the Qwen3-VL presets above rely on. The f16
            // projector is picked over bf16 -- either would work, f16 is
            // just the more universally-supported of the two.
            ggufSourceModelID: "bartowski/mistralai_Mistral-Small-3.1-24B-Instruct-2503-GGUF",
            useCases: [.coding, .chat, .visionChat],
            mmprojFilename: "mmproj-mistralai_Mistral-Small-3.1-24B-Instruct-2503-f16.gguf"
        ),
        ProfilePreset(
            id: "llama3-16-air-imac-mini",
            title: "Llama 3.2 3B Instruct · Q6_K",
            hardware: "MacBook Air / iMac / Mac mini · 16 GB",
            summary: "Responsive general assistant with a generous 32K context",
            profile: ServerProfile(name: "Llama 3.2 3B · 16 GB Mac", modelPath: "~/ai-models/Llama-3.2-3B-Instruct-Q6_K.gguf", alias: "llama-3.2-3b", contextSize: 32768, parallel: 1, flashAttention: true, jinja: true, cacheRAM: 1024, reasoning: "", reasoningBudget: 0, reasoningFormat: "", reasoningPreserve: false),
            ggufSourceModelID: "bartowski/Llama-3.2-3B-Instruct-GGUF",
            useCases: [.chat]
        ),
        ProfilePreset(
            id: "qwen14-24-imac-mini-pro",
            title: "Qwen3 14B · Q4_K_M",
            hardware: "iMac / Mac mini / MacBook Pro · 24 GB",
            summary: "Mid-size reasoning model with a conservative 16K context",
            profile: ServerProfile(name: "Qwen3 14B · 24 GB Mac", modelPath: "~/ai-models/Qwen_Qwen3-14B-Q4_K_M.gguf", alias: "qwen3-14b", contextSize: 16384, parallel: 1, flashAttention: true, jinja: true, cacheRAM: 2048, reasoning: "auto", reasoningBudget: 384, reasoningFormat: "deepseek", reasoningPreserve: true),
            ggufSourceModelID: "bartowski/Qwen_Qwen3-14B-GGUF",
            useCases: [.chat, .coding]
        ),
        ProfilePreset(
            id: "qwen35-m3max-48",
            title: "Qwen 3.6 35B A3B · Q5_K_M",
            hardware: "MacBook Pro M3 Max · 48 GB",
            summary: "Large 128K context, 4 GB cache, full SWA cache, reasoning enabled",
            profile: ServerProfile(name: "Qwen 3.6 35B · M3 Max 48 GB", modelPath: "~/ai-models/Qwen_Qwen3.6-35B-A3B-Q5_K_M.gguf", alias: "qwen3.6-35b-a3b", contextSize: 131072, parallel: 1, flashAttention: true, jinja: true, cacheRAM: 4096, reasoning: "auto", reasoningBudget: 512, reasoningFormat: "deepseek", reasoningPreserve: true, swaFull: true),
            ggufSourceModelID: "bartowski/Qwen_Qwen3.6-35B-A3B-GGUF",
            useCases: [.coding, .chat, .homeAutomation]
        ),
        // Vision+text chat presets: llama.cpp auto-detects the mmproj
        // sibling file (see MultimodalProjector) and wires up --mmproj,
        // so as long as mmprojFilename below is set, "Add preset" fetches
        // both files -- this comment used to say that had to be done by
        // hand, back when the download queue only ever fetched one file
        // per preset; see AppStore.processPresetDownloadQueue.
        ProfilePreset(
            id: "gguf-qwen3-vl-8b-q4-16",
            title: "Qwen3-VL 8B · Q4_K_M",
            hardware: "Mac mini / MacBook Air · 16 GB+",
            summary: "Vision + text chat; about 6 GB with the projector, 32K context",
            profile: ServerProfile(name: "Qwen3-VL 8B · 16 GB Mac", modelPath: "~/ai-models/Qwen3VL-8B-Instruct-Q4_K_M.gguf", alias: "qwen3-vl-8b", contextSize: 32768, parallel: 1, flashAttention: true, jinja: true, cacheRAM: 512, reasoning: "", reasoningBudget: 0, reasoningFormat: "", reasoningPreserve: false),
            ggufSourceModelID: "Qwen/Qwen3-VL-8B-Instruct-GGUF",
            useCases: [.chat, .visionChat],
            mmprojFilename: "mmproj-Qwen3VL-8B-Instruct-F16.gguf"
        ),
        ProfilePreset(
            id: "gguf-qwen3-vl-8b-q8-32",
            title: "Qwen3-VL 8B · Q8_0",
            hardware: "MacBook Pro Max / Mac Studio · 32 GB+",
            summary: "Higher-fidelity vision + text chat; about 10 GB with the projector, 64K context",
            profile: ServerProfile(name: "Qwen3-VL 8B Q8 · 32 GB Mac", modelPath: "~/ai-models/Qwen3VL-8B-Instruct-Q8_0.gguf", alias: "qwen3-vl-8b-q8", contextSize: 65536, parallel: 1, flashAttention: true, jinja: true, cacheRAM: 1024, reasoning: "", reasoningBudget: 0, reasoningFormat: "", reasoningPreserve: false),
            ggufSourceModelID: "Qwen/Qwen3-VL-8B-Instruct-GGUF",
            useCases: [.chat, .visionChat],
            mmprojFilename: "mmproj-Qwen3VL-8B-Instruct-F16.gguf"
        ),
        ProfilePreset(
            id: "gguf-qwen3-vl-32b-q4-48",
            title: "Qwen3-VL 32B · Q4_K_M",
            hardware: "MacBook Pro M3 Max · 48 GB",
            summary: "Flagship vision + text chat; about 21 GB with the projector, 64K context",
            profile: ServerProfile(name: "Qwen3-VL 32B · M3 Max 48 GB", modelPath: "~/ai-models/Qwen3VL-32B-Instruct-Q4_K_M.gguf", alias: "qwen3-vl-32b", contextSize: 65536, parallel: 1, flashAttention: true, jinja: true, cacheRAM: 4096, reasoning: "", reasoningBudget: 0, reasoningFormat: "", reasoningPreserve: false),
            ggufSourceModelID: "Qwen/Qwen3-VL-32B-Instruct-GGUF",
            useCases: [.chat, .visionChat],
            mmprojFilename: "mmproj-Qwen3VL-32B-Instruct-F16.gguf"
        ),
        ProfilePreset(
            id: "qwen8-16",
            title: "Qwen3 8B · Q4_K_M",
            hardware: "M1/M2/M3/M4 · 16 GB",
            summary: "Conservative 8K context for entry-level unified memory",
            profile: ServerProfile(name: "Qwen3 8B · 16 GB Mac", modelPath: "~/ai-models/Qwen_Qwen3-8B-Q4_K_M.gguf", alias: "qwen3-8b", contextSize: 8192, parallel: 1, flashAttention: true, jinja: true, cacheRAM: 1024, reasoning: "auto", reasoningBudget: 256, reasoningFormat: "deepseek", reasoningPreserve: false),
            ggufSourceModelID: "bartowski/Qwen_Qwen3-8B-GGUF",
            useCases: [.chat, .coding]
        ),
        ProfilePreset(
            id: "gemma12-24",
            title: "Gemma 3 12B · Q4_K_M",
            hardware: "Mac mini / MacBook Pro · 24 GB",
            summary: "Balanced 16K context for text and vision-capable models",
            profile: ServerProfile(name: "Gemma 3 12B · 24 GB Mac", modelPath: "~/ai-models/google_gemma-3-12b-it-Q4_K_M.gguf", alias: "gemma-3-12b", contextSize: 16384, parallel: 1, flashAttention: true, jinja: true, cacheRAM: 2048, reasoning: "", reasoningBudget: 0, reasoningFormat: "", reasoningPreserve: false),
            // Confirmed vision-capable: bartowski's repo also ships
            // mmproj-google_gemma-3-12b-it-*.gguf projector files, and
            // llama.cpp auto-wires --mmproj from a sibling in the model
            // folder (see MultimodalProjector) -- same mechanism the
            // Qwen3-VL presets above rely on. f16 over bf16/f32 for the
            // same reason as Mistral Small 3.1 above.
            ggufSourceModelID: "bartowski/google_gemma-3-12b-it-GGUF",
            useCases: [.chat, .visionChat],
            mmprojFilename: "mmproj-google_gemma-3-12b-it-f16.gguf"
        ),
        ProfilePreset(
            id: "qwen30-36",
            title: "Qwen3 30B A3B · Q4_K_M",
            hardware: "M2/M3/M4 Pro or Max · 36–48 GB",
            summary: "32K context and reasoning with comfortable memory headroom",
            profile: ServerProfile(name: "Qwen3 30B A3B · 36–48 GB Mac", modelPath: "~/ai-models/Qwen_Qwen3-30B-A3B-Q4_K_M.gguf", alias: "qwen3-30b-a3b", contextSize: 32768, parallel: 1, flashAttention: true, jinja: true, cacheRAM: 4096, reasoning: "auto", reasoningBudget: 512, reasoningFormat: "deepseek", reasoningPreserve: true),
            ggufSourceModelID: "bartowski/Qwen_Qwen3-30B-A3B-GGUF",
            useCases: [.chat, .coding]
        ),
        ProfilePreset(
            id: "llama70-64",
            title: "Llama 3.3 70B Instruct · Q4_K_M",
            hardware: "Mac Studio / MacBook Pro Max · 64 GB+",
            summary: "Large model preset with 16K context and 6 GB cache",
            profile: ServerProfile(name: "Llama 3.3 70B · 64 GB+ Mac", modelPath: "~/ai-models/Llama-3.3-70B-Instruct-Q4_K_M.gguf", alias: "llama-3.3-70b", contextSize: 16384, parallel: 1, flashAttention: true, jinja: true, cacheRAM: 6144, reasoning: "", reasoningBudget: 0, reasoningFormat: "", reasoningPreserve: false),
            ggufSourceModelID: "bartowski/Llama-3.3-70B-Instruct-GGUF",
            useCases: [.chat, .coding]
        ),
        ProfilePreset(
            id: "qwen32-64-studio",
            title: "Qwen3 32B · Q6_K",
            hardware: "Mac Studio Max · 64–96 GB",
            summary: "Higher-quality quantization, 32K context, and ample cache",
            profile: ServerProfile(name: "Qwen3 32B · Mac Studio 64–96 GB", modelPath: "~/ai-models/Qwen_Qwen3-32B-Q6_K.gguf", alias: "qwen3-32b", contextSize: 32768, parallel: 1, flashAttention: true, jinja: true, cacheRAM: 6144, reasoning: "auto", reasoningBudget: 768, reasoningFormat: "deepseek", reasoningPreserve: true),
            ggufSourceModelID: "bartowski/Qwen_Qwen3-32B-GGUF",
            useCases: [.chat, .coding]
        ),
        // Q6_K and Q8_0 at 70B both exceed Hugging Face's single-file
        // comfort limit, so every quantizer (bartowski, unsloth) ships
        // them pre-split into two parts under a same-named subdirectory
        // (e.g. "Llama-3.3-70B-Instruct-Q6_K/…-00001-of-00002.gguf").
        // download(file:from:to:ownerProfileID:) only ever fetches one
        // flat filename, so it can't reassemble a split model --
        // ggufSourceModelID deliberately stays unset for these two and
        // "Add all presets" leaves them as manual downloads. modelPath
        // points at the first part with llama.cpp's own split-file
        // naming so that once both parts are placed in the model
        // directory, llama-server (given the first part's path) finds
        // and loads the rest on its own.
        ProfilePreset(
            id: "llama70-128-ultra-pro",
            title: "Llama 3.3 70B Instruct · Q6_K",
            hardware: "Mac Studio Ultra / Mac Pro · 128 GB+",
            summary: "Quality-focused 70B preset with 32K context; ships as two split GGUF files -- download both from the same repo into the model folder",
            profile: ServerProfile(name: "Llama 3.3 70B · Ultra/Pro 128 GB+", modelPath: "~/ai-models/Llama-3.3-70B-Instruct-Q6_K-00001-of-00002.gguf", alias: "llama-3.3-70b-q6", contextSize: 32768, parallel: 1, flashAttention: true, jinja: true, cacheRAM: 8192, reasoning: "", reasoningBudget: 0, reasoningFormat: "", reasoningPreserve: false),
            useCases: [.chat, .coding]
        ),
        ProfilePreset(
            id: "llama70-192-ultra-pro",
            title: "Llama 3.3 70B Instruct · Q8_0",
            hardware: "Mac Studio Ultra / Mac Pro · 192 GB+",
            summary: "High-fidelity 70B preset with 65K context and large cache; ships as two split GGUF files -- download both from the same repo into the model folder",
            profile: ServerProfile(name: "Llama 3.3 70B · Ultra/Pro 192 GB+", modelPath: "~/ai-models/Llama-3.3-70B-Instruct-Q8_0-00001-of-00002.gguf", alias: "llama-3.3-70b-q8", contextSize: 65536, parallel: 1, flashAttention: true, jinja: true, cacheRAM: 12288, reasoning: "", reasoningBudget: 0, reasoningFormat: "", reasoningPreserve: false),
            useCases: [.chat, .coding]
        ),
        ProfilePreset(
            id: "llama70-q8-128-studio-ultra",
            title: "Llama 3.3 70B Instruct · Q8_0",
            hardware: "Mac Studio Ultra · 128 GB",
            summary: "Dense quality-focused model with a conservative 16K context and resident HA headroom; ships as two split GGUF files -- download both from the same repo into the model folder",
            profile: ServerProfile(name: "Llama 3.3 70B Q8 · Studio Ultra 128 GB", modelPath: "~/ai-models/Llama-3.3-70B-Instruct-Q8_0-00001-of-00002.gguf", alias: "llama-3.3-70b-q8", contextSize: 16384, parallel: 1, flashAttention: true, jinja: true, cacheRAM: 8192, reasoning: "", reasoningBudget: 0, reasoningFormat: "", reasoningPreserve: false),
            useCases: [.chat, .coding]
        ),
        ProfilePreset(
            id: "mlx-qwen3-235b-a22b-192",
            title: "Qwen3 235B A22B · MLX 4-bit",
            hardware: "Mac Studio Ultra · 192 GB+",
            summary: "Flagship MoE preset; approximately 132 GB of weights with the native 40K context",
            profile: ServerProfile(backend: .mlxLM, name: "MLX · Qwen3 235B A22B · Studio Ultra", executable: "mlx_lm.server", modelPath: "mlx-community/Qwen3-235B-A22B-4bit", alias: "qwen3-235b-a22b", contextSize: 40960, parallel: 1, flashAttention: false, jinja: false, cacheRAM: 10, reasoning: "", reasoningBudget: 0, reasoningFormat: "", reasoningPreserve: false),
            useCases: [.coding, .chat]
        )
    ]
}

struct ModelCategory: Identifiable, Hashable {
    let id: String
    let title: String
    let icon: String
    var sort = "downloads"
    var pipelineTag: String? = nil
    var tag: String? = nil
    var recommendedFamilies: [String] = []
    var recommendedModelIDs: [String] = []
    var minimumSize: Int64? = nil
    var maximumSize: Int64? = nil

    private static func task(_ id: String, _ title: String, _ icon: String) -> Self {
        .init(id: "task-\(id)", title: title, icon: icon, pipelineTag: id)
    }
    private static func language(_ code: String, _ title: String) -> Self {
        .init(id: "language-\(code)", title: title, icon: "globe", tag: code)
    }

    static let recommendedCoding = Self(id: "recommended-coding", title: "Recommended for Coding", icon: "chevron.left.forwardslash.chevron.right", recommendedFamilies: ["Qwen Coder", "DeepSeek Coder", "Codestral", "StarCoder", "Granite Code"], recommendedModelIDs: ["Qwen/Qwen2.5-Coder-7B-Instruct-GGUF", "bartowski/Qwen_Qwen3.6-35B-A3B-GGUF", "ggml-org/Qwen3.6-27B-GGUF", "DhruvalLabs/GLM-4.7-Flash-GGUF", "mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit", "mlx-community/Qwen3.6-27B-4bit", "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit", "mlx-community/Qwen3-Coder-30B-A3B-Instruct-8bit", "mlx-community/Qwen3.6-35B-A3B-4bit", "mlx-community/Qwen3.6-35B-A3B-8bit", "mlx-community/gpt-oss-20b-MXFP4-Q4", "mlx-community/gpt-oss-20b-MXFP4-Q8", "mlx-community/Qwen3-235B-A22B-4bit"])
    static let recommendedChat = Self(id: "recommended-chat", title: "Recommended for Prompted Chat", icon: "bubble.left.and.bubble.right.fill", recommendedFamilies: ["Qwen Instruct", "Llama Instruct", "Mistral Instruct", "Gemma it", "Phi"], recommendedModelIDs: ["ggml-org/Qwen3.6-27B-GGUF", "DhruvalLabs/GLM-4.7-Flash-GGUF", "mlx-community/Qwen3.6-27B-4bit", "mlx-community/Qwen3.6-35B-A3B-4bit", "mlx-community/Qwen3.6-35B-A3B-8bit", "mlx-community/gpt-oss-20b-MXFP4-Q4", "mlx-community/gpt-oss-20b-MXFP4-Q8"])
    static let recommendedSystems = Self(id: "recommended-systems", title: "Recommended for Systems Management", icon: "server.rack", recommendedFamilies: ["Qwen Coder", "Granite Code", "DeepSeek Coder", "Command R"], recommendedModelIDs: ["DhruvalLabs/GLM-4.7-Flash-GGUF", "mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit", "mlx-community/Qwen3.6-27B-4bit", "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit", "mlx-community/gpt-oss-20b-MXFP4-Q4", "mlx-community/gpt-oss-20b-MXFP4-Q8"])
    static let recommendedHomeAutomation = Self(id: "recommended-home-automation", title: "Recommended for Home Automation", icon: "house.and.flag.fill", recommendedFamilies: [], recommendedModelIDs: ["mlx-community/Qwen3-4B-4bit", "mlx-community/Qwen3.5-9B-MLX-4bit", "mlx-community/Qwen3-VL-8B-Instruct-4bit", "mlx-community/gpt-oss-20b-MXFP4-Q4", "mlx-community/gpt-oss-20b-MXFP4-Q8", "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit", "mlx-community/Qwen3.6-35B-A3B-4bit", "bartowski/Qwen_Qwen3.6-35B-A3B-GGUF"])
    /// Chat models that can also read an attached image -- i.e. ones
    /// llama.cpp can serve with a matching mmproj projector (see
    /// MultimodalProjector), or an MLX build mlx-vlm actually loads.
    /// Deliberately narrower than ModelCategory.multimodal's raw
    /// "image-text-to-text" pipeline tag, which turns up plenty of
    /// vision models that aren't really a fit for open-ended chat, and
    /// some GGUF/MLX conversions of newer VL releases whose runtime
    /// support isn't there yet (e.g. mlx-vlm's Qwen3-VL-30B-A3B convert
    /// currently fails to load with "Model type qwen3_vl_moe not
    /// supported"). Everything listed here is a plain dense Qwen3-VL
    /// Instruct build with a working GGUF+mmproj release from Qwen
    /// themselves, or the same family's existing MLX 4-bit convert.
    /// pipelineTag constrains this category's *live* Hugging Face search
    /// (both the family-keyword search and, for every other category,
    /// the plain browse) to models tagged "image-text-to-text" -- i.e.
    /// actually capable of both, not just a family-name text match that
    /// happens to also turn up text-only siblings from the same family.
    /// The hand-picked recommendedModelIDs above are exempt from this
    /// (they're already confirmed vision+text), so this only tightens
    /// what else surfaces alongside them.
    static let recommendedVisionChat = Self(id: "recommended-vision-chat", title: "Chat with Images", icon: "photo.on.rectangle.angled", pipelineTag: "image-text-to-text", recommendedFamilies: ["Qwen VL Instruct"], recommendedModelIDs: ["Qwen/Qwen3-VL-8B-Instruct-GGUF", "Qwen/Qwen3-VL-32B-Instruct-GGUF", "mlx-community/Qwen3-VL-8B-Instruct-4bit"])
    static let recommendedAppleSilicon = Self(id: "recommended-apple-silicon", title: "Recommended for Apple Silicon", icon: "apple.logo", recommendedFamilies: ["Qwen Instruct", "Llama Instruct", "Mistral Instruct", "Gemma it", "Phi"], recommendedModelIDs: ["Qwen/Qwen2.5-Coder-7B-Instruct-GGUF", "bartowski/Qwen_Qwen3.6-35B-A3B-GGUF", "ggml-org/Qwen3.6-27B-GGUF", "DhruvalLabs/GLM-4.7-Flash-GGUF", "mlx-community/Qwen3-4B-4bit", "mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit", "mlx-community/Qwen3.6-27B-4bit", "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit", "mlx-community/Qwen3-Coder-30B-A3B-Instruct-8bit", "mlx-community/Qwen3.6-35B-A3B-4bit", "mlx-community/Qwen3.6-35B-A3B-6bit", "mlx-community/Qwen3.6-35B-A3B-8bit", "mlx-community/gpt-oss-20b-MXFP4-Q4", "mlx-community/gpt-oss-20b-MXFP4-Q8", "mlx-community/Qwen3-235B-A22B-4bit"])
    static let all = Self(id: "all", title: "All", icon: "square.grid.2x2")
    static let trending = Self(id: "trending", title: "Trending", icon: "flame", sort: "trendingScore")
    static let mostDownloaded = Self(id: "downloads", title: "Most downloaded", icon: "arrow.down.circle")
    static let mostLiked = Self(id: "likes", title: "Most liked", icon: "heart", sort: "likes")
    static let recentlyUpdated = Self(id: "recent", title: "Recently updated", icon: "clock.arrow.circlepath", sort: "lastModified")
    static let discovery: [Self] = [.trending, .mostDownloaded, .mostLiked, .recentlyUpdated]
    static let multimodal: [Self] = [
        task("audio-text-to-text", "Audio-text-to-text", "waveform.and.mic"),
        task("image-text-to-text", "Image-text-to-text", "photo.badge.ellipsis"),
        task("image-text-to-image", "Image-text-to-image", "photo.on.rectangle.angled"),
        task("image-text-to-video", "Image-text-to-video", "video.badge.plus"),
        task("visual-question-answering", "Visual question answering", "questionmark.bubble"),
        task("document-question-answering", "Document question answering", "doc.text.magnifyingglass"),
        task("video-text-to-text", "Video-text-to-text", "video.bubble"),
        task("any-to-any", "Any-to-any", "arrow.triangle.branch")
    ]
    static let computerVision: [Self] = [
        task("depth-estimation", "Depth estimation", "square.3.layers.3d"),
        task("image-classification", "Image classification", "photo.badge.checkmark"),
        task("object-detection", "Object detection", "viewfinder"),
        task("image-segmentation", "Image segmentation", "square.dashed"),
        task("text-to-image", "Text-to-image", "text.below.photo"),
        task("image-to-text", "Image-to-text", "text.viewfinder"),
        task("image-to-image", "Image-to-image", "photo.stack"),
        task("image-to-video", "Image-to-video", "video"),
        task("text-to-video", "Text-to-video", "video.badge.ellipsis"),
        task("zero-shot-image-classification", "Zero-shot image classification", "photo.badge.questionmark"),
        task("mask-generation", "Mask generation", "theatermasks"),
        task("image-feature-extraction", "Image feature extraction", "point.3.filled.connected.trianglepath.dotted")
    ]
    static let nlp: [Self] = [
        task("text-generation", "Text generation", "text.bubble"),
        task("text-classification", "Text classification", "text.badge.checkmark"),
        task("token-classification", "Token classification", "character.cursor.ibeam"),
        task("table-question-answering", "Table question answering", "tablecells"),
        task("question-answering", "Question answering", "questionmark.bubble"),
        task("zero-shot-classification", "Zero-shot classification", "scope"),
        task("translation", "Translation", "translate"),
        task("summarization", "Summarization", "text.alignleft"),
        task("feature-extraction", "Feature extraction / embeddings", "point.3.connected.trianglepath.dotted"),
        task("sentence-similarity", "Sentence similarity", "equal.circle")
    ]
    static let audio: [Self] = [
        task("automatic-speech-recognition", "Automatic speech recognition", "waveform"),
        task("text-to-speech", "Text-to-speech", "speaker.wave.3"),
        task("audio-classification", "Audio classification", "waveform.badge.magnifyingglass"),
        task("voice-activity-detection", "Voice activity detection", "mic.badge.plus")
    ]
    static let coding: [Self] = [
        .init(id: "coding", title: "Coding", icon: "chevron.left.forwardslash.chevron.right", tag: "code"),
        .init(id: "text-to-sql", title: "Text to SQL", icon: "cylinder.split.1x2", tag: "text-to-sql"),
        .init(id: "code-completion", title: "Code completion", icon: "text.cursor", tag: "code-completion")
    ]
    static let languages: [Self] = [
        language("en", "English"), language("zh", "Chinese"), language("fr", "French"),
        language("es", "Spanish"), language("de", "German"), language("ja", "Japanese"),
        language("ko", "Korean"), language("pt", "Portuguese"), language("it", "Italian"),
        language("ru", "Russian"), language("ar", "Arabic"), language("hi", "Hindi"),
        language("th", "Thai"), language("multilingual", "Multilingual"), language("tr", "Turkish"),
        language("vi", "Vietnamese"), language("nl", "Dutch"), language("pl", "Polish"),
        language("id", "Indonesian"), language("sv", "Swedish"), language("uk", "Ukrainian"),
        language("fi", "Finnish"), language("da", "Danish"), language("no", "Norwegian")
    ]
}

struct HFModel: Codable, Identifiable, Hashable {
    let id: String
    let downloads: Int?
    let likes: Int?
    let lastModified: String?
    let pipeline_tag: String?
    let tags: [String]?
    let usedStorage: Int64?
    var sha: String? = nil
    var siblings: [HFModelDetail.Sibling]? = nil
}

struct HFModelDetail: Codable {
    struct Sibling: Codable, Hashable {
        struct LFS: Codable, Hashable {
            let size: Int64?
            let sha256: String?
        }
        let rfilename: String
        let size: Int64?
        let lfs: LFS?
    }
    let id: String
    let siblings: [Sibling]?
}

struct ModelVersionEntry: Equatable {
    let name: String
    let size: Int64
}

/// Normalizes repository contents into the rows shown by the model store.
/// MLX repositories are a single downloadable snapshot, while GGUF repositories
/// expose one row per weight file. Both paths deliberately produce the same row model.
enum ModelVersionInventory {
    static func entries(modelID: String, backend: InferenceBackend, siblings: [HFModelDetail.Sibling]) -> [ModelVersionEntry] {
        if backend != .llamaCPP {
            let name = modelID.split(separator: "/").last.map(String.init) ?? modelID
            let size = siblings.reduce(Int64(0)) { $0 + ($1.lfs?.size ?? $1.size ?? 0) }
            return [ModelVersionEntry(name: name, size: size)]
        }

        return siblings
            .filter { $0.rfilename.lowercased().hasSuffix(".gguf") }
            .map { ModelVersionEntry(name: $0.rfilename, size: $0.lfs?.size ?? $0.size ?? 0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// A library download may update a profile only when that exact profile
/// explicitly initiated the download.
enum DownloadProfileOwnership {
    static func permitsAssignment(to profileID: UUID, ownerProfileID: UUID?) -> Bool {
        profileID == ownerProfileID
    }
}

struct ChatMessage: Identifiable, Codable {
    let id: UUID
    let role: String
    var content: String
    var imageAttachments: [ChatImageAttachment]

    init(role: String, content: String, imageAttachments: [ChatImageAttachment] = []) {
        id = UUID(); self.role = role; self.content = content; self.imageAttachments = imageAttachments
    }

    private enum CodingKeys: String, CodingKey { case id, role, content, imageAttachments }

    // Custom decode (encode(to:) is still synthesized from CodingKeys
    // above) so chats saved before image attachments existed still load:
    // an absent "imageAttachments" key just means this message has none,
    // rather than failing to decode the whole chat.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(String.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        imageAttachments = try container.decodeIfPresent([ChatImageAttachment].self, forKey: .imageAttachments) ?? []
    }
}

struct PendingChatAttachment: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let path: String
    let text: String
    var byteCount: Int { text.utf8.count }
}

enum ChatAttachmentPayload {
    static let maximumFileBytes = 2 * 1024 * 1024
    static let maximumTotalBytes = 8 * 1024 * 1024

    static func render(prompt: String, attachments: [PendingChatAttachment]) -> String {
        guard !attachments.isEmpty else { return prompt }
        let files = attachments.map { attachment in
            "<attached_file name=\"\(attachment.name.replacingOccurrences(of: "\"", with: "&quot;"))\">\n\(attachment.text)\n</attached_file>"
        }.joined(separator: "\n\n")
        let request = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return request.isEmpty ? files : "\(request)\n\n\(files)"
    }
}

/// A user-attached image, persisted to disk (AppStore's chat-images
/// support directory) alongside its message rather than inlined as
/// base64 into ChatMessage.content -- chats.json is rewritten in full on
/// every streamed token (see AppStore.saveChats), and a multi-megabyte
/// base64 blob riding along on every single one of those writes would
/// make a long streamed reply noticeably slower to type out.
/// `filename` is relative to that directory.
struct ChatImageAttachment: Identifiable, Codable, Equatable {
    let id: UUID
    let filename: String
    let mimeType: String
    init(id: UUID = UUID(), filename: String, mimeType: String) {
        self.id = id; self.filename = filename; self.mimeType = mimeType
    }
}

/// Pure sizing decisions for an attached image, kept separate from the
/// actual NSImage/CGImage decoding and re-encoding work
/// (AppStore.attachChatFiles) so the policy itself -- when to downscale,
/// and by how much -- is unit-testable without touching AppKit.
enum ChatImageAttachmentPolicy {
    // Well above what any of InferenceBar's vision presets actually need
    // -- Qwen3-VL and similar tile their input around this size
    // internally regardless -- so downscaling to it before base64-encoding
    // keeps a multi-megapixel photo from turning into a many-megabyte
    // request body and a slow prompt-eval pass for no quality benefit.
    static let maximumLongEdge = 1568
    // Guards against decoding an absurd source file into memory at all;
    // the actual request-body size is bounded by maximumEncodedBytes
    // below regardless of how large the original was.
    static let maximumSourceFileBytes = 40 * 1024 * 1024
    // Applied to the final, already-downscaled/re-encoded image. Rarely
    // the limiting factor once maximumLongEdge has been applied, but
    // still checked so an unusually dense image can't slip through.
    static let maximumEncodedBytes = 8 * 1024 * 1024

    /// The size to encode an image at, preserving aspect ratio. Returns
    /// the original size unchanged when it's already within bounds.
    static func targetSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let longEdge = max(width, height)
        guard longEdge > maximumLongEdge, longEdge > 0 else { return (width, height) }
        let scale = Double(maximumLongEdge) / Double(longEdge)
        let scaledWidth = max(1, Int((Double(width) * scale).rounded()))
        let scaledHeight = max(1, Int((Double(height) * scale).rounded()))
        return (scaledWidth, scaledHeight)
    }

    /// Whether a profile with this runtime and mmproj-detection result
    /// should have image attachments refused outright, rather than sent
    /// and left to llama-server itself to reject with a raw "image input
    /// is not supported" 500 (which is what used to happen -- the
    /// composer only warned, it never actually stopped the attach or the
    /// send). True only for a llama.cpp profile with no projector
    /// detected next to its model. MLX and vLLM-MLX are never blocked
    /// here: InferenceBar doesn't wire up --mmproj for those backends at
    /// all, so "no projector detected" doesn't mean anything for them --
    /// they may still support vision input on their own.
    static func blocksImageAttachment(runtime: InferenceBackend, hasProjector: Bool) -> Bool {
        runtime == .llamaCPP && !hasProjector
    }
}

/// Attached images are real files under AppStore's chat-images directory
/// (see ChatImageAttachment), not something chats.json itself tracks the
/// existence of on disk -- so deleting a chat, editing a message to
/// truncate history, or regenerating an answer can each leave a file
/// behind with nothing left referencing it. Kept as a pure
/// referenced-vs-on-disk diff (AppStore.pruneOrphanedChatImages does the
/// actual directory listing and deletion) so the decision of what counts
/// as orphaned is unit-testable on its own.
enum ChatImageStorage {
    static func orphanedFilenames(referenced: Set<String>, onDisk: [String]) -> [String] {
        onDisk.filter { !referenced.contains($0) }
    }
}

enum ChatContentSegment: Equatable {
    case prose(String)
    case code(language: String, source: String)
    case table(headers: [String], rows: [[String]])
}

enum ChatMarkdownParser {
    static func segments(_ content: String) -> [ChatContentSegment] {
        let content = visibleAnswer(from: content)
        if let opening = content.range(of: "```markdown", options: [.caseInsensitive]),
           let closing = content.range(of: "```", options: [.backwards]), closing.lowerBound > opening.upperBound {
            let before = String(content[..<opening.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let document = String(content[opening.upperBound..<closing.lowerBound]).trimmingCharacters(in: .newlines)
            let after = String(content[closing.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            var rendered: [ChatContentSegment] = []
            if !before.isEmpty { rendered += segments(before) }
            rendered += segments(document)
            if !after.isEmpty { rendered += segments(after) }
            return rendered
        }
        var result: [ChatContentSegment] = []
        var prose: [String] = []
        var code: [String] = []
        var language = ""
        var insideFence = false

        func flushProse() {
            guard !prose.isEmpty else { return }
            appendBlocks(prose, to: &result)
            prose.removeAll()
        }
        func flushCode() {
            let source = code.joined(separator: "\n")
            if language.isEmpty && !looksLikeCode(source) { result.append(.prose(source)) }
            else { result.append(.code(language: language, source: source)) }
            code.removeAll(); language = ""
        }

        let lines = content.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if insideFence { flushCode() }
                else {
                    flushProse()
                    language = String(line.trimmingCharacters(in: .whitespaces).dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
                insideFence.toggle()
            } else if !insideFence && line.trimmingCharacters(in: .whitespaces).hasPrefix("#!") {
                flushProse()
                result.append(.code(language: line.lowercased().contains("bash") || line.lowercased().contains("sh") ? "bash" : "script", source: lines[index...].joined(separator: "\n")))
                index = lines.count
                continue
            } else if insideFence { code.append(line) }
            else { prose.append(line) }
            index += 1
        }
        if insideFence { flushCode() } else { flushProse() }
        return result
    }

    static func visibleAnswer(from content: String) -> String {
        var value = content
        if let regex = try? NSRegularExpression(pattern: "(?is)<think>.*?</think>"), !value.isEmpty {
            value = regex.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "")
        }
        if let closing = value.range(of: "</think>", options: .caseInsensitive), value.range(of: "<think>", options: .caseInsensitive) == nil {
            value = String(value[closing.upperBound...])
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func looksLikeCode(_ source: String) -> Bool {
        let lowered = source.lowercased()
        if lowered.hasPrefix("#!") { return true }
        let markers = ["func ", "class ", "struct ", "import ", "#!/", "echo ", "if [", "for ", "while ", "<?php", "const ", "let ", "var ", "def "]
        let hits = markers.reduce(0) { $0 + (lowered.contains($1) ? 1 : 0) }
        return hits >= 1 || source.contains("{") && source.contains("}") || source.contains(";")
    }

    private static func appendBlocks(_ lines: [String], to result: inout [ChatContentSegment]) {
        var pending: [String] = []
        func flushPending() {
            guard !pending.isEmpty else { return }
            let text = pending.joined(separator: "\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { pending.removeAll(); return }
            let diagramLines = pending.filter { $0.contains("──") || $0.contains("___") || $0.filter({ $0 == "|" }).count >= 3 }
            if pending.count >= 3, diagramLines.count >= 2 { result.append(.code(language: "text", source: text)) }
            else { result.append(.prose(text)) }
            pending.removeAll()
        }
        var index = 0
        while index < lines.count {
            if index + 1 < lines.count, let headers = tableCells(lines[index]), isTableSeparator(lines[index + 1]), !headers.isEmpty {
                flushPending(); index += 2
                var rows: [[String]] = []
                while index < lines.count, let cells = tableCells(lines[index]), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(cells); index += 1
                }
                result.append(.table(headers: headers, rows: rows))
            } else { pending.append(lines[index]); index += 1 }
        }
        flushPending()
    }

    private static func tableCells(_ line: String) -> [String]? {
        guard line.contains("|") else { return nil }
        var value = line.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("|") { value.removeFirst() }
        if value.hasSuffix("|") { value.removeLast() }
        let cells = value.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        return cells.count >= 2 ? cells : nil
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        guard let cells = tableCells(line) else { return false }
        return cells.allSatisfy { cell in
            let value = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return value.count >= 3 && value.allSatisfy { $0 == "-" }
        }
    }
}

enum ChatProseLayout {
    static func attributed(_ content: String) -> AttributedString {
        (try? AttributedString(markdown: linkifyBareURLs(content), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(content)
    }

    static func markdownSource(_ content: String) -> String {
        let linked = linkifyBareURLs(content)
        let lines = linked.components(separatedBy: "\n")
        var output: [String] = []
        for index in lines.indices {
            let line = lines[index]
            output.append(line)
            guard index < lines.count - 1, !line.isEmpty, !lines[index + 1].isEmpty else { continue }
            let currentIsList = isListLine(line)
            let nextIsList = isListLine(lines[index + 1])
            if !currentIsList && !nextIsList { output.append("") }
        }
        return output.joined(separator: "\n")
    }

    private static func isListLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") || trimmed.range(of: #"^\d+[.)]\s"#, options: .regularExpression) != nil
    }

    private static func linkifyBareURLs(_ content: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"(?<![<(\"])(https?://[^\s<>]+)"#) else { return content }
        return regex.stringByReplacingMatches(in: content, range: NSRange(content.startIndex..., in: content), withTemplate: "<$1>")
    }
}

enum ChatComposerSizing {
    static func height(for text: String, approximateCharactersPerLine: Int = 72, minimum: Double = 44, maximum: Double = 220) -> Double {
        let logicalLines = text.components(separatedBy: "\n")
        let visualLines = logicalLines.reduce(0) { total, line in
            total + max(1, Int(ceil(Double(max(line.count, 1)) / Double(approximateCharactersPerLine))))
        }
        return min(max(Double(visualLines) * 20 + 16, minimum), maximum)
    }
}

/// The Chat window's transcript/composer reading-column width, given the
/// scroll viewport's actual width. Scales with the window instead of
/// staying pinned to one fixed width forever -- which left large,
/// increasingly silly empty margins on anything wider than a modest
/// laptop screen. Still capped well short of the full viewport on a very
/// wide or external display, since an uncapped width would just stretch
/// prose lines to the point of being harder to read, not easier.
enum ChatColumnLayout {
    /// The previous fixed width, kept as the floor: a maxWidth is only
    /// ever a ceiling, so a window narrower than this still shrinks below
    /// it exactly as before -- this only ever widens the column, never
    /// narrows it relative to the old behavior.
    static let minimumWidth: Double = 760
    /// A generous cap on very wide/external displays: wide enough to use
    /// the extra space, not so wide that a line of prose runs edge to
    /// edge and becomes harder to read.
    static let maximumWidth: Double = 1200
    /// Left on each side once the column stops growing with the window,
    /// so it doesn't reach all the way to the very edge even below the cap.
    static let sideMargin: Double = 80

    static func maxWidth(forViewportWidth viewportWidth: Double) -> Double {
        min(max(viewportWidth - sideMargin, minimumWidth), maximumWidth)
    }
}

struct ChatProject: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
}

struct SavedChat: Identifiable, Codable {
    var id = UUID()
    var title: String
    var projectID: UUID?
    var messages: [ChatMessage]
    var updatedAt = Date()
    var elapsedSeconds: TimeInterval? = 0

    var markdownExport: String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        var text = "# \(title)\n\n_Exported from InferenceBar · \(dateFormatter.string(from: updatedAt))_\n\n"
        for message in messages {
            let speaker = message.role == "user" ? "You" : (message.role == "assistant" ? "Assistant" : message.role.capitalized)
            text += "**\(speaker):**\n\n\(message.content)\n\n"
            if !message.imageAttachments.isEmpty {
                let count = message.imageAttachments.count
                text += "_(\(count) image\(count == 1 ? "" : "s") attached, not included in this export)_\n\n"
            }
        }
        return text
    }

    // Filesystem-safe stand-in for a title that may contain "/", control
    // characters, or nothing at all after trimming.
    var suggestedExportFilename: String {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: CharacterSet(charactersIn: "/:\\"))
            .joined(separator: "-")
        return (cleaned.isEmpty ? "Chat" : cleaned) + ".md"
    }
}
