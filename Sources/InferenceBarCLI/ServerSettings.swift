import Foundation

/// A minimal, standalone re-reading of InferenceBar.app's own
/// server-settings.json. This CLI is a separate executable target (see
/// Package.swift) — it can't import GlobalServerSettings from the app
/// target directly — so this mirrors just the handful of fields needed
/// to reach whatever server the app currently has running. Keep in sync
/// by hand with GlobalServerSettings in Sources/InferenceBar/Models.swift
/// if that JSON shape ever changes.
struct ServerSettings: Equatable {
    var networkEnabled = false
    var listenAddress = "0.0.0.0"
    var port = 8080
    var authenticationEnabled = false
    var sslCertPath = ""
    var sslKeyPath = ""

    static let defaultSettingsURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("InferenceBar", isDirectory: true)
        .appendingPathComponent("server-settings.json")

    /// A missing key, or a missing/unreadable file entirely, falls back
    /// to the same defaults GlobalServerSettings itself uses — this file
    /// only ever holds whichever subset of these fields the user has
    /// actually changed from InferenceBar's own defaults, and no file at
    /// all (nothing changed yet, or the app has never run) means those
    /// defaults are exactly right.
    static func load(from url: URL = defaultSettingsURL) -> ServerSettings {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ServerSettings() }
        var settings = ServerSettings()
        if let value = json["networkEnabled"] as? Bool { settings.networkEnabled = value }
        if let value = json["listenAddress"] as? String { settings.listenAddress = value }
        if let value = json["port"] as? Int { settings.port = value }
        if let value = json["authenticationEnabled"] as? Bool { settings.authenticationEnabled = value }
        if let value = json["sslCertPath"] as? String { settings.sslCertPath = value }
        if let value = json["sslKeyPath"] as? String { settings.sslKeyPath = value }
        return settings
    }

    /// Mirrors GlobalServerSettings.clientHost: "0.0.0.0"/"::" can only
    /// be bound to, not dialed as a destination, so a request always
    /// targets loopback in that case — and whenever network access is
    /// off, the server can only be listening on loopback anyway.
    var clientHost: String {
        guard networkEnabled else { return "127.0.0.1" }
        return (listenAddress == "0.0.0.0" || listenAddress == "::") ? "127.0.0.1" : listenAddress
    }

    var tlsConfigured: Bool { !sslCertPath.isEmpty && !sslKeyPath.isEmpty }

    /// Candidate base URLs to try, in order. TLS is only ever wired up
    /// for the llama.cpp backend (see ServerProfile.arguments(network:)
    /// in the app) — mlx_lm.server and vllm-mlx always stay http
    /// regardless of these settings — and this CLI has no way to know
    /// which runtime is currently running: that's in-memory-only state
    /// (AppStore.runningProfileID) the app never persists to disk. So
    /// when TLS is configured, https is tried first (the common case
    /// once someone has actually turned it on), falling back to plain
    /// http for the other two runtimes; when it isn't configured, only
    /// http is ever a real answer.
    func candidateBaseURLs(host: String? = nil, port: Int? = nil) -> [URL] {
        let host = host ?? clientHost
        let port = port ?? self.port
        guard tlsConfigured else { return [URL(string: "http://\(host):\(port)")].compactMap { $0 } }
        return [URL(string: "https://\(host):\(port)"), URL(string: "http://\(host):\(port)")].compactMap { $0 }
    }
}
