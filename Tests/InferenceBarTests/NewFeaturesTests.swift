import Foundation
import XCTest
@testable import InferenceBar

/// Coverage for the features added in the cache/notifications/TLS/hotkey
/// enhancement pass: the profile Cache section, TLS settings, and the
/// reasoning controls — this time by testing the CLI arguments they
/// actually produce rather than driving the Settings/Profile Management
/// windows with `XCUIApplication`.
///
/// This file used to be `InferenceBarUITests`, added specifically because
/// SettingsTests.swift and LogsTests.swift (at the time) asserted on UI
/// that didn't match `GlobalServerSettingsView`/`LogsView` as actually
/// implemented — a "Server Settings" window title where the real window is
/// "Settings", General/Advanced tabs and a Theme picker that don't exist in
/// Settings, and an Autoscroll toggle/"Export logs" button that don't exist
/// in Logs. That whole approach turned out to rest on a premise SwiftPM
/// can't support at all: it has no product type for an Xcode-style "UI
/// Testing Bundle", so `XCUIApplication` refuses to run under `swift test`
/// no matter what it's pointed at ("Device is not configured for UI
/// testing"). Rewritten to test `ServerProfile.arguments(network:)` and
/// `GlobalServerSettings`, the actual state these controls read and write.
final class NewFeaturesTests: XCTestCase {

    // MARK: - Reasoning controls

    func testReasoningFieldsOnlyAppearWhenSet() {
        var profile = ServerProfile()
        profile.reasoning = ""
        profile.reasoningFormat = ""
        profile.reasoningBudget = 0
        profile.reasoningPreserve = false
        let bare = profile.arguments(network: GlobalServerSettings())
        XCTAssertFalse(bare.contains("--reasoning"))
        XCTAssertFalse(bare.contains("--reasoning-format"))
        XCTAssertFalse(bare.contains("--reasoning-budget"))
        XCTAssertFalse(bare.contains("--reasoning-preserve"))

        profile.reasoning = "high"
        profile.reasoningFormat = "deepseek"
        profile.reasoningBudget = 4_096
        profile.reasoningPreserve = true
        let args = profile.arguments(network: GlobalServerSettings())
        XCTAssertEqual(args[args.firstIndex(of: "--reasoning")! + 1], "high")
        XCTAssertEqual(args[args.firstIndex(of: "--reasoning-format")! + 1], "deepseek")
        XCTAssertEqual(args[args.firstIndex(of: "--reasoning-budget")! + 1], "4096")
        XCTAssertTrue(args.contains("--reasoning-preserve"))
    }

    // MARK: - Cache section: cache reuse and SWA-full

    func testCacheReuseIsOmittedUnlessPositive() {
        var profile = ServerProfile()
        profile.cacheReuse = nil
        XCTAssertFalse(profile.arguments(network: GlobalServerSettings()).contains("--cache-reuse"))
        profile.cacheReuse = 0
        XCTAssertFalse(profile.arguments(network: GlobalServerSettings()).contains("--cache-reuse"), "0 means disabled, not an explicit --cache-reuse 0")
        profile.cacheReuse = 256
        let args = profile.arguments(network: GlobalServerSettings())
        XCTAssertEqual(args[args.firstIndex(of: "--cache-reuse")! + 1], "256")
    }

    func testFullSWACacheFlagOnlyAppearsWhenExplicitlyEnabled() {
        var profile = ServerProfile()
        XCTAssertNil(profile.swaFull, "A profile saved before this field existed should decode with no opinion, not implicitly disabled")
        XCTAssertFalse(profile.arguments(network: GlobalServerSettings()).contains("--swa-full"))
        profile.swaFull = false
        XCTAssertFalse(profile.arguments(network: GlobalServerSettings()).contains("--swa-full"))
        profile.swaFull = true
        XCTAssertTrue(profile.arguments(network: GlobalServerSettings()).contains("--swa-full"))
    }

