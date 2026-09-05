import Foundation
import XCTest
@testable import InferenceBar

/// Tests for what a server profile's editor fields actually control: the
/// command-line arguments a profile builds for its runtime process.
///
/// Previously an `InferenceBarUITests` file driving the real Profile
/// Management window with `XCUIApplication`. As explained in
/// SettingsTests.swift, SwiftPM has no UI-Testing-Bundle product type, so
/// those tests could never actually run under `swift test`. Rewritten to
/// test `ServerProfile.arguments(network:)` — the pure function every
/// editor field (runtime, model path, alias, context size, parallelism,
/// flash attention, Jinja templates, RAM cache) ultimately feeds into, and
/// which differs meaningfully across the three supported runtimes. The
/// reasoning/cache-reuse/SWA/TLS/API-key fields added in a later pass have
/// their own coverage in NewFeaturesTests.swift.
final class ProfileManagementTests: XCTestCase {

    func testInferenceBackendTitleAndExecutableMapping() {
        XCTAssertEqual(InferenceBackend.llamaCPP.title, "llama.cpp · GGUF")
        XCTAssertEqual(InferenceBackend.llamaCPP.defaultExecutable, "llama-server")
        XCTAssertTrue(InferenceBackend.llamaCPP.usesGGUF)

        XCTAssertEqual(InferenceBackend.mlxLM.title, "Apple MLX · mlx-lm")
        XCTAssertEqual(InferenceBackend.mlxLM.defaultExecutable, "mlx_lm.server")
        XCTAssertFalse(InferenceBackend.mlxLM.usesGGUF)

        XCTAssertEqual(InferenceBackend.vllmMLX.title, "vLLM-MLX")
        XCTAssertEqual(InferenceBackend.vllmMLX.defaultExecutable, "vllm-mlx")
        XCTAssertFalse(InferenceBackend.vllmMLX.usesGGUF)
    }

    func testNewProfileDefaultsToLlamaCPP() {
        XCTAssertEqual(ServerProfile().runtime, .llamaCPP, "A profile with no backend chosen yet should default to llama.cpp")
    }

    func testLlamaCPPArgumentsCarryIdentityAndRuntimeFields() {
        var profile = ServerProfile()
        profile.modelPath = "/models/model.gguf"
        profile.alias = "my-model"
        profile.contextSize = 32_768
        profile.parallel = 4
        profile.flashAttention = false
        profile.jinja = false
        let args = profile.arguments(network: GlobalServerSettings())

        XCTAssertTrue(args.contains("--model"))
        XCTAssertEqual(args[args.firstIndex(of: "--model")! + 1], "/models/model.gguf")
        XCTAssertEqual(args[args.firstIndex(of: "--alias")! + 1], "my-model")
        XCTAssertEqual(args[args.firstIndex(of: "--ctx-size")! + 1], "32768")
        XCTAssertEqual(args[args.firstIndex(of: "--parallel")! + 1], "4")
        XCTAssertEqual(args[args.firstIndex(of: "--flash-attn")! + 1], "off")
        XCTAssertTrue(args.contains("--slots"), "llama-server should always be started with slot introspection enabled")
        XCTAssertFalse(args.contains("--jinja"), "Disabling Jinja templates should drop the flag entirely, not pass an explicit off value")
    }

    func testJinjaFlagOnlyAppearsWhenEnabled() {
        var enabled = ServerProfile()
        enabled.jinja = true
        XCTAssertTrue(enabled.arguments(network: GlobalServerSettings()).contains("--jinja"))

        var disabled = ServerProfile()
        disabled.jinja = false
        XCTAssertFalse(disabled.arguments(network: GlobalServerSettings()).contains("--jinja"))
    }

    func testNetworkHostAndPortAreAlwaysPassedThrough() {
        var settings = GlobalServerSettings()
        settings.networkEnabled = true
        settings.listenAddress = "0.0.0.0"
        settings.port = 9999
        let args = ServerProfile().arguments(network: settings)
        XCTAssertEqual(args[args.firstIndex(of: "--host")! + 1], "0.0.0.0")
        XCTAssertEqual(args[args.firstIndex(of: "--port")! + 1], "9999")
    }

