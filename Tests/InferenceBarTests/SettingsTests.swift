import Foundation
import XCTest
@testable import InferenceBar

/// Tests for the Settings window's network, TLS, and appearance logic.
///
/// This used to be an `InferenceBarUITests` file that drove the real
/// Settings window with `XCUIApplication`. SwiftPM has no product type for
/// an Xcode-style "UI Testing Bundle" (only plain unit-test bundles), and
/// `XCUIApplication` refuses to run outside one — "Device is not
/// configured for UI testing" — so those tests could never actually pass
/// under `swift test` / `make macos-test`, no matter how the app under test
/// was launched. Rewritten to test the real state and pure logic the
/// Settings window is a view onto instead: `GlobalServerSettings` (the
/// network/TLS/authentication fields) and the appearance enums, all of
/// which are plain, side-effect-free value types safe to exercise directly.
final class SettingsTests: XCTestCase {

    // MARK: - Network exposure

    func testEffectiveListenAddressFallsBackToLoopbackWhenNetworkDisabled() {
        var settings = GlobalServerSettings()
        settings.listenAddress = "0.0.0.0"
        XCTAssertEqual(settings.effectiveListenAddress, "127.0.0.1", "Disabled network access should never bind beyond loopback")
        settings.networkEnabled = true
        XCTAssertEqual(settings.effectiveListenAddress, "0.0.0.0")
    }

    func testClientHostNormalizesWildcardAddressesToLoopback() {
        var settings = GlobalServerSettings()
        settings.networkEnabled = true
        settings.listenAddress = "0.0.0.0"
        XCTAssertEqual(settings.clientHost, "127.0.0.1", "The client-facing host can't dial a wildcard bind address")
        settings.listenAddress = "::"
        XCTAssertEqual(settings.clientHost, "127.0.0.1")
        settings.listenAddress = "192.168.1.20"
        XCTAssertEqual(settings.clientHost, "192.168.1.20")
    }

    func testExposedWithoutAuthenticationOnlyWhenNetworkOnAndAuthOff() {
        var settings = GlobalServerSettings()
        XCTAssertFalse(settings.exposedWithoutAuthentication, "Network access is off by default")
        settings.networkEnabled = true
        XCTAssertTrue(settings.exposedWithoutAuthentication, "Network open with no API key is exactly the risky case Settings should flag")
        settings.authenticationEnabled = true
        XCTAssertFalse(settings.exposedWithoutAuthentication, "Requiring an API key closes the exposure")
    }

    // MARK: - TLS

    func testTLSConfiguredRequiresBothCertificateAndKey() {
        var settings = GlobalServerSettings()
        XCTAssertFalse(settings.tlsConfigured)
        settings.sslCertPath = "~/certs/inferencebar.pem"
        XCTAssertFalse(settings.tlsConfigured, "A certificate with no matching key isn't usable TLS")
        settings.sslKeyPath = "~/certs/inferencebar-key.pem"
        XCTAssertTrue(settings.tlsConfigured)
    }

    func testBaseURLOnlyUsesHTTPSForLlamaCPPWithTLSConfigured() {
        var settings = GlobalServerSettings()
        settings.port = 8080
        settings.sslCertPath = "~/cert.pem"
        settings.sslKeyPath = "~/key.pem"
        XCTAssertEqual(settings.baseURL(runtime: .llamaCPP)?.scheme, "https", "TLS is only ever wired up for llama.cpp")
        XCTAssertEqual(settings.baseURL(runtime: .mlxLM)?.scheme, "http", "mlx_lm.server is never asked to enable TLS, regardless of these settings")
        XCTAssertEqual(settings.baseURL(runtime: .vllmMLX)?.scheme, "http", "vllm-mlx is never asked to enable TLS, regardless of these settings")
    }

    // MARK: - The API key never round-trips through the plain settings file

    func testDecodingGlobalServerSettingsNeverPopulatesTheAPIKeyField() throws {
        // The API key lives in the keychain (see AppStore's APIKeyKeychain),
        // never in the plain-JSON settings file — CodingKeys deliberately
        // omits it, so even a JSON payload that includes one is ignored.
        let json = #"{"networkEnabled":true,"listenAddress":"0.0.0.0","port":9090,"authenticationEnabled":true,"apiKey":"should-never-load","sslCertPath":"","sslKeyPath":""}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(GlobalServerSettings.self, from: json)
        XCTAssertEqual(decoded.apiKey, "", "apiKey must never be populated by decoding the settings file")
        XCTAssertEqual(decoded.port, 9090)
        XCTAssertTrue(decoded.authenticationEnabled)
    }

    func testEncodingGlobalServerSettingsNeverWritesTheAPIKeyField() throws {
        var settings = GlobalServerSettings()
        settings.apiKey = "super-secret-value"
        let data = try JSONEncoder().encode(settings)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("super-secret-value"), "Encoding must never leak the API key into the plain settings file")
        XCTAssertFalse(text.contains("apiKey"), "The apiKey key itself should not appear at all")
    }

    func testMissingFieldsDecodeToTheirDefaults() throws {
        // An older settings.json saved before a field existed should still
        // decode cleanly rather than failing the whole app launch.
        let decoded = try JSONDecoder().decode(GlobalServerSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, GlobalServerSettings())
    }

    // MARK: - Appearance

    func testEveryThemeDeclaresAConcreteOrSystemColorScheme() {
        for theme in AppTheme.allCases {
            switch theme {
            case .system:
                XCTAssertNil(theme.colorScheme, "System should track the OS setting rather than force one")
            case .light, .catppuccinLatte:
                XCTAssertEqual(theme.colorScheme, .light, "\(theme.rawValue) should render as a light theme")
            default:
                XCTAssertEqual(theme.colorScheme, .dark, "\(theme.rawValue) should render as a dark theme")
            }
        }
    }

    func testThemeCasesHaveUniqueRawValues() {
        let rawValues = AppTheme.allCases.map(\.rawValue)
        XCTAssertEqual(Set(rawValues).count, rawValues.count, "Duplicate theme names would collide in the theme picker's identifiers")
        XCTAssertEqual(AppTheme.allCases.count, 10)
    }

    func testMenuBarIconStyleHasExactlyTheThreeDocumentedOptions() {
        XCTAssertEqual(Set(MenuBarIconStyle.allCases.map(\.rawValue)), ["Match System", "Colour", "Monochrome"])
    }
}