    func testCacheAdvancedFieldsDecodeFromAProfileSavedBeforeTheyExisted() throws {
        let legacyJSON = #"{"id":"00000000-0000-0000-0000-000000000002","name":"Legacy","executable":"llama-server","modelPath":"","alias":"local-model","contextSize":4096,"parallel":1,"flashAttention":true,"jinja":true,"cacheRAM":0,"reasoning":"auto","reasoningBudget":0,"reasoningFormat":"deepseek","reasoningPreserve":false,"extraArguments":""}"#
        let profile = try JSONDecoder().decode(ServerProfile.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(profile.cacheReuse)
        XCTAssertNil(profile.swaFull)
        XCTAssertNil(profile.exclusiveToInferenceBar)
    }

    // MARK: - TLS wiring (llama.cpp only)

    func testTLSFlagsOnlyAppearForLlamaCPPWithBothPathsSet() {
        var settings = GlobalServerSettings()
        settings.sslCertPath = "~/certs/inferencebar.pem"
        settings.sslKeyPath = "~/certs/inferencebar-key.pem"

        var llama = ServerProfile(); llama.backend = .llamaCPP
        let llamaArgs = llama.arguments(network: settings)
        XCTAssertTrue(llamaArgs.contains("--ssl-cert-file"))
        XCTAssertTrue(llamaArgs.contains("--ssl-key-file"))

        var mlx = ServerProfile(); mlx.backend = .mlxLM
        XCTAssertFalse(mlx.arguments(network: settings).contains("--ssl-cert-file"), "TLS is only ever wired up for llama.cpp")

        var vllm = ServerProfile(); vllm.backend = .vllmMLX
        XCTAssertFalse(vllm.arguments(network: settings).contains("--ssl-cert-file"))
    }

    func testTLSFlagsNeedBothCertificateAndKeyPaths() {
        var settings = GlobalServerSettings()
        settings.sslCertPath = "~/certs/inferencebar.pem"
        // sslKeyPath deliberately left empty.
        let args = ServerProfile().arguments(network: settings)
        XCTAssertFalse(args.contains("--ssl-cert-file"), "A certificate with no key isn't usable TLS and shouldn't be passed at all")
    }

    // MARK: - mmproj wiring (llama.cpp vision models only)

    func testMMProjIsPassedWhenASiblingProjectorFileExists() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("qwen3-vl.gguf")
        let projector = root.appendingPathComponent("mmproj-qwen3-vl.gguf")
        try Data([0]).write(to: model)
        try Data([0]).write(to: projector)
        let args = ServerProfile(modelPath: model.path).arguments(network: GlobalServerSettings())
        XCTAssertEqual(args.firstIndex(of: "--mmproj").map { args[$0 + 1] }, projector.path)
    }

    func testMMProjIsOmittedWithoutASiblingProjectorFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("plain-text-model.gguf")
        try Data([0]).write(to: model)
        XCTAssertFalse(ServerProfile(modelPath: model.path).arguments(network: GlobalServerSettings()).contains("--mmproj"))
    }

    func testMMProjIsNeverPassedForMLXOrVLLMEvenWithASiblingProjectorFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("model.gguf")
        try Data([0]).write(to: model)
        try Data([0]).write(to: root.appendingPathComponent("mmproj-model.gguf"))
        var mlx = ServerProfile(modelPath: model.path); mlx.backend = .mlxLM
        XCTAssertFalse(mlx.arguments(network: GlobalServerSettings()).contains("--mmproj"), "mmproj is a llama.cpp-only flag")
        var vllm = ServerProfile(modelPath: model.path); vllm.backend = .vllmMLX
        XCTAssertFalse(vllm.arguments(network: GlobalServerSettings()).contains("--mmproj"))
    }

    // MARK: - Keychain-backed API key

    func testAPIKeyOnlyAppearsWhenAuthenticationIsEnabledAndNonEmpty() {
        var settings = GlobalServerSettings()
        settings.authenticationEnabled = true
        settings.apiKey = ""
        XCTAssertFalse(ServerProfile().arguments(network: settings).contains("--api-key"), "An enabled toggle with no key typed yet shouldn't pass an empty key")

        settings.apiKey = "sk-example"
        let args = ServerProfile().arguments(network: settings)
        XCTAssertEqual(args[args.firstIndex(of: "--api-key")! + 1], "sk-example")

        settings.authenticationEnabled = false
        XCTAssertFalse(ServerProfile().arguments(network: settings).contains("--api-key"), "Disabling authentication should drop the key even if one is still typed in")
    }

    func testAPIKeyIsWiredUpForLlamaCPPAndVLLMButNotMLX() {
        var settings = GlobalServerSettings()
        settings.authenticationEnabled = true
        settings.apiKey = "sk-example"

        var llama = ServerProfile(); llama.backend = .llamaCPP
        XCTAssertTrue(llama.arguments(network: settings).contains("--api-key"))

        var mlx = ServerProfile(); mlx.backend = .mlxLM
        XCTAssertFalse(mlx.arguments(network: settings).contains("--api-key"), "mlx_lm.server has no API-key flag to pass one to")

        var vllm = ServerProfile(); vllm.backend = .vllmMLX
        XCTAssertTrue(vllm.arguments(network: settings).contains("--api-key"))
    }
}
