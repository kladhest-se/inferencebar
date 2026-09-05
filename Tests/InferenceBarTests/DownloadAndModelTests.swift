import Foundation
import XCTest
@testable import InferenceBar

final class DownloadAndModelTests: XCTestCase {
    func testUpdatePolicyFindsNewestNumericGitHubTag() {
        XCTAssertEqual(AppUpdatePolicy.newestUpdate(tags: ["v0.4", "v0.6", "0.5.2", "nightly"], currentVersion: "0.5"), "v0.6")
        XCTAssertNil(AppUpdatePolicy.newestUpdate(tags: ["v0.4", "v0.5.0"], currentVersion: "0.5"))
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
        // NOTE: matching is directory-scoped, not name-tied to a specific
        // model -- a real .gguf file that isn't the projector's own model
        // is only excluded by not being named "mmproj*", not by any check
        // that it "belongs" to this particular model. That's a deliberate
        // simplification (see testMultimodalProjectorPicksDeterministicallyWhenMultipleCandidatesExist,
        // which relies on projector filenames often being fully generic,
        // e.g. "mmproj-f16.gguf", with no relation to the model's own
        // name at all) -- so a *second* GGUF model dropped in the same
        // flat model folder does not itself get excluded from matching an
        // unrelated projector. All this test guards is that an unrelated
        // model file's mere presence doesn't break the correct pairing.
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
}