    func testRAMCacheFlagDiffersPerRuntimeAndIsOmittedWhenZero() {
        var llama = ServerProfile(); llama.backend = .llamaCPP; llama.cacheRAM = 512
        XCTAssertTrue(llama.arguments(network: GlobalServerSettings()).contains("--cache-ram"))

        var mlx = ServerProfile(); mlx.backend = .mlxLM; mlx.cacheRAM = 512
        let mlxArgs = mlx.arguments(network: GlobalServerSettings())
        XCTAssertTrue(mlxArgs.contains("--prompt-cache-size"))
        XCTAssertFalse(mlxArgs.contains("--cache-ram"), "mlx_lm.server doesn't understand llama.cpp's cache flag")

        var vllm = ServerProfile(); vllm.backend = .vllmMLX; vllm.cacheRAM = 512
        let vllmArgs = vllm.arguments(network: GlobalServerSettings())
        XCTAssertTrue(vllmArgs.contains("--cache-memory-mb"))

        var zeroCache = ServerProfile(); zeroCache.backend = .llamaCPP; zeroCache.cacheRAM = 0
        XCTAssertFalse(zeroCache.arguments(network: GlobalServerSettings()).contains("--cache-ram"), "A zero RAM cache should be omitted rather than passed as 0")
    }

    func testMLXConcurrencyFlagsMirrorTheParallelRequestsSetting() {
        var profile = ServerProfile(); profile.backend = .mlxLM; profile.parallel = 6
        let args = profile.arguments(network: GlobalServerSettings())
        XCTAssertEqual(args[args.firstIndex(of: "--decode-concurrency")! + 1], "6")
        XCTAssertEqual(args[args.firstIndex(of: "--prompt-concurrency")! + 1], "6")
    }

    func testVLLMMLXUsesAServeSubcommandInsteadOfAModelFlag() {
        var profile = ServerProfile(); profile.backend = .vllmMLX; profile.modelPath = "mlx-community/Example-4bit"
        let args = profile.arguments(network: GlobalServerSettings())
        XCTAssertEqual(args.first, "serve", "vllm-mlx takes its model as a positional argument to `serve`, not --model")
        XCTAssertEqual(args[1], "mlx-community/Example-4bit")
        XCTAssertFalse(args.contains("--model"))
    }

    func testExtraArgumentsAreSplitOnWhitespaceAndAppendedLast() {
        var profile = ServerProfile()
        profile.extraArguments = "--verbose  --log-format json"
        let args = profile.arguments(network: GlobalServerSettings())
        XCTAssertEqual(Array(args.suffix(3)), ["--verbose", "--log-format", "json"])
    }

    // MARK: - effectiveSystemPrompt

    func testEffectiveSystemPromptFallsBackWhenNilByDefault() {
        XCTAssertEqual(ServerProfile().effectiveSystemPrompt(fallback: "Default prompt."), "Default prompt.", "A fresh profile has no override yet")
    }

    func testEffectiveSystemPromptFallsBackWhenBlank() {
        var profile = ServerProfile()
        profile.systemPrompt = "   \n  "
        XCTAssertEqual(profile.effectiveSystemPrompt(fallback: "Default prompt."), "Default prompt.", "Turning the override on but leaving it empty should still use the default")
    }

    func testEffectiveSystemPromptUsesTheProfilesOwnOverrideWhenSet() {
        var profile = ServerProfile()
        profile.systemPrompt = "You are a terse Swift code reviewer. Answer only in Swedish."
        XCTAssertEqual(profile.effectiveSystemPrompt(fallback: "Default prompt."), "You are a terse Swift code reviewer. Answer only in Swedish.")
    }

    func testEffectiveSystemPromptTrimsWhitespaceAroundAnOverride() {
        var profile = ServerProfile()
        profile.systemPrompt = "  Be concise.  "
        XCTAssertEqual(profile.effectiveSystemPrompt(fallback: "Default prompt."), "Be concise.")
    }
}
