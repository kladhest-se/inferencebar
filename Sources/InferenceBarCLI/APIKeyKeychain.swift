import Foundation
import Security

/// Reads the server API key InferenceBar.app stores in the login
/// keychain — see APIKeyKeychain in Sources/InferenceBar/AppStore.swift,
/// duplicated here (read-only; this CLI never writes the key) rather
/// than shared, since this is a separate executable target and the app
/// doesn't expose a library product to depend on. Keep the service and
/// account strings in sync with that copy by hand.
///
/// A keychain item's default access control only allows the application
/// that created it to read it back without prompting. Because this CLI
/// is a different binary from InferenceBar.app, the very first read can
/// pop a macOS keychain permission dialog in an interactive session, and
/// will just fail quietly (returning "") with no GUI session to answer
/// it in (SSH, a scheduled script, cron). INFERENCE_API_KEY is the
/// reliable path for scripted/headless use once authentication is on.
enum APIKeyKeychain {
    private static let service = "local.inferencebar.app"
    private static let account = "server-api-key"

    static func load() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let key = String(data: data, encoding: .utf8) else { return "" }
        return key
    }
}
