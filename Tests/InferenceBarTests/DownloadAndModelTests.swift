import Foundation
import XCTest
@testable import InferenceBar

final class DownloadAndModelTests: XCTestCase {
    func testUpdatePolicyFindsNewestNumericGitHubTag() {
        XCTAssertEqual(AppUpdatePolicy.newestUpdate(tags: ["v0.4", "v0.6", "0.5.2", "nightly"], currentVersion: "0.5"), "v0.6")
        XCTAssertNil(AppUpdatePolicy.newestUpdate(tags: ["v0.4", "v0.5.0"], currentVersion: "0.5"))
        XCTAssertEqual(AppUpdatePolicy.newestUpdate(tags: ["v0.7", "v0.7.1"], currentVersion: "0.7"), "v0.7.1", "a patch release is an update")
        XCTAssertNil(AppUpdatePolicy.newestUpdate(tags: ["v0.7", "v0.7.1"], currentVersion: "0.7.1"))
        XCTAssertEqual(AppUpdatePolicy.checkInterval, 3600)
    }

    func testDefaultProfileStartupPolicy() {
        XCTAssertTrue(DefaultProfileStartupPolicy.shouldStart(enabled: true, defaultProfileExists: true, lifecycle: .stopped))
        XCTAssertFalse(DefaultProfileStartupPolicy.shouldStart(enabled: false, defaultProfileExists: true, lifecycle: .stopped))
        XCTAssertFalse(DefaultProfileStartupPolicy.shouldStart(enabled: true, defaultProfileExists: false, lifecycle: .stopped))
        XCTAssertFalse(DefaultProfileStartupPolicy.shouldStart(enabled: true, defaultProfileExists: true, lifecycle: .running))
    }

    func testCLIInstallPolicyPrefersHomebrewBinWhenWritable() {
        XCTAssertEqual(
            CLIInstallPolicy.destinationDirectory(homebrewBinIsWritableDirectory: true, homeDirectory: "/Users/alex"),
            "/opt/homebrew/bin"
        )
    }

    func testCLIInstallPolicyFallsBackToLocalBinWhenHomebrewBinIsNotWritable() {
        XCTAssertEqual(
            CLIInstallPolicy.destinationDirectory(homebrewBinIsWritableDirectory: false, homeDirectory: "/Users/alex"),
            "/Users/alex/.local/bin"
        )
    }

    func testCLIInstallPolicyIsOnPATHMatchesWholeDirectoryEntries() {
        XCTAssertTrue(CLIInstallPolicy.isOnPATH("/opt/homebrew/bin", pathEnvironmentVariable: "/usr/bin:/opt/homebrew/bin:/bin"))
        // Not fooled by a directory that merely starts with the same prefix.
        XCTAssertFalse(CLIInstallPolicy.isOnPATH("/opt/homebrew/bin", pathEnvironmentVariable: "/opt/homebrew/binary:/usr/bin"))
    }

    func testCLIInstallPolicyIsOnPATHFalseWhenAbsent() {
        XCTAssertFalse(CLIInstallPolicy.isOnPATH("/Users/alex/.local/bin", pathEnvironmentVariable: "/usr/bin:/bin"))
        XCTAssertFalse(CLIInstallPolicy.isOnPATH("/Users/alex/.local/bin", pathEnvironmentVariable: ""))
    }

    func testCLIInstallPolicySystemDirectoryIsTheStockMacOSDefault() {
        // /usr/local/bin is on every standard login shell's PATH out of
        // the box (see /etc/paths) with no profile edits needed -- the
        // preferred install target, tried before Homebrew's own bin.
        XCTAssertEqual(CLIInstallPolicy.systemDirectory, "/usr/local/bin")
        XCTAssertTrue(CLIInstallPolicy.isOnPATH(CLIInstallPolicy.systemDirectory, pathEnvironmentVariable: "/usr/local/bin:/usr/bin:/bin"))
    }

