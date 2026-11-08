import Foundation
import XCTest
@testable import InferenceBar

/// The pure logic behind the disk-space check, the speed test, the OpenCode
/// launcher/status and the in-app update download (see Utilities.swift).
final class ToolingFeatureTests: XCTestCase {
    private let gib: Int64 = 1_073_741_824

    // MARK: Disk space

    func testDiskSpaceAdvisorAllowsADownloadThatFitsWithItsReserve() {
        XCTAssertNil(DiskSpaceAdvisor.problem(requiredBytes: 32 * gib, availableBytes: 100 * gib))
        // Exactly the file plus the 5 GB reserve is enough; one byte less is not.
        XCTAssertNil(DiskSpaceAdvisor.problem(requiredBytes: 32 * gib, availableBytes: 37 * gib))
        XCTAssertNotNil(DiskSpaceAdvisor.problem(requiredBytes: 32 * gib, availableBytes: 37 * gib - 1))
    }

    func testDiskSpaceAdvisorExplainsWhatIsMissing() throws {
        let message = try XCTUnwrap(DiskSpaceAdvisor.problem(requiredBytes: 32 * gib, availableBytes: 10 * gib))
        XCTAssertTrue(message.contains("Not enough free disk space"))
        XCTAssertTrue(message.contains("Settings"), "it should say what the user can do about it")
    }

    func testDiskSpaceAdvisorCountsWhatAResumedDownloadAlreadyHas() {
        // 32 GB file, 20 GB already on disk: 12 GB + 5 GB reserve = 17 GB.
        XCTAssertNotNil(DiskSpaceAdvisor.problem(requiredBytes: 32 * gib, alreadyPresentBytes: 20 * gib, availableBytes: 16 * gib))
        XCTAssertNil(DiskSpaceAdvisor.problem(requiredBytes: 32 * gib, alreadyPresentBytes: 20 * gib, availableBytes: 17 * gib))
    }

    func testDiskSpaceAdvisorNeverBlocksWhenTheSizeOrTheFreeSpaceIsUnknown() {
        XCTAssertNil(DiskSpaceAdvisor.problem(requiredBytes: 0, availableBytes: 1))
        XCTAssertNil(DiskSpaceAdvisor.problem(requiredBytes: 32 * gib, availableBytes: nil))
    }

