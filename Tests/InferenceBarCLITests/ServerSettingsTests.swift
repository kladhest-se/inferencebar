import Foundation
import XCTest
@testable import InferenceBarCLI

final class ServerSettingsTests: XCTestCase {
    private func write(_ json: [String: Any]) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let data = try! JSONSerialization.data(withJSONObject: json)
        try! data.write(to: url)
        return url
    }

    override func tearDown() {
        // Best-effort cleanup of any temp files this test wrote.
        super.tearDown()
    }

    func testLoadFromMissingFileReturnsDefaults() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("does-not-exist-\(UUID().uuidString).json")
        let settings = ServerSettings.load(from: url)
        XCTAssertEqual(settings, ServerSettings())
    }

    func testLoadFromMalformedFileReturnsDefaults() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try! Data("not json".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(ServerSettings.load(from: url), ServerSettings())
    }

    func testLoadReadsOnlyPresentKeys() {
        let url = write(["port": 9090, "networkEnabled": true])
        defer { try? FileManager.default.removeItem(at: url) }
        let settings = ServerSettings.load(from: url)
        XCTAssertEqual(settings.port, 9090)
        XCTAssertTrue(settings.networkEnabled)
        // Untouched fields keep their defaults.
        XCTAssertEqual(settings.listenAddress, "0.0.0.0")
        XCTAssertFalse(settings.authenticationEnabled)
    }

    func testLoadReadsAllFields() {
        let url = write([
            "networkEnabled": true,
            "listenAddress": "192.168.1.5",
            "port": 4242,
            "authenticationEnabled": true,
            "sslCertPath": "/tmp/cert.pem",
            "sslKeyPath": "/tmp/key.pem",
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let settings = ServerSettings.load(from: url)
        XCTAssertTrue(settings.networkEnabled)
        XCTAssertEqual(settings.listenAddress, "192.168.1.5")
        XCTAssertEqual(settings.port, 4242)
        XCTAssertTrue(settings.authenticationEnabled)
        XCTAssertEqual(settings.sslCertPath, "/tmp/cert.pem")
        XCTAssertEqual(settings.sslKeyPath, "/tmp/key.pem")
    }

    func testClientHostWhenNetworkDisabledIsAlwaysLoopback() {
        var settings = ServerSettings()
        settings.networkEnabled = false
        settings.listenAddress = "192.168.1.5"
        XCTAssertEqual(settings.clientHost, "127.0.0.1")
    }

    func testClientHostRewritesWildcardAddresses() {
        var settings = ServerSettings()
        settings.networkEnabled = true
        settings.listenAddress = "0.0.0.0"
        XCTAssertEqual(settings.clientHost, "127.0.0.1")
        settings.listenAddress = "::"
        XCTAssertEqual(settings.clientHost, "127.0.0.1")
    }

    func testClientHostPassesThroughASpecificAddress() {
        var settings = ServerSettings()
        settings.networkEnabled = true
        settings.listenAddress = "192.168.1.5"
        XCTAssertEqual(settings.clientHost, "192.168.1.5")
    }

    func testTLSConfiguredRequiresBothPaths() {
        var settings = ServerSettings()
        XCTAssertFalse(settings.tlsConfigured)
        settings.sslCertPath = "/tmp/cert.pem"
        XCTAssertFalse(settings.tlsConfigured)
        settings.sslKeyPath = "/tmp/key.pem"
        XCTAssertTrue(settings.tlsConfigured)
    }

    func testCandidateBaseURLsWithoutTLSIsHTTPOnly() {
        var settings = ServerSettings()
        settings.port = 8080
        let candidates = settings.candidateBaseURLs(host: "127.0.0.1")
        XCTAssertEqual(candidates.map(\.absoluteString), ["http://127.0.0.1:8080"])
    }

    func testCandidateBaseURLsWithTLSTriesHTTPSFirst() {
        var settings = ServerSettings()
        settings.sslCertPath = "/tmp/cert.pem"
        settings.sslKeyPath = "/tmp/key.pem"
        settings.port = 8080
        let candidates = settings.candidateBaseURLs(host: "127.0.0.1")
        XCTAssertEqual(candidates.map(\.absoluteString), ["https://127.0.0.1:8080", "http://127.0.0.1:8080"])
    }

    func testCandidateBaseURLsHonorsExplicitHostAndPortOverrides() {
        var settings = ServerSettings()
        settings.networkEnabled = true
        settings.listenAddress = "192.168.1.5"
        settings.port = 8080
        let candidates = settings.candidateBaseURLs(host: "example.local", port: 9999)
        XCTAssertEqual(candidates.map(\.absoluteString), ["http://example.local:9999"])
    }
}