    func testLegacyChatsDecodeWithAStoppedZeroDuration() throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000001","title":"Old chat","projectID":null,"messages":[],"updatedAt":0}"#.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let chat = try decoder.decode(SavedChat.self, from: json)
        XCTAssertEqual(chat.elapsedSeconds ?? 0, 0)
    }

    func testChatProseRetainsModelLineBreaks() {
        let rendered = ChatProseLayout.attributed("Intro:\n**First** item\n**Second** item")
        XCTAssertEqual(String(rendered.characters), "Intro:\nFirst item\nSecond item")
    }

    func testChatProseUsesFullMarkdownAndAutolinksWebURLs() {
        let source = ChatProseLayout.markdownSource("# Heading\nVisit https://example.com/docs")
        XCTAssertTrue(source.contains("# Heading"))
        XCTAssertTrue(source.contains("<https://example.com/docs>"))
        XCTAssertEqual(String(ChatProseLayout.attributed("# Heading\nVisit https://example.com/docs").characters), "# Heading\nVisit https://example.com/docs")
    }

    func testProfileOutputTokenLimitDefaultsAndClamps() {
        var profile = ServerProfile()
        XCTAssertEqual(profile.effectiveMaximumOutputTokens, 8_192)
        profile.maximumOutputTokens = 100
        XCTAssertEqual(profile.effectiveMaximumOutputTokens, 256)
        profile.maximumOutputTokens = 100_000
        XCTAssertEqual(profile.effectiveMaximumOutputTokens, 65_536)
    }

    func testProcessLogBufferEmitsOnlyCompleteUTF8Lines() {
        var buffer = ProcessLogLineBuffer()
        let bytes = Array("progress: café\npartial".utf8)
        var output = ""
        for byte in bytes { if let line = buffer.append(byte) { output += line } }
        XCTAssertEqual(output, "progress: café\n")
        XCTAssertEqual(buffer.flush(), "partial")
        XCTAssertNil(buffer.flush())
    }

    func testMenuBarLocksProfilesAndLabelsStoppingState() {
        XCTAssertTrue(MenuBarLifecyclePresentation.locksProfileSelection(.stopping))
        XCTAssertTrue(MenuBarLifecyclePresentation.locksProfileSelection(.running))
        XCTAssertFalse(MenuBarLifecyclePresentation.locksProfileSelection(.stopped))
        XCTAssertEqual(MenuBarLifecyclePresentation.profileTitle(name: "Qwen", lifecycle: .stopping, activity: .idle, isSending: false), "Stopping… · Qwen")
    }

    func testChatAttachmentsRenderAsDelimitedLocalContext() {
        let attachment = PendingChatAttachment(name: "settings.json", path: "/tmp/settings.json", text: "{\"enabled\":true}")
        let rendered = ChatAttachmentPayload.render(prompt: "Explain this", attachments: [attachment])
        XCTAssertTrue(rendered.hasPrefix("Explain this"))
        XCTAssertTrue(rendered.contains("<attached_file name=\"settings.json\">"))
        XCTAssertTrue(rendered.contains("{\"enabled\":true}"))
    }

    func testChatAttachmentPayloadEscapesQuotedFilename() {
        let attachment = PendingChatAttachment(name: "a\"b.txt", path: "/tmp/a-b.txt", text: "hello")
        XCTAssertTrue(ChatAttachmentPayload.render(prompt: "", attachments: [attachment]).contains("name=\"a&quot;b.txt\""))
    }

    func testChatTailPolicyPausesAndResumesOnlyAtBottom() {
        XCTAssertFalse(ChatTailPolicy.shouldFollow(currentlyFollowing: true, bottomIsVisible: false, userScrolledUp: true))
        XCTAssertFalse(ChatTailPolicy.shouldFollow(currentlyFollowing: false, bottomIsVisible: false, userScrolledUp: false))
        XCTAssertTrue(ChatTailPolicy.shouldFollow(currentlyFollowing: false, bottomIsVisible: true, userScrolledUp: false))
        XCTAssertTrue(ChatTailPolicy.shouldFollow(currentlyFollowing: true, bottomIsVisible: false, userScrolledUp: false))
    }

    func testChatComposerHeightGrowsAndRemainsBounded() {
        XCTAssertEqual(ChatComposerSizing.height(for: "hello"), 44)
        XCTAssertGreaterThan(ChatComposerSizing.height(for: String(repeating: "x", count: 220)), 44)
        XCTAssertEqual(ChatComposerSizing.height(for: String(repeating: "line\n", count: 100)), 220)
    }

    func testChatColumnLayoutScalesWithViewportButStaysWithinBounds() {
        // Narrow window: floors at the previous fixed width, never narrower.
        XCTAssertEqual(ChatColumnLayout.maxWidth(forViewportWidth: 500), 760)
        // Mid-size window: tracks the viewport minus the side margin.
        XCTAssertEqual(ChatColumnLayout.maxWidth(forViewportWidth: 1000), 920)
        // Very wide window: caps at the maximum reading width instead of
        // stretching prose edge to edge.
        XCTAssertEqual(ChatColumnLayout.maxWidth(forViewportWidth: 2500), 1200)
    }

    func testGenericAPIAliasDoesNotLeakIntoChatDisplayName() {
        var profile = ServerProfile(name: "MLX · Qwen3 Coder 30B · 32 GB", alias: "default_model")
        XCTAssertEqual(profile.chatDisplayName, "MLX · Qwen3 Coder 30B · 32 GB")
        profile.alias = "qwen-coder"
        XCTAssertEqual(profile.chatDisplayName, "qwen-coder")
    }

    func testCompletedSnapshotReconciliationWaitsForStableCompleteFiles() {
        XCTAssertFalse(DownloadCompletionReconciler.shouldFinalize(progress: 1, snapshotComplete: true, hasIncompleteFiles: true, stableChecks: 10))
        XCTAssertFalse(DownloadCompletionReconciler.shouldFinalize(progress: 1, snapshotComplete: true, hasIncompleteFiles: false, stableChecks: 5))
        XCTAssertTrue(DownloadCompletionReconciler.shouldFinalize(progress: 1, snapshotComplete: true, hasIncompleteFiles: false, stableChecks: 6))
    }

    func testChatMarkdownParserExtractsFencedScripts() {
        let content = "Before\n```bash\necho hello\necho world\n```\nAfter"
        XCTAssertEqual(ChatMarkdownParser.segments(content), [
            .prose("Before"),
            .code(language: "bash", source: "echo hello\necho world"),
            .prose("After")
        ])
    }

    func testChatMarkdownParserExtractsTables() {
        let content = "Before\n\n| Feature | Status |\n| --- | --- |\n| Links | Done |\n| Stop | Done |\n\nAfter"
        XCTAssertEqual(ChatMarkdownParser.segments(content), [
            .prose("Before\n"),
            .table(headers: ["Feature", "Status"], rows: [["Links", "Done"], ["Stop", "Done"]]),
            .prose("\nAfter")
        ])
    }

    func testOuterMarkdownFenceRendersAsMarkdownDocument() {
        let content = "Here is Markdown:\n```markdown\n# Title\n\n| Name | Value |\n| --- | --- |\n| One | Two |\n\n```bash\necho hi\n```\n```"
        XCTAssertEqual(ChatMarkdownParser.segments(content), [
            .prose("Here is Markdown:"),
            .prose("# Title\n"),
            .table(headers: ["Name", "Value"], rows: [["One", "Two"]]),
            .code(language: "bash", source: "echo hi")
        ])
    }

    func testChatMarkdownParserKeepsUnclosedFenceAsCode() {
        XCTAssertEqual(ChatMarkdownParser.segments("```python\nprint('hello')"), [.code(language: "python", source: "print('hello')")])
    }

    func testChatMarkdownParserHidesThinkingAndRecoversUnfencedShellScript() {
        let response = "<think>draft notes\n```\nnot code</think>\nHere is the script:\n#!/usr/bin/env bash\nset -euo pipefail\necho hello"
        XCTAssertEqual(ChatMarkdownParser.segments(response), [
            .prose("Here is the script:"),
            .code(language: "bash", source: "#!/usr/bin/env bash\nset -euo pipefail\necho hello")
        ])
    }

    func testUnlabelledProseFenceDoesNotBecomeCode() {
        XCTAssertEqual(ChatMarkdownParser.segments("```\nLooks good. I will present it clearly."), [.prose("Looks good. I will present it clearly.")])
    }

    func testEndpointPortIsNeverLocaleGrouped() {
        XCTAssertEqual(EndpointFormatter.endpoint(address: "0.0.0.0", port: 8080), "http://0.0.0.0:8080")
    }

    func testRequiredHomebrewRuntimeDefinitions() {
        XCTAssertEqual(BrewDependency.required.map(\.id), ["llama.cpp", "mlx-lm", "uv"])
        XCTAssertEqual(BrewDependency.required.first?.executables, ["llama-server"])
        XCTAssertTrue(HomebrewRuntimeManager.candidateBrewPaths.contains("/opt/homebrew/bin/brew"))
        XCTAssertTrue(HomebrewRuntimeManager.candidateBrewPaths.contains("/usr/local/bin/brew"))
    }

    func testModelFormatsRequireAnInstalledCompatibleRuntime() {
        XCTAssertTrue(RuntimeAvailability.supports(.llamaCPP, installedExecutables: ["llama-server"]))
        XCTAssertFalse(RuntimeAvailability.supports(.mlxLM, installedExecutables: ["llama-server"]))
        XCTAssertTrue(RuntimeAvailability.supports(.mlxLM, installedExecutables: ["mlx_lm.server"]))
        XCTAssertTrue(RuntimeAvailability.supports(.vllmMLX, installedExecutables: ["vllm-mlx"]))
    }

    func testSingleMLXRepositoryUsesOneStandardVersionRow() {
        let siblings = [
            HFModelDetail.Sibling(rfilename: "config.json", size: 100, lfs: nil),
            HFModelDetail.Sibling(rfilename: "model.safetensors", size: nil, lfs: .init(size: 900, sha256: nil))
        ]
        let entries = ModelVersionInventory.entries(modelID: "mlx-community/Example-4bit", backend: .mlxLM, siblings: siblings)
        XCTAssertEqual(entries, [ModelVersionEntry(name: "Example-4bit", size: 1_000)])
    }

    func testGGUFRepositoryUsesOneStandardVersionRowPerWeight() {
        let siblings = [
            HFModelDetail.Sibling(rfilename: "README.md", size: 20, lfs: nil),
            HFModelDetail.Sibling(rfilename: "model-Q8_0.gguf", size: 800, lfs: nil),
            HFModelDetail.Sibling(rfilename: "model-Q4_K_M.gguf", size: 400, lfs: nil)
        ]
        XCTAssertEqual(
            ModelVersionInventory.entries(modelID: "owner/model", backend: .llamaCPP, siblings: siblings),
            [ModelVersionEntry(name: "model-Q4_K_M.gguf", size: 400), ModelVersionEntry(name: "model-Q8_0.gguf", size: 800)]
        )
    }

    func testLibraryDownloadCannotAssignAProfileWithoutExplicitOwnership() {
        let profileID = UUID()
        XCTAssertFalse(DownloadProfileOwnership.permitsAssignment(to: profileID, ownerProfileID: nil))
        XCTAssertFalse(DownloadProfileOwnership.permitsAssignment(to: profileID, ownerProfileID: UUID()))
        XCTAssertTrue(DownloadProfileOwnership.permitsAssignment(to: profileID, ownerProfileID: profileID))
    }

    func testResumeDataRoundTripAndRemoval() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("model.gguf")
        let data = Data("resume-state".utf8)

        try DownloadResumeStore.save(data, for: destination)
        XCTAssertEqual(DownloadResumeStore.load(for: destination), data)
        XCTAssertTrue(FileManager.default.fileExists(atPath: DownloadResumeStore.url(for: destination).path))

        DownloadResumeStore.remove(for: destination)
        XCTAssertNil(DownloadResumeStore.load(for: destination))
    }

    func testMLXSnapshotResolverOnlyReturnsCompleteSnapshot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshots = root.appendingPathComponent("models--mlx-community--Example/snapshots", isDirectory: true)
        let incomplete = snapshots.appendingPathComponent("incomplete", isDirectory: true)
        let complete = snapshots.appendingPathComponent("complete", isDirectory: true)
        try FileManager.default.createDirectory(at: incomplete, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: complete, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: incomplete.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(to: complete.appendingPathComponent("config.json"))
        try Data([0x01]).write(to: complete.appendingPathComponent("model.safetensors"))

        XCTAssertEqual(
            MLXSnapshotResolver.resolve(modelID: "mlx-community/Example", root: root)?.resolvingSymlinksInPath().path,
            complete.resolvingSymlinksInPath().path
        )
        XCTAssertNil(MLXSnapshotResolver.resolve(modelID: complete.path, root: root))
    }

    func testMetadataManifestRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = ModelManifestEntry(sourceModelID: "owner/model", revision: "abc123", filename: "model-Q5_K_M.gguf", checksumSHA256: "deadbeef", format: "GGUF", localPath: root.appendingPathComponent("model-Q5_K_M.gguf").path, size: 42, downloadedAt: Date(timeIntervalSince1970: 1234))

        try ModelMetadataManifest.save([entry], to: root)
        XCTAssertEqual(ModelMetadataManifest.load(from: root), [entry])
    }

    func testModelProvenanceParsingAndLinks() {
        XCTAssertEqual(ModelProvenance.license(from: ["gguf", "license:apache-2.0"]), "apache-2.0")
        XCTAssertEqual(ModelProvenance.quantization(from: "Qwen_Qwen3.6-35B-A3B-Q5_K_M.gguf"), "Q5_K_M")
        XCTAssertEqual(ModelProvenance.repositoryURL(for: "bartowski/example")?.absoluteString, "https://huggingface.co/bartowski/example")
        XCTAssertNil(ModelProvenance.repositoryURL(for: "local-file"))
    }

    @MainActor
    func testPersistentDownloadJobRoundTrip() throws {
        let owner = UUID()
        let job = AppStore.DownloadJob(id: "gguf:owner/model:file.gguf", modelID: "owner/model", file: "file.gguf", phase: "Paused", progress: 0.25, received: 25, total: 100, speed: 0, isPaused: true, backend: .llamaCPP, destination: "/tmp/file.gguf", ownerProfileID: owner)
        let data = try JSONEncoder().encode(job)
        XCTAssertEqual(try JSONDecoder().decode(AppStore.DownloadJob.self, from: data).ownerProfileID, owner)
        XCTAssertEqual(try JSONDecoder().decode(AppStore.DownloadJob.self, from: data).destination, "/tmp/file.gguf")
    }

    func testHardwareAdvisorClassifiesMemoryAndDiskPressure() {
        let roomy = MacHardwareProfile(chip: "Test", physicalMemory: 64_000_000_000, availableDisk: 500_000_000_000)
        XCTAssertEqual(ModelHardwareAdvisor.assess(fileSize: 8_000_000_000, filename: "Model-7B-Q4_K_M.gguf", contextSize: 32_768, hardware: roomy, alreadyDownloaded: false).fit, .comfortable)
        let constrained = MacHardwareProfile(chip: "Test", physicalMemory: 16_000_000_000, availableDisk: 500_000_000_000)
        XCTAssertEqual(ModelHardwareAdvisor.assess(fileSize: 15_000_000_000, filename: "Model-30B-Q4_K_M.gguf", contextSize: 65_536, hardware: constrained, alreadyDownloaded: false).fit, .unsupported)
        let lowDisk = MacHardwareProfile(chip: "Test", physicalMemory: 64_000_000_000, availableDisk: 5_000_000_000)
        XCTAssertEqual(ModelHardwareAdvisor.assess(fileSize: 8_000_000_000, filename: "Model-7B-Q4_K_M.gguf", contextSize: 32_768, hardware: lowDisk, alreadyDownloaded: false).fit, .unsupported)
    }

    func testRuntimeTelemetryParser() {
        let log = """
        I slot launch_slot_: id 0 | task 871 | processing task
        I slot print_timing: id 0 | task 871 | prompt processing, n_tokens = 8192, progress = 0.75
        I slot print_timing: id 0 | task 871 | n_gen = 189, tg = 62.66 t/s, tg_3s = 62.99 t/s
        """
        let health = RuntimeTelemetryParser.parse(log, contextLimit: 32_768)
        XCTAssertEqual(health.activeRequests, 1)
        XCTAssertEqual(health.contextTokens, 8_192)
        XCTAssertEqual(health.tokensPerSecond ?? 0, 62.66, accuracy: 0.001)
        XCTAssertEqual(health.loadingProgress ?? 0, 0.75, accuracy: 0.001)
    }

    // MARK: - RuntimeHealth.contextFraction / contextUsageLevel

    func testContextFractionIsZeroWithoutAKnownLimit() {
        XCTAssertEqual(RuntimeHealth(contextTokens: 500, contextLimit: 0).contextFraction, 0, "No limit parsed yet — nothing to divide by")
    }

    func testContextFractionDividesTokensByLimit() {
        XCTAssertEqual(RuntimeHealth(contextTokens: 8_192, contextLimit: 32_768).contextFraction, 0.25, accuracy: 0.0001)
    }

    func testContextFractionNeverExceedsOneEvenIfTokensOverrunTheLimit() {
        // Can happen transiently: llama.cpp logs the raw prompt size
        // before it applies its own context-shift truncation.
        XCTAssertEqual(RuntimeHealth(contextTokens: 40_000, contextLimit: 32_768).contextFraction, 1, accuracy: 0.0001)
    }

    func testContextUsageLevelBands() {
        XCTAssertEqual(RuntimeHealth(contextTokens: 10_000, contextLimit: 32_768).contextUsageLevel, .normal)
        XCTAssertEqual(RuntimeHealth(contextTokens: 25_000, contextLimit: 32_768).contextUsageLevel, .elevated, "75% and up is elevated")
        XCTAssertEqual(RuntimeHealth(contextTokens: 30_500, contextLimit: 32_768).contextUsageLevel, .critical, "92% and up is critical")
    }

    func testContextUsageLevelIsNormalWithoutAKnownLimit() {
        XCTAssertEqual(RuntimeHealth(contextTokens: 999_999, contextLimit: 0).contextUsageLevel, .normal, "Nothing to warn about until a limit is actually known")
    }

    func testGGUFPreflightRejectsInvalidHeader() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gguf")
        try Data(repeating: 0x58, count: 24).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let hardware = MacHardwareProfile(chip: "Test", physicalMemory: 64_000_000_000, availableDisk: 100_000_000_000)
        let report = ModelCompatibilityValidator.inspectGGUF(at: file, contextSize: 4_096, hardware: hardware)
        XCTAssertFalse(report.isCompatible)
        XCTAssertTrue(report.errors.contains(where: { $0.contains("not a valid GGUF") }))
    }

    func testMultimodalProjectorPicksSiblingProjectorFile() {
        XCTAssertEqual(
            MultimodalProjector.projectorFilename(forModel: "qwen3-vl-8b.gguf", siblingFilenames: ["qwen3-vl-8b.gguf", "mmproj-qwen3-vl-8b-f16.gguf", "README.md"]),
            "mmproj-qwen3-vl-8b-f16.gguf"
        )
        // Not fooled by a non-GGUF or by the model's own filename even if
        // it happened to contain "mmproj".
        XCTAssertNil(MultimodalProjector.projectorFilename(forModel: "model.gguf", siblingFilenames: ["model.gguf", "mmproj-notes.txt"]))
        XCTAssertNil(MultimodalProjector.projectorFilename(forModel: "mmproj-model.gguf", siblingFilenames: ["mmproj-model.gguf"]))
    }

    func testHasProjectorSiblingDetectsAnMmprojFileRegardlessOfHuggingFaceTags() {
        // The whole point of this check: it looks at the repo's actual
        // files, not any pipeline_tag Hugging Face happens to carry --
        // a GGUF requant repo tagged just "text-generation" still counts
        // if it ships an mmproj file alongside the model.
        XCTAssertTrue(MultimodalProjector.hasProjectorSibling(among: ["Qwen3VL-32B-Instruct-Q4_K_M.gguf", "mmproj-Qwen3VL-32B-Instruct-Q8_0.gguf", "README.md"]))
        XCTAssertFalse(MultimodalProjector.hasProjectorSibling(among: ["Qwen3-32B-Q4_K_M.gguf", "README.md"]))
        XCTAssertFalse(MultimodalProjector.hasProjectorSibling(among: ["mmproj-notes.txt"]))
    }

    func testMultimodalProjectorPicksDeterministicallyWhenMultipleCandidatesExist() {
        XCTAssertEqual(
            MultimodalProjector.projectorFilename(forModel: "model.gguf", siblingFilenames: ["model.gguf", "mmproj-f32.gguf", "mmproj-f16.gguf"]),
            "mmproj-f16.gguf" // alphabetically first, not enumeration order
        )
    }

    func testMultimodalProjectorPathFindsSiblingOnDisk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("qwen3-vl.gguf")
        let projector = root.appendingPathComponent("mmproj-qwen3-vl.gguf")
        try Data([0]).write(to: model)
        try Data([0]).write(to: projector)
        XCTAssertEqual(MultimodalProjector.path(forModelPath: model.path), projector.path)
        XCTAssertNil(MultimodalProjector.path(forModelPath: root.appendingPathComponent("nonexistent.gguf").path))
    }

    func testMultimodalProjectorPathStillFindsItsProjectorWithOtherModelsInTheSameFolder() throws {
        // Matching is directory-scoped (not restricted to files that
        // literally reference each other) but IS family-tied: a
        // generically-named projector like "mmproj-f16.gguf" still
        // matches any model (see
        // testMultimodalProjectorPicksDeterministicallyWhenMultipleCandidatesExist),
        // but here the projector's own name carries the same family
        // tokens as its model ("qwen3-vl"), so an unrelated second GGUF
        // file sitting in the same flat model folder must not interfere
        // with that pairing.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let visionModel = root.appendingPathComponent("qwen3-vl.gguf")
        let projector = root.appendingPathComponent("mmproj-qwen3-vl.gguf")
        let textOnlyModel = root.appendingPathComponent("mistral-text.gguf")
        try Data([0]).write(to: visionModel)
        try Data([0]).write(to: projector)
        try Data([0]).write(to: textOnlyModel)
        XCTAssertEqual(MultimodalProjector.path(forModelPath: visionModel.path), projector.path)
    }

    func testMultimodalProjectorRefusesAnUnrelatedModelFamilysProjector() throws {
        // Regression test for a real crash: once this app's preset
        // auto-download (see ProfilePreset.mmprojFilename) fetched
        // Qwen3-VL 32B's real mmproj file into the shared, flat
        // ~/ai-models folder, starting a completely unrelated profile
        // -- plain Qwen 3.6 35B, a text-only model that was already
        // sitting in that same folder -- also got that Qwen3-VL 32B
        // projector wired up as its --mmproj, because the original
        // matching rule was "any mmproj file in the directory". That
        // mismatched a 2048-dim text model against a 20480-dim
        // projector and llama-server aborted outright (GGML_ASSERT)
        // instead of just declining images. Family-token matching (see
        // MultimodalProjector.projectorFilename) must reject this pairing.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let textOnlyModel = root.appendingPathComponent("Qwen_Qwen3.6-35B-A3B-Q5_K_M.gguf")
        let unrelatedProjector = root.appendingPathComponent("mmproj-Qwen3VL-32B-Instruct-F16.gguf")
        let visionModel = root.appendingPathComponent("Qwen3VL-32B-Instruct-Q4_K_M.gguf")
        try Data([0]).write(to: textOnlyModel)
        try Data([0]).write(to: unrelatedProjector)
        try Data([0]).write(to: visionModel)
        XCTAssertNil(MultimodalProjector.path(forModelPath: textOnlyModel.path), "a text-only model must never be wired up with an unrelated model family's projector")
        XCTAssertEqual(MultimodalProjector.path(forModelPath: visionModel.path), unrelatedProjector.path, "the vision model this projector actually belongs to must still find it")
    }

    func testMultimodalProjectorRejectsSameFamilyDifferentSizeProjector() {
        // Same model family, different size tier -- Qwen3-VL 8B must not
        // pick up the 32B projector (or vice versa) even though both
        // names share "qwen3vl"/"instruct".
        XCTAssertNil(MultimodalProjector.projectorFilename(
            forModel: "Qwen3VL-8B-Instruct-Q4_K_M.gguf",
            siblingFilenames: ["Qwen3VL-8B-Instruct-Q4_K_M.gguf", "mmproj-Qwen3VL-32B-Instruct-F16.gguf"]
        ))
    }

    func testOpenCodeConfigSyncBuildsTheInferenceBarProviderEntry() throws {
        let profiles = [
            OpenCodeConfigSync.ProfileEntry(alias: "gemma-4-8b", name: "Gemma 4 8B (Coding)", contextSize: 32768, maximumOutputTokens: 8192)
        ]
        let merged = OpenCodeConfigSync.mergedConfig(existing: [:], baseURL: "http://127.0.0.1:8080/v1", apiKey: "local", profiles: profiles)
        XCTAssertEqual(merged["$schema"] as? String, "https://opencode.ai/config.json")
        let providers = try XCTUnwrap(merged["provider"] as? [String: Any])
        let inferencebar = try XCTUnwrap(providers[OpenCodeConfigSync.providerID] as? [String: Any])
        XCTAssertEqual(inferencebar["npm"] as? String, "@ai-sdk/openai-compatible")
        let options = try XCTUnwrap(inferencebar["options"] as? [String: Any])
        XCTAssertEqual(options["baseURL"] as? String, "http://127.0.0.1:8080/v1")
        XCTAssertEqual(options["apiKey"] as? String, "local")
        let models = try XCTUnwrap(inferencebar["models"] as? [String: Any])
        let model = try XCTUnwrap(models["gemma-4-8b"] as? [String: Any])
        XCTAssertEqual(model["name"] as? String, "Gemma 4 8B (Coding)")
        let limit = try XCTUnwrap(model["limit"] as? [String: Any])
        XCTAssertEqual(limit["context"] as? Int, 32768)
        XCTAssertEqual(limit["output"] as? Int, 8192)
    }

    func testOpenCodeConfigSyncPreservesUnrelatedExistingConfigAndOverwritesOnlyItsOwnProvider() throws {
        let existing: [String: Any] = [
            "$schema": "https://opencode.ai/config.json",
            "theme": "dark",
            "provider": [
                "anthropic": ["npm": "@ai-sdk/anthropic"],
                OpenCodeConfigSync.providerID: ["npm": "stale-entry-from-before"]
            ]
        ]
        let profiles = [OpenCodeConfigSync.ProfileEntry(alias: "qwen3.6-27b", name: "Qwen 3.6 27B", contextSize: 65536, maximumOutputTokens: 4096)]
        let merged = OpenCodeConfigSync.mergedConfig(existing: existing, baseURL: "http://127.0.0.1:8080/v1", apiKey: "{env:INFERENCE_API_KEY}", profiles: profiles)
        XCTAssertEqual(merged["theme"] as? String, "dark")
        let providers = try XCTUnwrap(merged["provider"] as? [String: Any])
        XCTAssertNotNil(providers["anthropic"], "an unrelated provider a person configured by hand must survive the merge")
        let inferencebar = try XCTUnwrap(providers[OpenCodeConfigSync.providerID] as? [String: Any])
        XCTAssertEqual(inferencebar["npm"] as? String, "@ai-sdk/openai-compatible", "re-syncing must overwrite the stale inferencebar entry, not merge into it")
        let options = try XCTUnwrap(inferencebar["options"] as? [String: Any])
        XCTAssertEqual(options["apiKey"] as? String, "{env:INFERENCE_API_KEY}")
    }

    func testOpenCodeConfigSyncSetsTopLevelModelFieldForTheDefaultCodingProfile() throws {
        let profiles = [
            OpenCodeConfigSync.ProfileEntry(alias: "gemma-4-8b", name: "Gemma 4 8B", contextSize: 32768, maximumOutputTokens: 8192),
            OpenCodeConfigSync.ProfileEntry(alias: "qwen3.6-35b", name: "Qwen 3.6 35B", contextSize: 131072, maximumOutputTokens: 8192)
        ]
        let merged = OpenCodeConfigSync.mergedConfig(existing: [:], baseURL: "http://127.0.0.1:8080/v1", apiKey: "local", profiles: profiles, defaultModelAlias: "qwen3.6-35b")
        XCTAssertEqual(merged["model"] as? String, "inferencebar/qwen3.6-35b")
    }

    func testOpenCodeConfigSyncClearsItsOwnStaleDefaultButLeavesAnotherProvidersModelAlone() {
        // No defaultModelAlias this time (the person cleared their default
        // coding profile) -- a "model" this sync previously set (the
        // "inferencebar/" prefix) must be removed, but a "model" pointing
        // at some other provider is someone else's setting, not ours to
        // touch.
        let ourStaleDefault = OpenCodeConfigSync.mergedConfig(
            existing: ["model": "inferencebar/old-alias"],
            baseURL: "http://127.0.0.1:8080/v1", apiKey: "local",
            profiles: [OpenCodeConfigSync.ProfileEntry(alias: "gemma-4-8b", name: "Gemma 4 8B", contextSize: 32768, maximumOutputTokens: 8192)]
        )
        XCTAssertNil(ourStaleDefault["model"])

        let someoneElsesDefault = OpenCodeConfigSync.mergedConfig(
            existing: ["model": "anthropic/claude-sonnet-4-5"],
            baseURL: "http://127.0.0.1:8080/v1", apiKey: "local",
            profiles: [OpenCodeConfigSync.ProfileEntry(alias: "gemma-4-8b", name: "Gemma 4 8B", contextSize: 32768, maximumOutputTokens: 8192)]
        )
        XCTAssertEqual(someoneElsesDefault["model"] as? String, "anthropic/claude-sonnet-4-5")
    }

    func testChatImageAttachmentPolicyBlocksLlamaCPPWithoutAProjector() {
        XCTAssertTrue(ChatImageAttachmentPolicy.blocksImageAttachment(runtime: .llamaCPP, hasProjector: false))
        XCTAssertFalse(ChatImageAttachmentPolicy.blocksImageAttachment(runtime: .llamaCPP, hasProjector: true))
    }

    func testChatImageAttachmentPolicyNeverBlocksMLXOrVLLM() {
        // InferenceBar doesn't wire up --mmproj for these backends at all,
        // so "no projector detected" isn't a meaningful signal for them --
        // they may still support vision input on their own.
        XCTAssertFalse(ChatImageAttachmentPolicy.blocksImageAttachment(runtime: .mlxLM, hasProjector: false))
        XCTAssertFalse(ChatImageAttachmentPolicy.blocksImageAttachment(runtime: .vllmMLX, hasProjector: false))
    }

    func testChatImageAttachmentPolicyLeavesSmallImagesUnchanged() {
        let target = ChatImageAttachmentPolicy.targetSize(width: 800, height: 600)
        XCTAssertEqual(target.width, 800)
        XCTAssertEqual(target.height, 600)
    }

    func testChatImageAttachmentPolicyDownscalesPreservingAspectRatio() {
        let target = ChatImageAttachmentPolicy.targetSize(width: 4032, height: 3024)
        XCTAssertEqual(target.width, ChatImageAttachmentPolicy.maximumLongEdge)
        // 3024/4032 == 0.75, preserved within a rounding pixel.
        XCTAssertEqual(Double(target.height) / Double(target.width), 0.75, accuracy: 0.01)
    }

    func testChatImageAttachmentPolicyDownscalesTallImagesByHeight() {
        let target = ChatImageAttachmentPolicy.targetSize(width: 1000, height: 5000)
        XCTAssertEqual(target.height, ChatImageAttachmentPolicy.maximumLongEdge)
        // 1000/5000 == 0.2; 1568 * 0.2 == 313.6, rounded to 314.
        XCTAssertEqual(target.width, 314)
    }

    func testChatImageStorageKeepsOnlyReferencedFilenames() {
        let orphaned = ChatImageStorage.orphanedFilenames(
            referenced: ["a.png", "b.jpg"],
            onDisk: ["a.png", "b.jpg", "c.png"]
        )
        XCTAssertEqual(orphaned, ["c.png"])
    }

    func testChatImageStorageOrphansEverythingWhenNothingIsReferenced() {
        XCTAssertEqual(ChatImageStorage.orphanedFilenames(referenced: [], onDisk: ["a.png"]), ["a.png"])
    }

    func testChatMessageDecodesWithoutImageAttachmentsKeyForBackwardCompatibility() throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000002","role":"user","content":"Hello"}"#.data(using: .utf8)!
        let message = try JSONDecoder().decode(ChatMessage.self, from: json)
        XCTAssertEqual(message.content, "Hello")
        XCTAssertTrue(message.imageAttachments.isEmpty)
    }

    func testChatMessageRoundTripsImageAttachments() throws {
        let original = ChatMessage(role: "user", content: "See attached", imageAttachments: [ChatImageAttachment(filename: "abc.png", mimeType: "image/png")])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
        XCTAssertEqual(decoded.imageAttachments, original.imageAttachments)
    }

    func testQwen35MoEArchitectureIsSupported() {
        XCTAssertTrue(ModelCompatibilityValidator.supportsGGUFArchitecture("qwen35moe"))
        XCTAssertTrue(ModelCompatibilityValidator.supportsGGUFArchitecture(" qwen35_moe\n"))
        XCTAssertTrue(ModelCompatibilityValidator.supportsGGUFArchitecture("qwen3_moe"))
        XCTAssertFalse(ModelCompatibilityValidator.supportsGGUFArchitecture("unknown_future_arch"))
    }

    func testMLXPreflightReportsMissingWeightsAndWarnsOnUnrecognizedArchitecture() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"model_type":"brand_new_arch"}"#.utf8).write(to: root.appendingPathComponent("config.json"))
        let report = ModelCompatibilityValidator.inspectMLX(at: root)
        // An unrecognized architecture is advisory only (same reasoning as
        // the GGUF preflight: this list goes stale faster than mlx-lm
        // itself does), so it must not be what makes this incompatible --
        // the missing .safetensors weights are the real, hard error.
        XCTAssertFalse(report.isCompatible)
        XCTAssertTrue(report.warnings.contains(where: { $0.contains("brand_new_arch") }))
        XCTAssertTrue(report.errors.contains(where: { $0.contains("safetensors") }))
    }

    func testPresetAvailabilityRequiresDownloadedModel() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("preset-model.gguf")
        let preset = ProfilePreset(id: "test", title: "Test", hardware: "Test Mac", summary: "", profile: ServerProfile(modelPath: model.path))
        XCTAssertFalse(preset.isAvailable(modelRoot: root))
        try Data([0]).write(to: model)
        XCTAssertTrue(preset.isAvailable(modelRoot: root))
    }

    func testCuratedMLXModelsHaveHardwarePresets() {
        let expected = [
            "mlx-community/gpt-oss-20b-MXFP4-Q4",
            "mlx-community/gpt-oss-20b-MXFP4-Q8",
            "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
            "mlx-community/Qwen3-Coder-30B-A3B-Instruct-8bit",
            "mlx-community/Qwen3.6-35B-A3B-4bit",
            "mlx-community/Qwen3.6-35B-A3B-6bit",
            "mlx-community/Qwen3.6-35B-A3B-8bit",
            "mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit",
            "mlx-community/Qwen3.6-27B-4bit"
        ]
        let presetModels = Set(ProfilePreset.all.map(\.profile.modelPath))
        XCTAssertTrue(Set(expected).isSubset(of: Set(ModelCategory.recommendedAppleSilicon.recommendedModelIDs)))
        XCTAssertTrue(Set(expected).isSubset(of: presetModels))
        XCTAssertTrue(ModelCategory.recommendedAppleSilicon.recommendedModelIDs.contains("ggml-org/Qwen3.6-27B-GGUF"))
        XCTAssertTrue(ModelCategory.recommendedAppleSilicon.recommendedModelIDs.contains("DhruvalLabs/GLM-4.7-Flash-GGUF"))
        XCTAssertTrue(presetModels.contains(where: { $0.hasSuffix("Qwen3.6-27B-Q4_K_M.gguf") }))
        XCTAssertTrue(presetModels.contains(where: { $0.hasSuffix("GLM-4.7-Flash-Q4_K_M.gguf") }))
        XCTAssertGreaterThanOrEqual(ProfilePreset.all.filter { $0.hardware.contains("iMac M4") && $0.hardware.contains("24 GB") }.count, 3)
        XCTAssertTrue(ProfilePreset.all.contains(where: { $0.hardware.contains("Mac mini M4 Pro") }))
        XCTAssertTrue(ProfilePreset.all.contains(where: { $0.hardware.contains("Mac Studio") }))
    }

    func testHomeAutomationCurationAndPresets() {
        let lightweightModels = ["mlx-community/Qwen3-4B-4bit", "mlx-community/Qwen3.5-9B-MLX-4bit", "mlx-community/Qwen3-VL-8B-Instruct-4bit"]
        XCTAssertTrue(Set(lightweightModels).isSubset(of: Set(ModelCategory.recommendedHomeAutomation.recommendedModelIDs)))
        for model in lightweightModels {
            let preset = ProfilePreset.all.first(where: { $0.profile.modelPath == model })
            XCTAssertNotNil(preset)
            let minimumContext = model == "mlx-community/Qwen3-4B-4bit" ? 8_192 : 16_384
            XCTAssertGreaterThanOrEqual(preset?.profile.contextSize ?? 0, minimumContext)
            XCTAssertEqual(preset?.profile.reasoning, "")
        }
    }

    func testVisionChatCategoryTargetsImageTextPipelineWithoutNarrowingChatPicks() {
        // Only the new vision-specific category asks for image-capable
        // models; the original "Chat Picks" category stays exactly as
        // broad as before (no pipelineTag), so it keeps recommending its
        // existing text-only picks too.
        XCTAssertEqual(ModelCategory.recommendedVisionChat.pipelineTag, "image-text-to-text")
        XCTAssertNil(ModelCategory.recommendedChat.pipelineTag)
    }

    func testDownloadSourceModelIDResolvesGGUFAndMLXPresetsDifferently() {
        // GGUF: only presets with a confirmed source repo can
        // auto-download -- an unconfirmed one deliberately stays nil
        // rather than guessing at a repo/filename that might not match.
        let confirmedGGUF = ProfilePreset.all.first(where: { $0.id == "gguf-qwen3-vl-32b-q4-48" })
        XCTAssertEqual(confirmedGGUF?.downloadSourceModelID, "Qwen/Qwen3-VL-32B-Instruct-GGUF")
        XCTAssertEqual(confirmedGGUF?.expectedGGUFFilename, "Qwen3VL-32B-Instruct-Q4_K_M.gguf")
        // Llama 3.3 70B's Q6_K/Q8_0 quants are the one case that stays
        // unconfirmed on purpose: every quantizer ships them pre-split
        // into two files (over Hugging Face's single-file comfort
        // limit), and download(file:from:to:ownerProfileID:) only
        // fetches one flat filename, so it can't auto-download either
        // half.
        let splitFileGGUF = ProfilePreset.all.first(where: { $0.id == "llama70-128-ultra-pro" })
        XCTAssertNotNil(splitFileGGUF)
        XCTAssertNil(splitFileGGUF?.ggufSourceModelID)
        XCTAssertNil(splitFileGGUF?.downloadSourceModelID)
        XCTAssertEqual(splitFileGGUF?.expectedGGUFFilename, "Llama-3.3-70B-Instruct-Q6_K-00001-of-00002.gguf")
        // MLX/vLLM-MLX: modelPath already *is* the Hugging Face repo ID,
        // so downloadSourceModelID always resolves without needing its
        // own ggufSourceModelID.
        let mlxPreset = ProfilePreset.all.first(where: { $0.id == "mlx-qwen36-m3max-48" })
        XCTAssertEqual(mlxPreset?.downloadSourceModelID, "mlx-community/Qwen3.6-35B-A3B-4bit")
        XCTAssertNil(mlxPreset?.expectedGGUFFilename)
    }

    func testFormerlyUnconfirmedGGUFPresetsNowResolveAConfirmedSourceRepo() {
        // These were left unconfirmed in an earlier pass ("needs a manual
        // download" in the Profiles menu); each now has a verified
        // Hugging Face repo whose filename exactly matches this preset's
        // modelPath, so "Add all presets" can fetch every one of them.
        let expectations: [(id: String, sourceModelID: String, filename: String)] = [
            ("gemma4-8b-opencode", "bartowski/google_gemma-4-E4B-it-GGUF", "google_gemma-4-E4B-it-Q5_K_M.gguf"),
            ("gemma4-26b-opencode", "unsloth/gemma-4-26B-A4B-it-GGUF", "gemma-4-26B-A4B-it-UD-Q4_K_M.gguf"),
            ("mistral-small31-32", "bartowski/mistralai_Mistral-Small-3.1-24B-Instruct-2503-GGUF", "mistralai_Mistral-Small-3.1-24B-Instruct-2503-Q4_K_M.gguf"),
            ("qwen14-24-imac-mini-pro", "bartowski/Qwen_Qwen3-14B-GGUF", "Qwen_Qwen3-14B-Q4_K_M.gguf"),
            ("qwen8-16", "bartowski/Qwen_Qwen3-8B-GGUF", "Qwen_Qwen3-8B-Q4_K_M.gguf"),
            ("gemma12-24", "bartowski/google_gemma-3-12b-it-GGUF", "google_gemma-3-12b-it-Q4_K_M.gguf"),
            ("qwen30-36", "bartowski/Qwen_Qwen3-30B-A3B-GGUF", "Qwen_Qwen3-30B-A3B-Q4_K_M.gguf"),
            ("llama70-64", "bartowski/Llama-3.3-70B-Instruct-GGUF", "Llama-3.3-70B-Instruct-Q4_K_M.gguf"),
            ("qwen32-64-studio", "bartowski/Qwen_Qwen3-32B-GGUF", "Qwen_Qwen3-32B-Q6_K.gguf"),
        ]
        for expectation in expectations {
            let preset = ProfilePreset.all.first(where: { $0.id == expectation.id })
            XCTAssertNotNil(preset, "missing preset \(expectation.id)")
            XCTAssertEqual(preset?.downloadSourceModelID, expectation.sourceModelID, "wrong source repo for \(expectation.id)")
            XCTAssertEqual(preset?.expectedGGUFFilename, expectation.filename, "wrong filename for \(expectation.id)")
        }
    }

    func testVisionChatCurationAndPresets() {
        let expectedModelIDs = ["Qwen/Qwen3-VL-8B-Instruct-GGUF", "Qwen/Qwen3-VL-32B-Instruct-GGUF", "mlx-community/Qwen3-VL-8B-Instruct-4bit"]
        XCTAssertTrue(Set(expectedModelIDs).isSubset(of: Set(ModelCategory.recommendedVisionChat.recommendedModelIDs)))
        let presetModels = Set(ProfilePreset.all.map(\.profile.modelPath))
        XCTAssertTrue(presetModels.contains(where: { $0.hasSuffix("Qwen3VL-8B-Instruct-Q4_K_M.gguf") }))
        XCTAssertTrue(presetModels.contains(where: { $0.hasSuffix("Qwen3VL-8B-Instruct-Q8_0.gguf") }))
        XCTAssertTrue(presetModels.contains(where: { $0.hasSuffix("Qwen3VL-32B-Instruct-Q4_K_M.gguf") }))
        XCTAssertTrue(ProfilePreset.all.contains(where: { $0.profile.modelPath.hasSuffix("Qwen3VL-32B-Instruct-Q4_K_M.gguf") && $0.hardware.contains("48 GB") }))
    }

    func testReferenceMemoryTierPresets() {
        let tiers = Set(ProfilePreset.all.map(\.hardware))
        XCTAssertTrue(tiers.contains(where: { $0.contains("8 GB") }))
        XCTAssertTrue(tiers.contains(where: { $0.contains("128 GB") }))
        XCTAssertTrue(tiers.contains(where: { $0.contains("192 GB") }))
        XCTAssertTrue(ProfilePreset.all.contains(where: { $0.profile.modelPath == "mlx-community/Qwen3-235B-A22B-4bit" && $0.profile.contextSize == 40_960 }))
    }

    func testDownloadedCatalogFiltersModelsByRuntime() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([0]).write(to: root.appendingPathComponent("local.gguf"))
        let snapshot = root.appendingPathComponent("models--owner--mlx-model/snapshots/revision", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: snapshot.appendingPathComponent("config.json"))
        try Data([1]).write(to: snapshot.appendingPathComponent("model.safetensors"))
        let models = DownloadedModelCatalog.scan(root: root)
        XCTAssertEqual(models.filter { $0.supports(.llamaCPP) }.map(\.format), [.gguf])
        XCTAssertEqual(models.filter { $0.supports(.mlxLM) }.map(\.format), [.mlx])
        XCTAssertEqual(models.filter { $0.supports(.vllmMLX) }.map(\.format), [.mlx])
    }

    func testProfileStatusPrioritizesFailedThenLifecycleThenDownloadThenMissingModel() {
        // Failed wins over everything else, even if it's somehow also
        // flagged as the running/downloading profile.
        XCTAssertEqual(
            ProfileStatus.status(isFailed: true, isRunningProfile: true, serverLifecycleIsRunning: true, isDownloadingThisProfile: true, modelAvailable: false),
            .failed
        )
        // Running profile: the server's own lifecycle decides running vs. still starting.
        XCTAssertEqual(
            ProfileStatus.status(isFailed: false, isRunningProfile: true, serverLifecycleIsRunning: true, isDownloadingThisProfile: false, modelAvailable: true),
            .running
        )
        XCTAssertEqual(
            ProfileStatus.status(isFailed: false, isRunningProfile: true, serverLifecycleIsRunning: false, isDownloadingThisProfile: false, modelAvailable: true),
            .starting
        )
        // Not running: an in-flight download for this profile takes priority over "missing".
        XCTAssertEqual(
            ProfileStatus.status(isFailed: false, isRunningProfile: false, serverLifecycleIsRunning: false, isDownloadingThisProfile: true, modelAvailable: false),
            .downloading
        )
        // Not running, not downloading, no model on disk yet.
        XCTAssertEqual(
            ProfileStatus.status(isFailed: false, isRunningProfile: false, serverLifecycleIsRunning: false, isDownloadingThisProfile: false, modelAvailable: false),
            .modelMissing
        )
        // Idle and ready to start.
        XCTAssertEqual(
            ProfileStatus.status(isFailed: false, isRunningProfile: false, serverLifecycleIsRunning: false, isDownloadingThisProfile: false, modelAvailable: true),
            .ready
        )
    }

    func testDownloadMenuBarSummaryCoversResolvingInProgressAndNoTotalYet() {
        // Still resolving metadata -- no byte counts yet at all.
        XCTAssertEqual(
            DownloadMenuBarPresentation.summary(modelName: "bartowski/Qwen_Qwen3-14B-GGUF", isResolving: true, status: "", progress: 0, totalBytes: 0, bytesPerSecond: 0),
            "Resolving Qwen_Qwen3-14B-GGUF…"
        )
        XCTAssertEqual(
            DownloadMenuBarPresentation.summary(modelName: "", isResolving: true, status: "", progress: 0, totalBytes: 0, bytesPerSecond: 0),
            "Resolving download…"
        )
        // Resolved but the total byte count hasn't arrived yet -- falls
        // back to whatever status string the download loop is reporting.
        XCTAssertEqual(
            DownloadMenuBarPresentation.summary(modelName: "bartowski/Qwen_Qwen3-14B-GGUF", isResolving: false, status: "Preparing…", progress: 0, totalBytes: 0, bytesPerSecond: 0),
            "Qwen_Qwen3-14B-GGUF: Preparing…"
        )
        // Normal in-progress download with real numbers.
        let summary = DownloadMenuBarPresentation.summary(modelName: "bartowski/Qwen_Qwen3-14B-GGUF", isResolving: false, status: "Downloading", progress: 0.5, totalBytes: 1_000_000_000, bytesPerSecond: 10_000_000)
        XCTAssertTrue(summary.hasPrefix("Qwen_Qwen3-14B-GGUF: "))
        XCTAssertTrue(summary.contains("50"))
        XCTAssertTrue(summary.hasSuffix("/s"))
    }

    func testExternalRequestLabelOnlyShowsForNonInferenceBarTrafficWhileRunning() {
        // Not running at all -- nothing to show regardless of count.
        XCTAssertNil(MenuBarLifecyclePresentation.externalRequestLabel(lifecycle: .stopped, isSending: false, activeRequests: 3))
        XCTAssertNil(MenuBarLifecyclePresentation.externalRequestLabel(lifecycle: .starting, isSending: false, activeRequests: 3))
        // Running, but InferenceBar's own chat is the one sending -- that
        // already has its own status line, so this would be redundant.
        XCTAssertNil(MenuBarLifecyclePresentation.externalRequestLabel(lifecycle: .running, isSending: true, activeRequests: 3))
        // Running and idle -- no external traffic to report.
        XCTAssertNil(MenuBarLifecyclePresentation.externalRequestLabel(lifecycle: .running, isSending: false, activeRequests: 0))
        // The actual case this exists for: running, not InferenceBar's
        // own chat, and the server log shows active requests.
        XCTAssertEqual(MenuBarLifecyclePresentation.externalRequestLabel(lifecycle: .running, isSending: false, activeRequests: 1), "1 external request active")
        XCTAssertEqual(MenuBarLifecyclePresentation.externalRequestLabel(lifecycle: .running, isSending: false, activeRequests: 2), "2 external requests active")
    }

    func testMinimumUnifiedMemoryParsesPlainRangeAndPlusHardwareStrings() {
        func preset(hardware: String) -> ProfilePreset {
            ProfilePreset(id: "t", title: "t", hardware: hardware, summary: "", profile: ServerProfile(name: "t", alias: "t"))
        }
        XCTAssertEqual(preset(hardware: "Apple Silicon · 16 GB").minimumUnifiedMemoryGB, 16)
        // A range or a "+" both mean "sized for at least this much" -- the
        // low end is the floor to compare against, not an average.
        XCTAssertEqual(preset(hardware: "M2/M3/M4 Pro or Max · 36–48 GB").minimumUnifiedMemoryGB, 36)
        XCTAssertEqual(preset(hardware: "Mac Studio Ultra / Mac Pro · 192 GB+").minimumUnifiedMemoryGB, 192)
        // No GB figure at all -- never filtered out sight unseen.
        XCTAssertNil(preset(hardware: "Apple Silicon").minimumUnifiedMemoryGB)
    }

    func testIsSupportedComparesAgainstTheFloorNotTheWholeRange() {
        func preset(hardware: String) -> ProfilePreset {
            ProfilePreset(id: "t", title: "t", hardware: hardware, summary: "", profile: ServerProfile(name: "t", alias: "t"))
        }
        let tier = preset(hardware: "M2/M3/M4 Pro or Max · 36–48 GB")
        XCTAssertFalse(tier.isSupported(physicalMemoryGB: 24))
        XCTAssertTrue(tier.isSupported(physicalMemoryGB: 36))
        XCTAssertTrue(tier.isSupported(physicalMemoryGB: 48))
        XCTAssertTrue(tier.isSupported(physicalMemoryGB: 192))
        // A hardware string this doesn't understand is always supported --
        // "filter nothing" is the safe default, not "hide everything".
        XCTAssertTrue(preset(hardware: "Apple Silicon").isSupported(physicalMemoryGB: 8))
    }

    func testEveryCurrentPresetsHardwareStringParses() {
        // A regression catcher: if a future preset's `hardware` field
        // drifts from the "... · N[-M] GB[+]" convention, it would
        // silently stop being hardware-filtered (isSupported treats an
        // unparseable string as always-supported) instead of failing
        // loudly, so this pins the convention down explicitly.
        for preset in ProfilePreset.all {
            XCTAssertNotNil(preset.minimumUnifiedMemoryGB, "\(preset.id) hardware string \"\(preset.hardware)\" didn't parse a GB figure")
        }
    }

    func testEveryCurrentPresetHasAtLeastOneUseCase() {
        // A regression catcher for the "Add preset" menu's category
        // submenus: an untagged preset isn't lost (presetCategoryMenu(nil)
        // in ContentView.swift catches it), but it's still worth knowing
        // if a newly added preset was forgotten rather than deliberately
        // left uncategorized.
        for preset in ProfilePreset.all {
            XCTAssertFalse(preset.useCases.isEmpty, "\(preset.id) has no PresetUseCase tag")
        }
    }

    func testVisionCapablePresetsAreTaggedChatWithImages() {
        // These six are confirmed (via each repo's real sibling file
        // listing) to ship an mmproj projector file that llama.cpp or
        // mlx-vlm actually wires up, not just a model family that's
        // "usually" multimodal -- see the comments beside each preset in
        // Models.swift.
        let visionCapable = ["mlx-qwen3-vl-8b-home-16", "gguf-qwen3-vl-8b-q4-16", "gguf-qwen3-vl-8b-q8-32", "gguf-qwen3-vl-32b-q4-48", "mistral-small31-32", "gemma12-24"]
        for id in visionCapable {
            let preset = ProfilePreset.all.first { $0.id == id }
            XCTAssertEqual(preset?.useCases.contains(.visionChat), true, "\(id) should be tagged .visionChat")
        }
    }

    func testM5MacBookPresetsExistWithConfirmedSourcesAndSensibleTiers() {
        let expectations: [(id: String, hardware: String, minimumGB: Int, source: String?, filename: String?)] = [
            ("gguf-qwen38-27b-q8-m5max-64", "MacBook Pro M5 Max · 64 GB", 64, "ggml-org/Qwen3.8-27B-GGUF", "Qwen3.8-27B-Q8_0.gguf"),
            ("gguf-qwen36-35b-q8-m5max-64", "MacBook Pro M5 Max · 64 GB", 64, "bartowski/Qwen_Qwen3.6-35B-A3B-GGUF", "Qwen_Qwen3.6-35B-A3B-Q8_0.gguf"),
            ("mlx-qwen38-27b-8bit-m5max-64", "MacBook Pro M5 Max · 64 GB", 64, "lmstudio-community/Qwen3.8-27B-MLX-8bit", nil),
            ("gguf-qwen38-27b-q4-m5pro-48", "MacBook Pro M5 Pro · 48 GB", 48, "ggml-org/Qwen3.8-27B-GGUF", "Qwen3.8-27B-Q4_K_M.gguf"),
            ("gguf-qwen38-27b-q4-32", "MacBook Air / Pro M5 · 32 GB", 32, "ggml-org/Qwen3.8-27B-GGUF", "Qwen3.8-27B-Q4_K_M.gguf"),
            ("mlx-qwen38-27b-4bit-32", "MacBook Air / Pro M5 · 32 GB", 32, "mlx-community/Qwen3.8-27B-4bit", nil),
            ("mlx-gpt-oss-120b-m5max-128", "MacBook Pro M5 Max · 128 GB", 128, "mlx-community/gpt-oss-120b-MXFP4-Q4", nil),
            ("gguf-qwen3-coder-30b-q8-m5max-64", "MacBook Pro M5 Max · 64 GB", 64, "unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF", "Qwen3-Coder-30B-A3B-Instruct-Q8_0.gguf"),
            ("mlx-qwen3-coder-30b-8bit-m5max-64", "MacBook Pro M5 Max · 64 GB", 64, "mlx-community/Qwen3-Coder-30B-A3B-Instruct-8bit", nil),
            ("gguf-qwen3-coder-30b-q4-m5pro-48", "MacBook Pro M5 Pro · 48 GB", 48, "unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF", "Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"),
            ("gguf-qwen3-coder-30b-q4-32", "MacBook Air / Pro M5 · 32 GB", 32, "unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF", "Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"),
        ]
        for expectation in expectations {
            let preset = ProfilePreset.all.first { $0.id == expectation.id }
            XCTAssertNotNil(preset, "missing preset \(expectation.id)")
            XCTAssertEqual(preset?.hardware, expectation.hardware)
            XCTAssertEqual(preset?.minimumUnifiedMemoryGB, expectation.minimumGB)
            XCTAssertEqual(preset?.downloadSourceModelID, expectation.source, "wrong source for \(expectation.id)")
            XCTAssertEqual(preset?.expectedGGUFFilename, expectation.filename, "wrong filename for \(expectation.id)")
        }
        // A 64 GB M5 Max sees its own tier and everything smaller, but
        // not the 128 GB one.
        let at64 = ProfilePreset.all.filter { $0.hardware.contains("M5 Max") && $0.isSupported(physicalMemoryGB: 64) }
        XCTAssertEqual(Set(at64.map(\.id)), ["gguf-qwen38-27b-q8-m5max-64", "gguf-qwen36-35b-q8-m5max-64", "mlx-qwen38-27b-8bit-m5max-64", "gguf-qwen3-coder-30b-q8-m5max-64", "mlx-qwen3-coder-30b-8bit-m5max-64"])
    }

    func testEveryVisionPresetsProjectorPairsWithItsOwnModelAndNoOtherFamily() {
        // Pins down MultimodalProjector's family matching against every
        // real preset at once, not just one hand-picked pair: each
        // llama.cpp vision preset's own projector has to be accepted for
        // its model file, and a different generation's projector (here
        // Qwen3.6 vs Qwen3.8, which differ by a single token) has to be
        // refused -- otherwise llama-server aborts on a tensor mismatch.
        for preset in ProfilePreset.all where preset.profile.runtime == .llamaCPP {
            guard let projector = preset.mmprojFilename, let model = preset.expectedGGUFFilename else { continue }
            XCTAssertEqual(MultimodalProjector.projectorFilename(forModel: model, siblingFilenames: [projector]), projector, "\(preset.id): projector isn't paired with its own model")
        }
        XCTAssertNil(MultimodalProjector.projectorFilename(forModel: "Qwen3.6-27B-Q4_K_M.gguf", siblingFilenames: ["mmproj-Qwen3.8-27B-Q8_0.gguf"]))
        XCTAssertNil(MultimodalProjector.projectorFilename(forModel: "Qwen3.8-27B-Q8_0.gguf", siblingFilenames: ["mmproj-Qwen3VL-32B-Instruct-F16.gguf"]))
    }

    func testPresetAliasesAreUniqueSoOpenCodeSyncCannotCollide() {
        // OpenCodeConfigSync keys its model list by alias, so two
        // different presets sharing one would overwrite each other there.
        // (Pre-existing duplicates among older presets are left alone;
        // this only guards the M5-generation additions.)
        let m5Presets: Set<String> = [
            "gguf-qwen38-27b-q8-m5max-64", "gguf-qwen36-35b-q8-m5max-64", "mlx-qwen38-27b-8bit-m5max-64",
            "gguf-qwen38-27b-q4-m5pro-48", "gguf-qwen38-27b-q4-32", "mlx-qwen38-27b-4bit-32", "mlx-gpt-oss-120b-m5max-128",
            "gguf-qwen3-coder-30b-q8-m5max-64", "mlx-qwen3-coder-30b-8bit-m5max-64", "gguf-qwen3-coder-30b-q4-m5pro-48", "gguf-qwen3-coder-30b-q4-32"
        ]
        let aliases = ProfilePreset.all.filter { m5Presets.contains($0.id) }.map(\.profile.alias)
        XCTAssertEqual(aliases.count, m5Presets.count)
        // The 48 GB and 32 GB Qwen3.8 Q4_K_M presets deliberately share
        // one model file but must still differ in alias.
        XCTAssertEqual(aliases.count, Set(aliases).count, "duplicate alias among the M5 presets: \(aliases)")
    }

    func testPresetStillMatchesItsProfileAfterTheDownloadRewritesTheModelPath() throws {
        // A finished download replaces "~/ai-models/x.gguf" with the real
        // absolute path (and an MLX repo ID with its snapshot folder). The
        // OpenCode sync and its picker used to compare the raw strings, so
        // a downloaded coding profile was reported as "no coding profiles".
        let gguf = try XCTUnwrap(ProfilePreset.all.first { $0.id == "gguf-qwen3-coder-30b-q8-m5max-64" })
        var profile = gguf.profile
        XCTAssertTrue(gguf.matches(profile), "a freshly added profile matches")
        profile.modelPath = "/Users/alex/ai-models/Qwen3-Coder-30B-A3B-Instruct-Q8_0.gguf"
        XCTAssertTrue(gguf.matches(profile), "absolute path after the download")
        profile.modelPath = "/Volumes/Models/qwen3-coder-30b-a3b-instruct-q8_0.GGUF"
        XCTAssertTrue(gguf.matches(profile), "another model folder, different letter case")
        profile.modelPath = "/Users/alex/ai-models/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"
        XCTAssertFalse(gguf.matches(profile), "a different quantization is a different model")

        let mlx = try XCTUnwrap(ProfilePreset.all.first { $0.id == "mlx-qwen3-coder-30b-8bit-m5max-64" })
        var mlxProfile = mlx.profile
        XCTAssertTrue(mlx.matches(mlxProfile))
        let folder = "models--" + mlx.profile.modelPath.replacingOccurrences(of: "/", with: "--")
        mlxProfile.modelPath = "/Users/alex/ai-models/\(folder)/snapshots/abc123"
        XCTAssertTrue(mlx.matches(mlxProfile), "snapshot folder after the MLX download")
        mlxProfile.modelPath = "/Users/alex/ai-models/models--mlx-community--Other-Model-8bit/snapshots/abc123"
        XCTAssertFalse(mlx.matches(mlxProfile))
        XCTAssertFalse(gguf.matches(mlxProfile), "the runtime must agree too")
    }

    func testOpenCodeSyncNeverTreatsAnUnparseableConfigAsEmpty() throws {
        XCTAssertEqual(try OpenCodeConfigSync.parseExisting(nil).get().count, 0, "no file yet is an empty config")
        XCTAssertEqual(try OpenCodeConfigSync.parseExisting(Data("  \n".utf8)).get().count, 0, "a blank file is an empty config")
        let ok = try OpenCodeConfigSync.parseExisting(Data(#"{"theme":"dark"}"#.utf8)).get()
        XCTAssertEqual(ok["theme"] as? String, "dark")
        // A trailing comma is deliberately not listed: Foundation accepts it, so
        // that file is read completely and rewritten as valid JSON, losing nothing.
        for broken in ["// my settings\n{\"theme\":\"dark\"}", "[1,2]", "{\"theme\":"] {
            XCTAssertEqual(OpenCodeConfigSync.parseExisting(Data(broken.utf8)).failureValue, .notAJSONObject, "\(broken) would have been overwritten")
        }
    }

    func testOpenCodeCodingPresetsRunToolCallingTemplatesAndFitTheirMemoryTier() {
        // Weights + fp16 KV cache (48 layers x 4 KV heads x 128 dims x 2
        // tensors x 2 bytes = 98,304 bytes/token) must stay inside the
        // share of unified memory macOS lets the GPU wire. Published figures
        // say roughly 75%; machines of 36 GB or less are often reported at
        // two thirds, so the smaller tiers are held to that stricter limit.
        let tiers: [(id: String, weightsGB: Double, memoryGB: Double)] = [
            ("gguf-qwen3-coder-30b-q8-m5max-64", 32.5, 64),
            ("mlx-qwen3-coder-30b-8bit-m5max-64", 32.5, 64),
            ("gguf-qwen3-coder-30b-q4-m5pro-48", 18.6, 48),
            ("gguf-qwen3-coder-30b-q4-32", 18.6, 32),
        ]
        for tier in tiers {
            guard let preset = ProfilePreset.all.first(where: { $0.id == tier.id }) else {
                XCTFail("missing preset \(tier.id)")
                continue
            }
            XCTAssertTrue(preset.useCases.contains(.coding), "\(tier.id) should be a coding preset")
            if preset.profile.runtime == .llamaCPP {
                XCTAssertTrue(preset.profile.jinja, "\(tier.id) needs --jinja for the tool-call template")
                XCTAssertTrue(preset.profile.flashAttention)
            }
            let kvGB = Double(preset.profile.contextSize) * 98_304 / 1_073_741_824
            let ceiling = tier.memoryGB <= 36 ? tier.memoryGB * 2 / 3 : tier.memoryGB * 0.75
            XCTAssertLessThan(tier.weightsGB + kvGB, ceiling, "\(tier.id) would exceed the GPU wired-memory ceiling")
        }
    }

    func testMenuBarIconNeverDrawsOutsideItsCanvas() {
        // The menu bar clips anything outside the image, which is how the
        // status dot got sliced off at the right and bottom edges: its
        // cut-out ring reached x=25.25 and y=-1.25 on a 24x18 canvas.
        let canvas = NSRect(origin: .zero, size: StatusIconGeometry.size)
        let badges: [(name: String, dot: NSRect)] = [
            ("status", StatusIconGeometry.statusDot),
            ("update", StatusIconGeometry.updateDot),
        ]
        for badge in badges {
            let ring = StatusIconGeometry.ring(around: badge.dot)
            XCTAssertTrue(canvas.contains(ring), "\(badge.name) badge's ring \(ring) leaves the \(canvas) canvas")
        }
        XCTAssertTrue(canvas.contains(StatusIconGeometry.bubble))
        XCTAssertTrue(StatusIconGeometry.bubble.contains(StatusIconGeometry.bolt))
        // The update badge has its own corner; it must not cover the status dot.
        XCTAssertFalse(StatusIconGeometry.statusDot.intersects(StatusIconGeometry.updateDot))
    }

    func testPresetUseCaseTitlesAndIconsAreDistinct() {
        // Every case needs its own label and symbol -- a collision would
        // make two categories indistinguishable in the "Add preset" menu.
        let titles = Set(PresetUseCase.allCases.map(\.title))
        let icons = Set(PresetUseCase.allCases.map(\.icon))
        XCTAssertEqual(titles.count, PresetUseCase.allCases.count)
        XCTAssertEqual(icons.count, PresetUseCase.allCases.count)
    }

    func testChunkRangesCoverTheWholeFileContiguouslyWithNoGapsOrOverlaps() {
        // A realistic ~4 GB quant split 4 ways.
        let totalBytes: Int64 = 4_000_000_003 // deliberately not evenly divisible
        let ranges = ParallelDownloadPlanner.chunkRanges(totalBytes: totalBytes)
        XCTAssertEqual(ranges.count, ParallelDownloadPlanner.chunkCount)
        XCTAssertEqual(ranges.first?.lowerBound, 0)
        XCTAssertEqual(ranges.last?.upperBound, totalBytes - 1)
        for (previous, next) in zip(ranges, ranges.dropFirst()) {
            XCTAssertEqual(next.lowerBound, previous.upperBound + 1, "chunks must be back-to-back with no gap or overlap")
        }
        let coveredBytes = ranges.reduce(Int64(0)) { $0 + ($1.upperBound - $1.lowerBound + 1) }
        XCTAssertEqual(coveredBytes, totalBytes)
    }

    func testChunkRangesNeverExceedsOneChunkPerByte() {
        // Fewer bytes than the usual chunk count -- degrade to fewer,
        // still-valid ranges instead of an empty or zero-length one.
        let ranges = ParallelDownloadPlanner.chunkRanges(totalBytes: 3)
        XCTAssertEqual(ranges.count, 3)
        XCTAssertEqual(ranges, [0...0, 1...1, 2...2])
        XCTAssertEqual(ParallelDownloadPlanner.chunkRanges(totalBytes: 0), [])
    }

    func testShouldSplitOnlyAboveTheMinimumSizeThreshold() {
        XCTAssertFalse(ParallelDownloadPlanner.shouldSplit(totalBytes: ParallelDownloadPlanner.minimumBytesToSplit - 1))
        XCTAssertTrue(ParallelDownloadPlanner.shouldSplit(totalBytes: ParallelDownloadPlanner.minimumBytesToSplit))
        XCTAssertTrue(ParallelDownloadPlanner.shouldSplit(totalBytes: ParallelDownloadPlanner.minimumBytesToSplit * 100))
    }

    func testEveryVisionCapableGGUFPresetHasAConfirmedMmprojFilename() {
        // Every .visionChat preset that runs on llama.cpp needs a
        // confirmed mmproj companion filename so "Add preset"/"Add all
        // presets" can actually fetch it (see
        // AppStore.processPresetDownloadQueue) -- without this, the model
        // downloads and runs fine but every image attachment gets refused,
        // which is exactly the bug that motivated adding mmprojFilename in
        // the first place. MLX/vLLM-MLX vision presets are exempt: their
        // runtime doesn't use a separate --mmproj file at all.
        for preset in ProfilePreset.all where preset.useCases.contains(.visionChat) && preset.profile.runtime == .llamaCPP {
            XCTAssertNotNil(preset.mmprojFilename, "\(preset.id) is tagged .visionChat and runs on llama.cpp but has no mmprojFilename set")
        }
    }

    func testHasProjectorAvailableIsVacuouslyTrueForNonVisionPresets() {
        // A preset with no mmprojFilename has nothing to check for, so it
        // should never block on a projector it was never going to fetch --
        // even against an empty/nonexistent directory.
        let nonVisionPreset = ProfilePreset.all.first { $0.mmprojFilename == nil }
        XCTAssertNotNil(nonVisionPreset, "expected at least one preset without mmprojFilename to exist for this test")
        let emptyDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(nonVisionPreset!.hasProjectorAvailable(modelRoot: emptyDirectory))
    }

    func testHasProjectorAvailableFindsAMatchingSiblingRegardlessOfWhichModelItWasDownloadedFor() {
        // The app's model directory is flat and shared across every
        // downloaded model (see MultimodalProjector's doc comments), so
        // hasProjectorAvailable should be satisfied by ANY mmproj file
        // sitting in modelRoot, not specifically the one named in
        // mmprojFilename -- mirroring MultimodalProjector.hasProjectorSibling's
        // own matching rule.
        let visionPreset = ProfilePreset.all.first { $0.mmprojFilename != nil }
        XCTAssertNotNil(visionPreset, "expected at least one preset with mmprojFilename to exist for this test")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertFalse(visionPreset!.hasProjectorAvailable(modelRoot: directory), "should report missing before any projector file exists")
        let differentlyNamedProjector = directory.appendingPathComponent("some-other-mmproj-file-f16.gguf")
        FileManager.default.createFile(atPath: differentlyNamedProjector.path, contents: Data())
        XCTAssertTrue(visionPreset!.hasProjectorAvailable(modelRoot: directory), "any mmproj-named sibling should satisfy the check")
    }

    func testHFModelSiblingsDecodeWithTheRfilenameKeyThatModelCardReliesOn() {
        // ModelCard (ContentView.swift) computes its "Vision" tag as
        // MultimodalProjector.hasProjectorSibling(among: (model.siblings ??
        // []).map(\.rfilename)) -- this pins down that an HFModel decoded
        // from a real `?full=true` Hugging Face API response actually
        // populates `siblings` with that shape, so a rename of the
        // "rfilename" JSON key (or of the Sibling type) would fail loudly
        // here instead of just silently making every ModelCard's vision
        // tag disappear.
        let json = """
        {"id":"Qwen/Qwen3-VL-8B-Instruct-GGUF","siblings":[{"rfilename":"Qwen3VL-8B-Instruct-F16.gguf"},{"rfilename":"mmproj-Qwen3VL-8B-Instruct-F16.gguf"},{"rfilename":"README.md"}]}
        """
        let model = try! JSONDecoder().decode(HFModel.self, from: Data(json.utf8))
        let siblingNames = (model.siblings ?? []).map(\.rfilename)
        XCTAssertEqual(siblingNames, ["Qwen3VL-8B-Instruct-F16.gguf", "mmproj-Qwen3VL-8B-Instruct-F16.gguf", "README.md"])
        XCTAssertTrue(MultimodalProjector.hasProjectorSibling(among: siblingNames))
    }

    func testHFModelWithNoSiblingsFieldDoesNotCrashTheVisionTagComputation() {
        // A search path that doesn't request `full=true` (or a repo with
        // no listed files) decodes `siblings` as nil -- ModelCard's `??
        // []` fallback should read as "no projector found", not crash.
        let json = """
        {"id":"bartowski/some-model-GGUF"}
        """
        let model = try! JSONDecoder().decode(HFModel.self, from: Data(json.utf8))
        XCTAssertNil(model.siblings)
        XCTAssertFalse(MultimodalProjector.hasProjectorSibling(among: (model.siblings ?? []).map(\.rfilename)))
    }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