    func testAvailableBytesWorksForAFolderThatDoesNotExistYet() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-folder-\(UUID().uuidString)/models", isDirectory: true)
        let free = DiskSpaceAdvisor.availableBytes(at: missing)
        XCTAssertNotNil(free, "the nearest existing parent is asked instead")
        XCTAssertGreaterThan(free ?? 0, 0)
    }

    // MARK: Speed test

    func testPromptTokenTargetFitsTheSlotContext() {
        XCTAssertEqual(SpeedTest.promptTokenTarget(contextSize: 98_304, parallel: 1), 2000, "capped")
        XCTAssertEqual(SpeedTest.promptTokenTarget(contextSize: 4096, parallel: 1), 2000, "half of 4096 is 2048, still capped")
        XCTAssertEqual(SpeedTest.promptTokenTarget(contextSize: 2048, parallel: 1), 1024, "half the slot")
        XCTAssertEqual(SpeedTest.promptTokenTarget(contextSize: 4096, parallel: 4), 512, "llama.cpp splits the context between slots")
        XCTAssertEqual(SpeedTest.promptTokenTarget(contextSize: 100, parallel: 1), 200, "never below the floor")
        XCTAssertEqual(SpeedTest.promptTokenTarget(contextSize: 2048, parallel: 0), 1024, "a zero parallel setting is treated as one")
    }

    func testLongPromptIsUniquePerRunAndRoughlyTheRequestedSize() {
        let first = SpeedTest.longPrompt(approximateTokens: 2000, nonce: "aaa")
        let second = SpeedTest.longPrompt(approximateTokens: 2000, nonce: "bbb")
        XCTAssertNotEqual(first, second, "a prompt cache must not be able to answer it")
        XCTAssertTrue(first.hasPrefix("Reference aaa."), "the nonce comes first so the whole prompt differs")
        XCTAssertEqual(first.components(separatedBy: "quick brown fox").count - 1, 2000 / 22)
        XCTAssertEqual(SpeedTest.longPrompt(approximateTokens: 5, nonce: "x").components(separatedBy: "quick brown fox").count - 1, 1)
    }

    func testRequestBodyOnlyAddsLlamaCppExtensionsForLlamaCpp() {
        let llama = SpeedTest.requestBody(model: "m", prompt: "hi", maxTokens: 1, llamaCPP: true)
        XCTAssertEqual(llama["cache_prompt"] as? Bool, false)
        XCTAssertEqual(llama["model"] as? String, "m")
        XCTAssertEqual(llama["max_tokens"] as? Int, 1)
        XCTAssertEqual(llama["stream"] as? Bool, false)
        let mlx = SpeedTest.requestBody(model: nil, prompt: "hi", maxTokens: 128, llamaCPP: false)
        XCTAssertNil(mlx["cache_prompt"])
        XCTAssertNil(mlx["model"], "mlx_lm.server would try to resolve a model name as a repository")
    }

    func testParseUsesLlamaCppTimingsWhenTheServerReportsThem() throws {
        let json = #"{"usage":{"prompt_tokens":2000,"completion_tokens":1},"timings":{"prompt_n":2000,"predicted_n":1,"prompt_per_second":812.5,"predicted_per_second":55.2}}"#
        let measurement = try XCTUnwrap(SpeedTest.parse(Data(json.utf8), elapsedSeconds: 9))
        XCTAssertTrue(measurement.reportedByServer)
        XCTAssertEqual(measurement.promptTokens, 2000)
        XCTAssertEqual(try XCTUnwrap(measurement.promptTokensPerSecond), 812.5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(measurement.generationTokensPerSecond), 55.2, accuracy: 0.001)
    }

    func testParseEstimatesFromWallClockTimeWithoutServerTimings() throws {
        let json = #"{"usage":{"prompt_tokens":100,"completion_tokens":50}}"#
        let measurement = try XCTUnwrap(SpeedTest.parse(Data(json.utf8), elapsedSeconds: 2))
        XCTAssertFalse(measurement.reportedByServer)
        XCTAssertEqual(try XCTUnwrap(measurement.promptTokensPerSecond), 50, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(measurement.generationTokensPerSecond), 25, accuracy: 0.001)
    }

    func testParseRejectsRepliesWithNoTokenCounts() {
        XCTAssertNil(SpeedTest.parse(Data("not json".utf8), elapsedSeconds: 1))
        XCTAssertNil(SpeedTest.parse(Data("{}".utf8), elapsedSeconds: 1))
        XCTAssertNil(SpeedTest.parse(Data(#"{"usage":{"prompt_tokens":0,"completion_tokens":0}}"#.utf8), elapsedSeconds: 1))
    }

    func testSummaryIsMarkedEstimatedUnlessBothMeasurementsCameFromTheServer() {
        let reported = SpeedMeasurement(promptTokens: 10, generatedTokens: 1, promptTokensPerSecond: 5, generationTokensPerSecond: 6, reportedByServer: true)
        let guessed = SpeedMeasurement(promptTokens: 10, generatedTokens: 1, promptTokensPerSecond: 1, generationTokensPerSecond: 2, reportedByServer: false)
        XCTAssertEqual(SpeedTest.summary(profileName: "p", prompt: reported, generation: reported)?.estimated, false)
        XCTAssertEqual(SpeedTest.summary(profileName: "p", prompt: reported, generation: guessed)?.estimated, true)
        XCTAssertNil(SpeedTest.summary(profileName: "p", prompt: nil, generation: nil))
        let both = SpeedTest.summary(profileName: "p", prompt: reported, generation: guessed)
        XCTAssertEqual(both?.promptTokensPerSecond, 5, "prompt speed comes from the prompt run")
        XCTAssertEqual(both?.generationTokensPerSecond, 2, "generation speed comes from the generation run")
    }

    // MARK: OpenCode launcher and sync status

    func testLauncherPlanStartsTheDefaultCodingProfileWhenNothingIsRunning() {
        let first = UUID(), second = UUID()
        XCTAssertEqual(OpenCodeLauncher.plan(codingProfileIDs: [first, second], runningProfileID: nil, serverIsActive: false, defaultProfileID: second), .startProfile(second))
        XCTAssertEqual(OpenCodeLauncher.plan(codingProfileIDs: [first, second], runningProfileID: nil, serverIsActive: false, defaultProfileID: nil), .startProfile(first))
        XCTAssertEqual(OpenCodeLauncher.plan(codingProfileIDs: [first, second], runningProfileID: nil, serverIsActive: false, defaultProfileID: UUID()), .startProfile(first), "a default that is no longer a coding profile is ignored")
        XCTAssertEqual(OpenCodeLauncher.plan(codingProfileIDs: [], runningProfileID: nil, serverIsActive: false, defaultProfileID: nil), .noProfile)
    }

    func testLauncherPlanNeverSwitchesAServerThatIsAlreadyUp() {
        let coding = UUID(), other = UUID()
        XCTAssertEqual(OpenCodeLauncher.plan(codingProfileIDs: [coding], runningProfileID: coding, serverIsActive: true, defaultProfileID: nil), .useRunning(coding))
        guard case .blocked = OpenCodeLauncher.plan(codingProfileIDs: [coding], runningProfileID: other, serverIsActive: true, defaultProfileID: coding) else {
            return XCTFail("a running profile that is not a coding profile must not be replaced silently")
        }
        guard case .blocked = OpenCodeLauncher.plan(codingProfileIDs: [coding], runningProfileID: nil, serverIsActive: true, defaultProfileID: nil) else {
            return XCTFail("a server that is starting or stopping is not free to take over")
        }
    }

    func testShellQuoteSurvivesSpacesQuotesAndShellCharacters() {
        XCTAssertEqual(OpenCodeLauncher.shellQuote("/Users/alex/My Project"), "'/Users/alex/My Project'")
        XCTAssertEqual(OpenCodeLauncher.shellQuote("it's"), #"'it'\''s'"#)
        XCTAssertEqual(OpenCodeLauncher.shellQuote("$HOME/`id`"), "'$HOME/`id`'", "nothing inside single quotes is expanded")
    }

    func testLauncherScriptWaitsForTheServerThenRunsOpenCodeInTheFolder() {
        let script = OpenCodeLauncher.script(directory: "/tmp/my project", healthURL: "http://127.0.0.1:8080/health", authenticationEnabled: false)
        XCTAssertTrue(script.hasPrefix("#!/bin/zsh\n"))
        XCTAssertTrue(script.contains("cd '/tmp/my project' ||"))
        XCTAssertTrue(script.contains("'http://127.0.0.1:8080/health'"))
        XCTAssertTrue(script.hasSuffix("exec opencode\n"))
        XCTAssertFalse(script.contains("INFERENCE_API_KEY"))
    }

    func testLauncherScriptNeverContainsTheApiKey() {
        let script = OpenCodeLauncher.script(directory: "/tmp/p", healthURL: "http://127.0.0.1:8080/health", authenticationEnabled: true)
        XCTAssertTrue(script.contains("INFERENCE_API_KEY"), "it tells the user which variable to export")
        XCTAssertFalse(script.contains("sk-"))
        XCTAssertFalse(script.contains("Bearer"))
    }

    func testOpenCodeSyncStatusKnowsWhetherItSucceeded() {
        let ok = OpenCodeSyncStatus(kind: .synced, message: "Synced 2 models", models: ["a", "b"], date: Date())
        let bad = OpenCodeSyncStatus(kind: .failed, message: "no", models: [], date: Date())
        XCTAssertTrue(ok.isSuccess)
        XCTAssertFalse(bad.isSuccess)
    }

    // MARK: In-app update download

    func testUpdateDownloadNamesTheDmgTheWayTheMakefileDoes() {
        XCTAssertEqual(UpdateDownload.version(fromTag: "v0.7.1"), "0.7.1")
        XCTAssertEqual(UpdateDownload.version(fromTag: "V1.0"), "1.0")
        XCTAssertEqual(UpdateDownload.version(fromTag: "0.7"), "0.7")
        XCTAssertEqual(UpdateDownload.version(fromTag: "vnext"), "vnext", "a v not followed by a digit is part of the name")
        XCTAssertEqual(UpdateDownload.dmgFilename(tag: "v0.7.1"), "InferenceBar-0.7.1-macos.dmg")
    }

    func testUpdateAssetURLPointsAtTheGitHubReleaseAndRefusesPathTricks() {
        XCTAssertEqual(
            UpdateDownload.assetURL(tag: "v0.7.1", filename: "InferenceBar-0.7.1-macos.dmg")?.absoluteString,
            "https://github.com/kladhest-se/inferencebar/releases/download/v0.7.1/InferenceBar-0.7.1-macos.dmg"
        )
        XCTAssertNil(UpdateDownload.assetURL(tag: "v1/../../evil", filename: "x.dmg"))
        XCTAssertNil(UpdateDownload.assetURL(tag: "v1", filename: "../x.dmg"))
        XCTAssertNil(UpdateDownload.assetURL(tag: "", filename: "x.dmg"))
    }

    func testExpectedSHA256ReadsAShasumLine() {
        let hash = String(repeating: "ab", count: 32)
        XCTAssertEqual(UpdateDownload.expectedSHA256(fromChecksumFile: "\(hash)  InferenceBar-0.7.1-macos.dmg\n"), hash)
        XCTAssertEqual(UpdateDownload.expectedSHA256(fromChecksumFile: hash.uppercased()), hash, "compared in lowercase")
        XCTAssertNil(UpdateDownload.expectedSHA256(fromChecksumFile: "short  file"))
        XCTAssertNil(UpdateDownload.expectedSHA256(fromChecksumFile: ""))
        XCTAssertNil(UpdateDownload.expectedSHA256(fromChecksumFile: "<html>Not Found</html>"), "an error page is not a checksum")
    }

    func testSHA256HexMatchesAKnownDigest() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sha-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try UpdateDownload.sha256Hex(of: file), "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }
}
