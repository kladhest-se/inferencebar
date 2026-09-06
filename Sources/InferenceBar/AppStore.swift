import AppKit
import CryptoKit
import Darwin
import Foundation
import Observation
import Security
import UniformTypeIdentifiers
import UserNotifications

// InferenceBar is a menu-bar-only (LSUIElement) app with no Dock icon or
// always-visible window, so a crash or a finished download can easily
// happen while nobody is looking at the menu bar. These post a local
// notification for exactly those two moments; everything else stays as
// quiet as it already was.
enum AppNotifications {
    static func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}

// Stores the server API key in the login keychain rather than alongside the
// rest of GlobalServerSettings in server-settings.json on disk. The key is
// a bearer credential — anything that can read that plain JSON file could
// otherwise lift it and use it against a network-exposed profile.
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
              let data = item as? Data, let key = String(data: data, encoding: .utf8) else {
            return ""
        }
        return key
    }

    static func save(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        guard !key.isEmpty else { SecItemDelete(query as CFDictionary); return }
        let data = Data(key.utf8)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        } else {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }
}

/// An image staged in the composer but not yet sent — already decoded,
/// downscaled, and re-encoded (see AppStore.ingestImageData) so `data`
/// is exactly what will be written to disk and base64-encoded if this
/// message is sent, and `thumbnail` is ready to draw in the attachment
/// strip without another decode.
struct PendingChatImageAttachment: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    let data: Data
    let mimeType: String
    let thumbnail: NSImage
    var byteCount: Int { data.count }
}

@MainActor
@Observable
final class AppStore {
    // The running app's own marketing version (Info.plist's
    // CFBundleShortVersionString), so the update checker always compares
    // against what's actually installed rather than a literal that has to
    // be remembered and bumped by hand alongside every release.
    static let appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    // Sent as the system message for any profile that doesn't override it
    // (see ServerProfile.effectiveSystemPrompt) and shown pre-filled in
    // Settings so "Reset to default" has something to reset to.
    static let defaultSystemPromptText = "You are InferenceBar, a helpful conversational assistant running locally on the user's Mac. Answer the user's actual request directly. For simple greetings, respond naturally and briefly. Do not generate websites, HTML, or source code unless explicitly asked."

    struct DownloadJob: Identifiable, Codable {
        let id: String
        let modelID: String
        let file: String
        var phase = "Preparing"
        var progress = 0.0
        var received: Int64 = 0
        var total: Int64 = 0
        var speed = 0.0
        var isPaused = false
        var backend: InferenceBackend = .llamaCPP
        var destination: String = ""
        var ownerProfileID: UUID? = nil
    }
    static let shared = AppStore()
    var profiles: [ServerProfile] = [] { didSet { saveProfiles() } }
    var selectedProfileID: UUID?
    var runningProfileID: UUID?
    // Everything written here also lands on disk (see persistLogChange
    // below) before this in-memory copy is capped, so a long session never
    // loses history to memory pressure, and a crash mid-session still
    // leaves the record on disk even if nobody had the Logs window open.
    var logs = "" {
        didSet {
            guard !isApplyingLogCap else { return }
            persistLogChange(from: oldValue, to: logs)
            capLogsInMemoryIfNeeded()
        }
    }
    var searchQuery = ""
    var modelCategory: ModelCategory = .trending
    var modelCatalogBackend: InferenceBackend = .llamaCPP
    var searchResults: [HFModel] = []
    var selectedModel: HFModel?
    var modelFiles: [String] = []
    var modelFileSizes: [String: Int64] = [:]
    var modelManifestEntries: [ModelManifestEntry] = []
    var isSearching = false
    var isLoadingFiles = false
    var downloadStatus = ""
    var downloadModelName = ""
    var downloadPhase = "" {
        didSet {
            guard downloadPhase == "Completed", oldValue != "Completed" else { return }
            AppNotifications.post(title: "Download complete", body: downloadModelName.isEmpty ? "A model finished downloading." : downloadModelName)
        }
    }
    var downloadOwnerProfileID: UUID?
    var downloadBackend: InferenceBackend?
    var downloadProgress = 0.0
    var downloadedBytes: Int64 = 0
    var downloadTotalBytes: Int64 = 0
    var downloadBytesPerSecond = 0.0
    var downloadCompletedFiles = 0
    var downloadTotalFiles = 0
    var isDownloading = false
    var isResolvingDownload = false
    var isDownloadPaused = false
    var downloadJobs: [String: DownloadJob] = [:] { didSet { saveDownloadQueue() } }
    var messages: [ChatMessage] = [] { didSet { updateActiveChat() } }
    var chats: [SavedChat] = [] { didSet { saveChats() } }
    var chatProjects: [ChatProject] = [] { didSet { saveChatProjects() } }
    var activeChatID: UUID?
    @ObservationIgnored private var activeChatStartedAt: Date?
    var prompt = ""
    var pendingChatAttachments: [PendingChatAttachment] = []
    var pendingChatImageAttachments: [PendingChatImageAttachment] = []
    @ObservationIgnored private var chatGenerationTask: Task<Void, Never>?
    // Set once eraseAllServerSlots() learns the running server was
    // launched without --slot-save-path (which InferenceBar never sets),
    // so every subsequent message skips the always-failing erase attempt
    // instead of retrying — and logging — it every single time. Nothing
    // in the UI reads this, so it's excluded from Observation tracking
    // like chatGenerationTask above.
    @ObservationIgnored private var slotEraseUnsupported = false
    var isSending = false {
        didSet { NotificationCenter.default.post(name: .inferenceServerLifecycleChanged, object: nil) }
    }
    var engineActivity: EngineActivity = .idle {
        didSet { NotificationCenter.default.post(name: .inferenceServerLifecycleChanged, object: nil) }
    }
    var errorMessage: String?
    var networkSettings = GlobalServerSettings() { didSet { saveNetworkSettings() } }
    var serverLifecycle: ServerLifecycle = .stopped {
        didSet {
            NotificationCenter.default.post(name: .inferenceServerLifecycleChanged, object: nil)
            // Deliberately doesn't name the profile here: failedProfileID and
            // runningProfileID aren't reliably updated before serverLifecycle
            // at every call site that sets .failed, so this only uses what's
            // guaranteed correct at this exact instant — the case itself.
            if case .failed(let reason) = serverLifecycle, oldValue != serverLifecycle {
                AppNotifications.post(title: "InferenceBar server stopped", body: reason)
            }
            // A run that actually reaches "running" earns a fresh retry
            // budget — only a crash loop (never reaching running) should
            // exhaust maxCrashRestartAttempts.
            if serverLifecycle == .running { crashRestartAttempts = 0 }
        }
    }
    var failedProfileID: UUID?
    var runtimeMemoryBytes: Int64 = 0
    var runtimeStartedAt: Date?
    var compatibilityReport: ModelPreflightReport?
    var favoriteProfileIDs: Set<UUID> = [] { didSet { saveFavorites() } }
    var defaultProfileID = UserDefaults.standard.string(forKey: "defaultProfileID").flatMap(UUID.init(uuidString:)) {
        didSet {
            if let defaultProfileID { UserDefaults.standard.set(defaultProfileID.uuidString, forKey: "defaultProfileID") }
            else { UserDefaults.standard.removeObject(forKey: "defaultProfileID") }
        }
    }
    var autoStartDefaultProfile = UserDefaults.standard.bool(forKey: "autoStartDefaultProfile") {
        didSet { UserDefaults.standard.set(autoStartDefaultProfile, forKey: "autoStartDefaultProfile") }
    }
    // Which "Coding"-tagged profile OpenCode should use unless the person
    // picks a different one themselves in its own /models picker -- see
    // syncCodingProfilesToOpenCode(), which writes this as opencode.json's
    // top-level "model" field. Distinct from defaultProfileID above,
    // which is InferenceBar's own auto-start-on-launch profile and has
    // nothing to do with OpenCode.
    var defaultCodingProfileID = UserDefaults.standard.string(forKey: "defaultCodingProfileID").flatMap(UUID.init(uuidString:)) {
        didSet {
            if let defaultCodingProfileID { UserDefaults.standard.set(defaultCodingProfileID.uuidString, forKey: "defaultCodingProfileID") }
            else { UserDefaults.standard.removeObject(forKey: "defaultCodingProfileID") }
        }
    }
    // Off by default: registering a global key monitor is exactly the kind
    // of thing that should be opt-in, not something a fresh install starts
    // doing silently. InferenceBarDelegate observes .inferenceHotkeySettingChanged
    // to register/unregister the actual NSEvent monitor when this flips.
    var globalHotkeyEnabled = UserDefaults.standard.bool(forKey: "globalHotkeyEnabled") {
        didSet {
            UserDefaults.standard.set(globalHotkeyEnabled, forKey: "globalHotkeyEnabled")
            NotificationCenter.default.post(name: .inferenceHotkeySettingChanged, object: nil)
        }
    }
    // Mirrors GlobalHotkey's own UserDefaults-backed storage into an
    // @Observable stored property so the Settings recorder UI updates
    // live; the write-through keeps InferenceBarDelegate's nonisolated
    // reads (which go straight to GlobalHotkey/UserDefaults, never
    // through AppStore.shared) in sync with whatever's recorded here.
    var hotkeyKeyCode = GlobalHotkey.keyCode {
        didSet {
            GlobalHotkey.keyCode = hotkeyKeyCode
            NotificationCenter.default.post(name: .inferenceHotkeySettingChanged, object: nil)
        }
    }
    var hotkeyModifierFlags = GlobalHotkey.modifierFlags {
        didSet {
            GlobalHotkey.modifierFlags = hotkeyModifierFlags
            NotificationCenter.default.post(name: .inferenceHotkeySettingChanged, object: nil)
        }
    }
    // Off by default, like the hotkey above — sending a user's chat
    // queries out to a search server is exactly the kind of thing that
    // should be opt-in. No notification needed: nothing else in the app
    // reacts to this changing, sendPrompt() just reads it fresh each time.
    var webSearchEnabled = UserDefaults.standard.bool(forKey: "webSearchEnabled") {
        didSet { UserDefaults.standard.set(webSearchEnabled, forKey: "webSearchEnabled") }
    }
    var webSearchSearXNGURL = UserDefaults.standard.string(forKey: "webSearchSearXNGURL") ?? "" {
        didSet { UserDefaults.standard.set(webSearchSearXNGURL, forKey: "webSearchSearXNGURL") }
    }
    // A quick, session-only override shown as a button in the chat
    // window once web search is enabled in Settings — lets the user turn
    // search off for the conversation at hand without touching the
    // Settings toggle. Deliberately not persisted to UserDefaults: it
    // defaults back to on (searching, per Settings) every relaunch,
    // rather than silently staying off from a toggle someone forgot
    // about.
    var webSearchEnabledThisChat = true
    // The app-wide default system prompt, used by any profile that
    // doesn't set its own (see ServerProfile.systemPrompt). Editable in
    // Settings; falls back to Self.defaultSystemPromptText the first
    // time InferenceBar runs.
    var defaultSystemPrompt = UserDefaults.standard.string(forKey: "defaultSystemPrompt") ?? AppStore.defaultSystemPromptText {
        didSet { UserDefaults.standard.set(defaultSystemPrompt, forKey: "defaultSystemPrompt") }
    }
    // Also off by default and independent of webSearchEnabled — a model
    // that can only search still can't read a page the user pastes a
    // link to, and someone may want one capability without the other.
    var fetchURLEnabled = UserDefaults.standard.bool(forKey: "fetchURLEnabled") {
        didSet { UserDefaults.standard.set(fetchURLEnabled, forKey: "fetchURLEnabled") }
    }
    var updateChecksEnabled = UserDefaults.standard.object(forKey: "updateChecksEnabled") == nil ? true : UserDefaults.standard.bool(forKey: "updateChecksEnabled") {
        didSet {
            UserDefaults.standard.set(updateChecksEnabled, forKey: "updateChecksEnabled")
            if updateChecksEnabled { startUpdateMonitoring() } else { updateCheckTask?.cancel(); updateCheckTask = nil; availableUpdateTag = nil }
        }
    }
    var availableUpdateTag: String? { didSet { NotificationCenter.default.post(name: .inferenceServerLifecycleChanged, object: nil) } }
    var lastUpdateCheck: Date?
    var updateCheckError: String?
    var isCheckingForUpdates = false
    var requestedSection: AppSection = .profiles
    var appTheme = AppTheme(rawValue: UserDefaults.standard.string(forKey: "appTheme") ?? "") ?? .system {
        didSet { UserDefaults.standard.set(appTheme.rawValue, forKey: "appTheme"); NotificationCenter.default.post(name: .inferenceAppearanceChanged, object: nil) }
    }
    var menuBarIconStyle = MenuBarIconStyle(rawValue: UserDefaults.standard.string(forKey: "menuBarIconStyle") ?? "") ?? .matchSystem {
        didSet { UserDefaults.standard.set(menuBarIconStyle.rawValue, forKey: "menuBarIconStyle"); NotificationCenter.default.post(name: .inferenceAppearanceChanged, object: nil) }
    }

    private var process: Process?
    private var outputTask: Task<Void, Never>?
    private var readinessTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    // Piggybacks on healthTask's existing per-second poll rather than
    // adding a second timer -- see the loop below. Not read by any UI, so
    // it's excluded from Observation tracking like the other bookkeeping
    // vars near chatGenerationTask above.
    @ObservationIgnored private var lastObservedActiveRequests = 0
    private var stopRequested = false
    var autoRestartOnCrash = UserDefaults.standard.bool(forKey: "autoRestartOnCrash") {
        didSet { UserDefaults.standard.set(autoRestartOnCrash, forKey: "autoRestartOnCrash") }
    }
    private var crashRestartAttempts = 0
    private var crashRestartTask: Task<Void, Never>?
    private var stopForceKillTask: Task<Void, Never>?
    private static let maxCrashRestartAttempts = 5
    private var activeDownloader: DownloadController?
    private var activeDownloaders: [String: DownloadController] = [:]
    private var mlxDownloadProcesses: [String: Process] = [:]
    private var cancelledDownloadJobs: Set<String> = []
    private var completedDownloadJobs: Set<String> = []
    private var mlxDownloadProcess: Process?
    private var downloadCancellationRequested = false
    @ObservationIgnored private var updateCheckTask: Task<Void, Never>?
    private let profilesURL: URL
    private let networkSettingsURL: URL
    private let favoritesURL: URL
    private let chatsURL: URL
    private let chatProjectsURL: URL
    // Where attached images actually live -- see ChatImageAttachment's
    // doc comment for why they're separate files rather than inline
    // base64 in chats.json.
    private let chatImagesDirectory: URL
    private let downloadQueueURL: URL
    let logFileURL: URL
    private let previousLogFileURL: URL
    private var logFileHandle: FileHandle?
    private var isApplyingLogCap = false
    private static let maxInMemoryLogCharacters = 200_000
    private var isLoadingChat = false

    var runtimeHealth: RuntimeHealth {
        let context = profiles.first(where: { $0.id == runningProfileID })?.contextSize ?? 0
        var health = RuntimeTelemetryParser.parse(logs, contextLimit: context)
        health.pid = process?.isRunning == true ? process?.processIdentifier : nil
        health.memoryBytes = runtimeMemoryBytes
        health.uptime = runtimeStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        if serverLifecycle == .running { health.loadingProgress = 1 }
        return health
    }

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("InferenceBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        profilesURL = support.appendingPathComponent("profiles.json")
        networkSettingsURL = support.appendingPathComponent("server-settings.json")
        favoritesURL = support.appendingPathComponent("favorites.json")
        chatsURL = support.appendingPathComponent("chats.json")
        chatProjectsURL = support.appendingPathComponent("chat-projects.json")
        chatImagesDirectory = support.appendingPathComponent("ChatImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: chatImagesDirectory, withIntermediateDirectories: true)
        downloadQueueURL = support.appendingPathComponent("download-queue.json")
        let logsDirectory = support.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        logFileURL = logsDirectory.appendingPathComponent("engine.log")
        previousLogFileURL = logsDirectory.appendingPathComponent("engine.previous.log")
        if let data = try? Data(contentsOf: networkSettingsURL), var saved = try? JSONDecoder().decode(GlobalServerSettings.self, from: data) {
            saved.apiKey = APIKeyKeychain.load()
            networkSettings = saved
        } else {
            networkSettings.apiKey = APIKeyKeychain.load()
        }
        if let data = try? Data(contentsOf: favoritesURL), let saved = try? JSONDecoder().decode(Set<UUID>.self, from: data) { favoriteProfileIDs = saved }
        loadProfiles()
        if let defaultProfileID, !profiles.contains(where: { $0.id == defaultProfileID }) { self.defaultProfileID = nil }
        if let defaultCodingProfileID, !profiles.contains(where: { $0.id == defaultCodingProfileID }) { self.defaultCodingProfileID = nil }
        modelManifestEntries = ModelMetadataManifest.load(from: configuredModelRoot)
        reconcileMLXProfilePaths()
        selectedProfileID = profiles.first?.id
        if let data = try? Data(contentsOf: chatsURL), let saved = try? JSONDecoder().decode([SavedChat].self, from: data) { chats = saved }
        if let data = try? Data(contentsOf: chatProjectsURL), let saved = try? JSONDecoder().decode([ChatProject].self, from: data) { chatProjects = saved }
        pruneOrphanedChatImages()
        if let first = chats.sorted(by: { $0.updatedAt > $1.updatedAt }).first { selectChat(first.id) } else { newChat() }
        loadDownloadQueue()
        Task { [weak self] in await self?.resumePersistedDownloads() }
    }

    var selectedProfileIndex: Int? { profiles.firstIndex { $0.id == selectedProfileID } }
    var selectedProfile: ServerProfile? { selectedProfileIndex.map { profiles[$0] } }
    var isRunning: Bool { process?.isRunning == true }
    var canStartProfile: Bool { !MenuBarLifecyclePresentation.locksProfileSelection(serverLifecycle) && process == nil }
    var favoriteProfiles: [ServerProfile] { profiles.filter { favoriteProfileIDs.contains($0.id) } }
    var availablePresets: [ProfilePreset] { ProfilePreset.all.filter { $0.isAvailable(modelRoot: configuredModelRoot) } }
    // Hardware-gated on purpose only for the not-yet-downloaded side: a
    // preset whose model is already on disk stays offered regardless --
    // it's not this filter's job to second-guess a model the user
    // already has, only to stop recommending (or auto-downloading) one
    // sized for a bigger Mac than this.
    var missingPresets: [ProfilePreset] {
        ProfilePreset.all.filter { !$0.isAvailable(modelRoot: configuredModelRoot) && $0.isSupported(physicalMemoryGB: currentUnifiedMemoryGB) }
    }
    // Counts presets hidden from missingPresets by the hardware check
    // above, so the menu can say *why* the list looks shorter than
    // ProfilePreset.all instead of just silently trimming it.
    var hardwareFilteredPresetCount: Int {
        ProfilePreset.all.filter { !$0.isAvailable(modelRoot: configuredModelRoot) && !$0.isSupported(physicalMemoryGB: currentUnifiedMemoryGB) }.count
    }
    private var currentUnifiedMemoryGB: Int {
        Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
    }
    func downloadedModelOptions(for runtime: InferenceBackend) -> [DownloadedModelOption] {
        DownloadedModelCatalog.scan(root: configuredModelRoot).filter { $0.supports(runtime) }
    }
    var defaultModelPath: String { configuredModelRoot.path }
    var downloadedProfiles: [ServerProfile] {
        profiles.filter { profile in
            if profile.runtime.usesGGUF { return FileManager.default.fileExists(atPath: NSString(string: profile.modelPath).expandingTildeInPath) }
            let expanded = NSString(string: profile.modelPath).expandingTildeInPath
            if FileManager.default.fileExists(atPath: (expanded as NSString).appendingPathComponent("config.json")), mlxWeightsExist(at: URL(fileURLWithPath: expanded)) { return true }
            let repo = "models--" + profile.modelPath.replacingOccurrences(of: "/", with: "--")
            let snapshots = configuredModelRoot.appendingPathComponent("\(repo)/snapshots")
            guard let revisions = try? FileManager.default.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil) else { return false }
            return revisions.contains { revision in
                guard FileManager.default.fileExists(atPath: revision.appendingPathComponent("config.json").path),
                      let files = try? FileManager.default.contentsOfDirectory(at: revision, includingPropertiesForKeys: nil) else { return false }
                return files.contains { $0.pathExtension.lowercased() == "safetensors" && FileManager.default.fileExists(atPath: $0.path) }
            }
        }
    }

    private var configuredModelRoot: URL {
        let configured = UserDefaults.standard.string(forKey: "modelDirectory") ?? "~/ai-models"
        return URL(fileURLWithPath: NSString(string: configured).expandingTildeInPath, isDirectory: true)
    }

    enum CLIInstallOutcome {
        case installed(path: String, onPATH: Bool)
        // This build's app bundle has no embedded CLI binary at all —
        // expected for anyone building straight from source with `swift
        // build` rather than `make macos-app`/`make macos-package`,
        // which are what actually embed it (see the Makefile).
        case bundledBinaryMissing
        case failed(String)
    }

    // Copies the `inference` CLI binary this app bundle ships alongside
    // itself (Contents/Resources/inference) out to wherever
    // CLIInstallPolicy picks, so "inference ask ..." works from an
    // ordinary Terminal without the user hunting for it inside the .app
    // bundle themselves.
    //
    // Tries /usr/local/bin first (macOS's own default PATH entry, so a
    // fresh install rarely needs any PATH editing afterward), asking for
    // one-time admin privileges to place it there when it isn't already
    // writable -- normal on Apple Silicon, where Homebrew lives under
    // /opt/homebrew and never touches /usr/local. Falls back to
    // Homebrew's own bin (no prompt) and finally a per-user directory
    // (also no prompt) if elevation isn't possible or is declined.
    func installCLITool() -> CLIInstallOutcome {
        guard let bundled = Bundle.main.url(forResource: "inference", withExtension: nil) else { return .bundledBinaryMissing }
        let fm = FileManager.default
        let systemBin = CLIInstallPolicy.systemDirectory
        let homebrewBin = CLIInstallPolicy.homebrewDirectory
        let realPATH = loginShellPATH()

        func copy(to destinationDir: String) throws -> String {
            let destination = URL(fileURLWithPath: destinationDir, isDirectory: true).appendingPathComponent("inference")
            try fm.createDirectory(atPath: destinationDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.copyItem(at: bundled, to: destination)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
            return destination.path
        }

        if fm.isWritableFile(atPath: systemBin), let path = try? copy(to: systemBin) {
            return .installed(path: path, onPATH: CLIInstallPolicy.isOnPATH(systemBin, pathEnvironmentVariable: realPATH))
        }
        if installCLIToolWithAdministratorPrivileges(from: bundled, into: systemBin) {
            let destination = URL(fileURLWithPath: systemBin, isDirectory: true).appendingPathComponent("inference").path
            return .installed(path: destination, onPATH: CLIInstallPolicy.isOnPATH(systemBin, pathEnvironmentVariable: realPATH))
        }
        // Elevation wasn't possible or was declined -- fall back exactly
        // as before, without ever forcing a second prompt.
        let destinationDir = CLIInstallPolicy.destinationDirectory(
            homebrewBinIsWritableDirectory: fm.isWritableFile(atPath: homebrewBin),
            homeDirectory: fm.homeDirectoryForCurrentUser.path
        )
        do {
            let path = try copy(to: destinationDir)
            return .installed(path: path, onPATH: CLIInstallPolicy.isOnPATH(destinationDir, pathEnvironmentVariable: realPATH))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // The PATH the user's actual login shell resolves -- not this GUI
    // process's own environment, which launchd populates with a bare
    // default (roughly /usr/bin:/bin:/usr/sbin:/sbin) that omits
    // Homebrew's bin and often even /usr/local/bin, regardless of what
    // a real Terminal session for the same user sees. Spawns the user's
    // $SHELL (falling back to zsh) as an interactive login shell so its
    // profile scripts (.zprofile, .zshrc, etc.) actually run, same as
    // opening Terminal would. Best-effort: falls back to this process's
    // own PATH if the shell can't be started, errors, or hangs.
    private func loginShellPATH() -> String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", "printf %s \"$PATH\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        let fallback = ProcessInfo.processInfo.environment["PATH"] ?? ""
        do {
            try process.run()
        } catch {
            return fallback
        }
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? fallback : output
    }

    // Copies the bundled CLI binary into a system directory (normally
    // /usr/local/bin) with a single admin-privileges prompt, for the
    // common stock-macOS case where it isn't already writable by this
    // user. Uses the same one-line "do shell script ... with
    // administrator privileges" idiom most Mac dev tools use for this
    // (VS Code's "code", Docker Desktop, etc.) rather than installing a
    // persistent privileged helper. Also hands ownership of the
    // directory itself (not its existing contents) to the current user,
    // so a later reinstall or update doesn't need to prompt again.
    // Returns false, without an error alert, if the user cancels the
    // prompt -- the caller falls back quietly from there.
    private func installCLIToolWithAdministratorPrivileges(from bundled: URL, into directory: String) -> Bool {
        let destination = "\(directory)/inference"
        let user = NSUserName()
        let innerCommand = "mkdir -p \"\(directory)\" && chown \"\(user)\":staff \"\(directory)\" && cp \"\(bundled.path)\" \"\(destination)\" && chmod 755 \"\(destination)\""
        let escapedCommand = innerCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escapedCommand)\" with administrator privileges"
        guard let appleScript = NSAppleScript(source: script) else { return false }
        var errorInfo: NSDictionary?
        appleScript.executeAndReturnError(&errorInfo)
        return errorInfo == nil
    }

    func downloadJob(modelID: String, file: String? = nil) -> DownloadJob? {
        downloadJobs.values.first { $0.modelID == modelID && (file == nil || $0.file == file) }
    }

    func modelVersionCounts(for model: HFModel, backend: InferenceBackend) -> (total: Int, downloaded: Int, downloading: Int) {
        if backend != .llamaCPP {
            let downloaded = isMLXModelCached(model.id) ? 1 : 0
            let downloading = downloadJobs.values.contains(where: { $0.modelID == model.id }) ? 1 : 0
            return (1, downloaded, downloading)
        }
        let files = (model.siblings ?? []).map(\.rfilename).filter { $0.lowercased().hasSuffix(".gguf") }
        let knownFiles = files.isEmpty && selectedModel?.id == model.id ? modelFiles : files
        let manifestNames = Set(modelManifestEntries.filter {
            $0.sourceModelID == model.id && FileManager.default.fileExists(atPath: $0.localPath)
        }.map { $0.filename.lowercased() })
        let active = downloadJobs.values.filter { $0.modelID == model.id }
        // A GGUF download pre-allocates its destination file before it
        // finishes (see the ggufFileExists comment in ContentView.swift),
        // so a file with an active job must never also count as
        // "downloaded" -- otherwise the same version briefly shows up in
        // both counts at once.
        let activeFiles = Set(active.map(\.file))
        let downloaded = knownFiles.filter { file in
            guard !activeFiles.contains(file) else { return false }
            let name = URL(fileURLWithPath: file).lastPathComponent
            if manifestNames.contains(name.lowercased()) { return true }
            return FileManager.default.fileExists(atPath: configuredModelRoot.appendingPathComponent(name).path)
        }.count
        return (knownFiles.count, downloaded, active.count)
    }

    private func recordModelMetadata(_ entry: ModelManifestEntry) {
        modelManifestEntries.removeAll { $0.id == entry.id }
        modelManifestEntries.append(entry)
        do { try ModelMetadataManifest.save(modelManifestEntries, to: configuredModelRoot) }
        catch { logs += "Could not save model metadata manifest: \(error.localizedDescription)\n" }
    }

    func toggleDownloadPause(_ id: String) {
        guard var job = downloadJobs[id] else { return }
        job.isPaused.toggle()
        job.phase = job.isPaused ? "Paused" : "Downloading"
        downloadJobs[id] = job
        if let downloader = activeDownloaders[id] { job.isPaused ? downloader.pause() : downloader.resume() }
        if let process = mlxDownloadProcesses[id], process.isRunning { kill(process.processIdentifier, job.isPaused ? SIGSTOP : SIGCONT) }
        if !job.isPaused, activeDownloaders[id] == nil, mlxDownloadProcesses[id] == nil {
            restartPersistedDownload(job)
        }
    }

    func cancelDownload(_ id: String) {
        guard let job = downloadJobs[id] else { return }
        cancelledDownloadJobs.insert(id)
        activeDownloaders[id]?.cancel()
        mlxDownloadProcesses[id]?.terminate()
        if activeDownloaders[id] == nil && mlxDownloadProcesses[id] == nil {
            if !job.destination.isEmpty { DownloadResumeStore.remove(for: URL(fileURLWithPath: job.destination)) }
            downloadJobs.removeValue(forKey: id)
        }
    }

    private func saveDownloadQueue() {
        let jobs = downloadJobs.values.sorted { $0.id < $1.id }
        do { try JSONEncoder().encode(jobs).write(to: downloadQueueURL, options: .atomic) }
        catch { logs += "Could not save download queue: \(error.localizedDescription)\n" }
    }

    private func loadDownloadQueue() {
        guard let data = try? Data(contentsOf: downloadQueueURL),
              let saved = try? JSONDecoder().decode([DownloadJob].self, from: data) else { return }
        let pending = saved.filter { job in
            if job.backend != .llamaCPP, resolvedMLXSnapshot(for: job.modelID) != nil {
                logs += "Reconciled completed MLX download: \(job.modelID)\n"
                return false
            }
            return true
        }
        downloadJobs = Dictionary(uniqueKeysWithValues: pending.map { job in
            var restored = job
            restored.speed = 0
            if !restored.isPaused { restored.phase = "Queued to resume" }
            return (restored.id, restored)
        })
        isDownloading = !downloadJobs.isEmpty
    }

    private func resumePersistedDownloads() async {
        for job in downloadJobs.values where !job.isPaused {
            restartPersistedDownload(job)
        }
    }

    private func restartPersistedDownload(_ job: DownloadJob) {
        downloadJobs.removeValue(forKey: job.id)
        if job.backend == .llamaCPP {
            let model = HFModel(id: job.modelID, downloads: nil, likes: nil, lastModified: nil, pipeline_tag: nil, tags: ["gguf"], usedStorage: nil)
            let directory = job.destination.isEmpty ? configuredModelRoot.path : URL(fileURLWithPath: job.destination).deletingLastPathComponent().path
            Task { await download(file: job.file, from: model, to: directory, ownerProfileID: job.ownerProfileID) }
        } else {
            Task { await downloadMLXModel(job.modelID) }
        }
    }

    func isFavorite(_ id: UUID) -> Bool { favoriteProfileIDs.contains(id) }
    func isDefaultProfile(_ id: UUID) -> Bool { defaultProfileID == id }
    func setDefaultProfile(_ id: UUID?) { defaultProfileID = id }
    func startDefaultProfileIfEnabled() {
        guard DefaultProfileStartupPolicy.shouldStart(enabled: autoStartDefaultProfile, defaultProfileExists: profiles.contains(where: { $0.id == defaultProfileID }), lifecycle: serverLifecycle),
              let defaultProfileID else { return }
        selectedProfileID = defaultProfileID
        start()
    }

    func startUpdateMonitoring() {
        guard updateChecksEnabled, updateCheckTask == nil else { return }
        updateCheckTask = Task { [weak self] in
            await self?.checkForUpdates()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(AppUpdatePolicy.checkInterval))
                guard !Task.isCancelled else { break }
                await self?.checkForUpdates()
            }
        }
    }

    func stopUpdateMonitoring() {
        updateCheckTask?.cancel()
        updateCheckTask = nil
    }

    func checkForUpdates() async {
        guard updateChecksEnabled, !isCheckingForUpdates else { return }
        isCheckingForUpdates = true; updateCheckError = nil
        defer { isCheckingForUpdates = false; lastUpdateCheck = Date() }
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/kladhest-se/inferencebar/tags?per_page=100")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("InferenceBar/\(Self.appVersion)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { throw URLError(.badServerResponse) }
            let tags = try JSONDecoder().decode([GitHubTag].self, from: data).map(\.name)
            availableUpdateTag = AppUpdatePolicy.newestUpdate(tags: tags, currentVersion: Self.appVersion)
        } catch {
            updateCheckError = error.localizedDescription
        }
    }
    func toggleFavorite(_ id: UUID) {
        if favoriteProfileIDs.contains(id) { favoriteProfileIDs.remove(id) }
        else { favoriteProfileIDs.insert(id) }
    }

    func addProfile() {
        var profile = ServerProfile()
        profile.modelPath = configuredModelRoot.path
        profiles.append(profile)
        selectedProfileID = profile.id
    }

    func addMLXProfile(modelID: String, backend: InferenceBackend = .mlxLM) {
        let executable = backend.defaultExecutable
        let alias = backend == .mlxLM ? "default_model" : "default"
        let shortName = modelID.split(separator: "/").last.map(String.init) ?? modelID
        let resolvedPath = resolvedMLXSnapshot(for: modelID)?.path ?? modelID
        let profile = ServerProfile(backend: backend, name: "MLX · \(shortName)", executable: executable, modelPath: resolvedPath, alias: alias, contextSize: 32768, parallel: 1, flashAttention: false, jinja: false, cacheRAM: backend == .mlxLM ? 10 : 0, reasoning: "", reasoningBudget: 0, reasoningFormat: "", reasoningPreserve: false)
        profiles.append(profile)
        selectedProfileID = profile.id
        requestedSection = .profiles
    }

    func addLocalGGUFProfile(path: String) {
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let profile = ServerProfile(name: "GGUF · \(name)", modelPath: path, alias: name.lowercased().replacingOccurrences(of: " ", with: "-"))
        profiles.append(profile)
        selectedProfileID = profile.id
        requestedSection = .profiles
    }

    func addPreset(_ preset: ProfilePreset) {
        var profile = preset.profile
        profile.id = UUID()
        profiles.append(profile)
        selectedProfileID = profile.id
    }

    /// Adds a profile for `preset` and, if its model isn't on disk yet,
    /// immediately starts downloading it -- see `addAllPresets` below
    /// for which presets that covers. Also queues a projector-only
    /// download when the main model is already present but the preset's
    /// `mmprojFilename` isn't satisfied yet (see `hasProjectorAvailable`)
    /// -- otherwise a vision preset added back when this app only ever
    /// downloaded one file per preset stays permanently missing its
    /// mmproj file even after upgrading to a build that knows to fetch it.
    func addPresetStartingDownloadIfNeeded(_ preset: ProfilePreset) {
        addPreset(preset)
        if preset.useCases.contains(.coding) { syncCodingProfilesToOpenCode() }
        guard let ownerProfileID = profiles.last?.id else { return }
        let modelMissing = !preset.isAvailable(modelRoot: configuredModelRoot)
        let projectorMissing = !preset.hasProjectorAvailable(modelRoot: configuredModelRoot)
        guard modelMissing || projectorMissing else { return }
        enqueuePresetDownload(preset, ownerProfileID: ownerProfileID)
    }

    /// Adds a profile for every preset not already represented among
    /// the current profiles (matched by runtime + model path, so
    /// running this again doesn't create duplicates), starting a
    /// download immediately for any whose model isn't on disk yet.
    /// That covers every MLX/vLLM-MLX preset (its modelPath is already
    /// a Hugging Face repo ID) and any GGUF preset with a confirmed
    /// source repo (see ProfilePreset.ggufSourceModelID) -- a GGUF
    /// preset without one still gets added, just without an automatic
    /// download, since guessing at an unconfirmed repo/filename could
    /// silently fetch the wrong file. Skips any preset sized for more
    /// unified memory than this Mac actually has, the same hardware
    /// check missingPresets applies -- this Mac downloading (or even
    /// just being offered) a 192 GB-tier model would be a much bigger
    /// waste of bandwidth and disk than an unconfirmed repo ever is.
    func addAllPresets() {
        for preset in ProfilePreset.all {
            guard preset.isSupported(physicalMemoryGB: currentUnifiedMemoryGB) else { continue }
            if let existingOwnerID = profiles.first(where: { $0.runtime == preset.profile.runtime && $0.modelPath == preset.profile.modelPath })?.id {
                // Already added as a profile in an earlier run -- don't add
                // it again, but a vision preset added before this app knew
                // to fetch its mmproj file may still be missing one, so
                // queue just that backfill against the existing profile.
                if !preset.hasProjectorAvailable(modelRoot: configuredModelRoot) {
                    enqueuePresetDownload(preset, ownerProfileID: existingOwnerID)
                }
                if preset.useCases.contains(.coding) { syncCodingProfilesToOpenCode() }
                continue
            }
            addPresetStartingDownloadIfNeeded(preset)
        }
    }

    static let openCodeConfigDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config", isDirectory: true)
        .appendingPathComponent("opencode", isDirectory: true)
    static let openCodeConfigURL = openCodeConfigDirectory.appendingPathComponent("opencode.json")

    /// Merges every current profile that came from a "Coding"-tagged
    /// preset into OpenCode's config as a custom provider (see
    /// OpenCodeConfigSync), so those models show up in OpenCode without
    /// hand-editing its config file. Called automatically whenever a
    /// coding preset is added (addPresetStartingDownloadIfNeeded/
    /// addAllPresets above) and available as a manual "Sync now" button
    /// in Settings for anyone who added coding presets before this
    /// existed, or whose config needs refreshing after editing a
    /// profile's name/context/alias by hand.
    ///
    /// Deliberately does nothing if OpenCode has never been set up on
    /// this Mac (no ~/.config/opencode directory, and no `opencode`
    /// executable found via Homebrew) -- otherwise every InferenceBar
    /// user who has never heard of OpenCode would get a stray config
    /// directory created the first time they add a coding preset.
    enum OpenCodeSyncOutcome {
        case synced(path: String)
        case noCodingProfiles
        case openCodeNotSetUp
        case failed(String)
    }

    @discardableResult
    func syncCodingProfilesToOpenCode() -> OpenCodeSyncOutcome {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: Self.openCodeConfigDirectory.path)
            || HomebrewRuntimeManager.isInstalled(.opencode, fileManager: fileManager) else { return .openCodeNotSetUp }
        let codingProfiles: [OpenCodeConfigSync.ProfileEntry] = profiles.compactMap { profile in
            guard ProfilePreset.all.contains(where: {
                $0.profile.runtime == profile.runtime && $0.profile.modelPath == profile.modelPath && $0.useCases.contains(.coding)
            }) else { return nil }
            return .init(alias: profile.alias, name: profile.name, contextSize: profile.contextSize, maximumOutputTokens: profile.effectiveMaximumOutputTokens)
        }
        guard !codingProfiles.isEmpty else { return .noCodingProfiles }
        var existing: [String: Any] = [:]
        if let data = try? Data(contentsOf: Self.openCodeConfigURL),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            existing = parsed
        }
        let apiKey = networkSettings.authenticationEnabled ? "{env:INFERENCE_API_KEY}" : "local"
        let baseURL = "\(networkSettings.baseURL(runtime: .llamaCPP)?.absoluteString ?? "http://127.0.0.1:\(networkSettings.port)")/v1"
        // Only honor defaultCodingProfileID if that profile is actually
        // one of the ones being synced (still exists, still coding-tagged)
        // -- otherwise fall through to clearing any stale "model" pointer
        // in mergedConfig rather than writing a default alias that no
        // longer corresponds to a real model in this same config.
        let defaultAlias = defaultCodingProfileID
            .flatMap { id in profiles.first(where: { $0.id == id }) }
            .flatMap { profile in codingProfiles.first(where: { $0.alias == profile.alias })?.alias }
        let merged = OpenCodeConfigSync.mergedConfig(existing: existing, baseURL: baseURL, apiKey: apiKey, profiles: codingProfiles, defaultModelAlias: defaultAlias)
        do {
            try fileManager.createDirectory(at: Self.openCodeConfigDirectory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: Self.openCodeConfigURL, options: .atomic)
            return .synced(path: Self.openCodeConfigURL.path)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // download()/downloadMLXModel() were built around a single in-flight
    // download at a time -- their progress (downloadProgress, downloadPhase,
    // downloadBytesPerSecond, downloadOwnerProfileID, ...) lives in shared
    // scalar properties, not per-job state, because until "Add all presets"
    // existed nothing ever started more than one download at once. Firing
    // several of these concurrently makes each one's progress callbacks
    // stomp on those shared properties, which is exactly what made the
    // per-profile progress bar jump around between different downloads'
    // numbers. Rather than rework that shared state to be per-job, this
    // queue keeps the existing single-flight assumption true by running
    // every preset download one at a time, in order, no matter how many
    // get queued at once.
    private var pendingPresetDownloads: [(preset: ProfilePreset, ownerProfileID: UUID)] = []
    private var isProcessingPresetDownloadQueue = false
    // Read by the menu-bar dropdown so "Add all presets" queuing several
    // downloads at once doesn't look like it silently dropped the rest --
    // see menuNeedsUpdate in InferenceBarApp.swift.
    var queuedPresetDownloadCount: Int { pendingPresetDownloads.count }

    private func enqueuePresetDownload(_ preset: ProfilePreset, ownerProfileID: UUID) {
        pendingPresetDownloads.append((preset, ownerProfileID))
        guard !isProcessingPresetDownloadQueue else { return }
        isProcessingPresetDownloadQueue = true
        Task { await self.processPresetDownloadQueue() }
    }

    private func processPresetDownloadQueue() async {
        while !pendingPresetDownloads.isEmpty {
            let next = pendingPresetDownloads.removeFirst()
            switch next.preset.profile.runtime {
            case .llamaCPP:
                guard let sourceModelID = next.preset.ggufSourceModelID else { continue }
                let placeholder = HFModel(id: sourceModelID, downloads: nil, likes: nil, lastModified: nil, pipeline_tag: nil, tags: nil, usedStorage: nil)
                if let filename = next.preset.expectedGGUFFilename, !next.preset.isAvailable(modelRoot: configuredModelRoot) {
                    await download(file: filename, from: placeholder, to: configuredModelRoot.path, ownerProfileID: next.ownerProfileID)
                }
                // The projector is a companion file living in the same repo,
                // not something a profile's modelPath ever points at, so it's
                // fetched with ownerProfileID: nil -- passing the real owner
                // here would reassign that profile's modelPath to the mmproj
                // file itself once this download completes (see
                // DownloadProfileOwnership.permitsAssignment).
                if let mmprojFilename = next.preset.mmprojFilename, !next.preset.hasProjectorAvailable(modelRoot: configuredModelRoot) {
                    await download(file: mmprojFilename, from: placeholder, to: configuredModelRoot.path, ownerProfileID: nil)
                }
            case .mlxLM, .vllmMLX:
                await downloadMLXModel(next.preset.profile.modelPath)
            }
        }
        isProcessingPresetDownloadQueue = false
    }

    func duplicateProfile() {
        guard var profile = selectedProfile else { return }
        profile.id = UUID(); profile.name += " copy"
        profiles.append(profile); selectedProfileID = profile.id
    }

    func deleteSelectedProfile() {
        guard let id = selectedProfileID, id != runningProfileID else { return }
        profiles.removeAll { $0.id == id }
        favoriteProfileIDs.remove(id)
        if defaultProfileID == id { defaultProfileID = nil }
        if defaultCodingProfileID == id { defaultCodingProfileID = nil }
        selectedProfileID = profiles.first?.id
    }

    /// Bulk delete for the Profiles window's multi-select mode. Silently
    /// skips the running profile if it's part of the selection -- same
    /// as deleteSelectedProfile() above never deleting it -- rather than
    /// refusing the whole batch, so selecting "everything" and hitting
    /// delete still removes every other profile.
    func deleteProfiles(_ ids: Set<UUID>) {
        let deletable = ids.filter { $0 != runningProfileID }
        guard !deletable.isEmpty else { return }
        profiles.removeAll { deletable.contains($0.id) }
        favoriteProfileIDs.subtract(deletable)
        if let defaultProfileID, deletable.contains(defaultProfileID) { self.defaultProfileID = nil }
        if let defaultCodingProfileID, deletable.contains(defaultCodingProfileID) { self.defaultCodingProfileID = nil }
        if let selectedProfileID, deletable.contains(selectedProfileID) { self.selectedProfileID = profiles.first?.id }
    }

    func search(category: ModelCategory? = nil) async {
        if let category { modelCategory = category }
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        isSearching = true; errorMessage = nil
        defer { isSearching = false }
        do {
            if !modelCategory.recommendedFamilies.isEmpty || !modelCategory.recommendedModelIDs.isEmpty {
                var curated: [String: HFModel] = [:]
                // A category with its own pipelineTag (e.g. "Chat with
                // Images" -> "image-text-to-text") narrows the family
                // search below to models Hugging Face itself tags as
                // capable of that -- but only for MLX. For GGUF, a
                // pipeline_tag server-side filter turns out to actively
                // hurt this: whoever requantizes a vision model to GGUF
                // very often doesn't bother recreating its pipeline_tag,
                // so a straight Qwen3-VL conversion frequently shows up
                // tagged just "text-generation" on Hugging Face (as a
                // user found when testing this) -- filtering on that tag
                // would silently drop good results rather than include
                // bad ones. GGUF results are instead post-filtered below
                // by whether the repo actually ships an mmproj file,
                // which is the same ground truth this app already uses
                // locally to decide whether a model can see images (see
                // MultimodalProjector), and can't be mistagged.
                if modelCatalogBackend == .mlxLM {
                    for family in modelCategory.recommendedFamilies {
                        var recommendedURL = URLComponents(string: "https://huggingface.co/api/models")!
                        var items = [URLQueryItem(name: "search", value: family), .init(name: "author", value: "mlx-community"), .init(name: "sort", value: "downloads"), .init(name: "direction", value: "-1"), .init(name: "limit", value: "8"), .init(name: "full", value: "true")]
                        if let pipelineTag = modelCategory.pipelineTag { items.append(.init(name: "pipeline_tag", value: pipelineTag)) }
                        recommendedURL.queryItems = items
                        guard let url = recommendedURL.url,
                              let (data, response) = try? await URLSession.shared.data(from: url),
                              let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode,
                              let models = try? JSONDecoder().decode([HFModel].self, from: data) else { continue }
                        for model in models { curated[model.id] = model }
                    }
                } else {
                    let families = modelCategory.recommendedFamilies
                    let requiresVisionProjector = modelCategory.pipelineTag == "image-text-to-text"
                    for family in families {
                        var recommendedURL = URLComponents(string: "https://huggingface.co/api/models")!
                        // full=true is needed here (harmlessly unused by
                        // every other GGUF category) so `siblings` is
                        // populated for the mmproj check below.
                        recommendedURL.queryItems = [.init(name: "search", value: family), .init(name: "filter", value: "gguf"), .init(name: "sort", value: "downloads"), .init(name: "direction", value: "-1"), .init(name: "limit", value: "8"), .init(name: "full", value: "true")]
                        let (familyData, familyResponse) = try await URLSession.shared.data(from: recommendedURL.url!)
                        try Self.validate(familyResponse)
                        for model in try JSONDecoder().decode([HFModel].self, from: familyData) {
                            if requiresVisionProjector {
                                let siblingNames = (model.siblings ?? []).map(\.rfilename)
                                guard MultimodalProjector.hasProjectorSibling(among: siblingNames) else { continue }
                            }
                            curated[model.id] = model
                        }
                    }
                }
                for modelID in modelCategory.recommendedModelIDs {
                    let encoded = modelID.split(separator: "/").map {
                        String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
                    }.joined(separator: "/")
                    guard let url = URL(string: "https://huggingface.co/api/models/\(encoded)"),
                          let (data, response) = try? await URLSession.shared.data(from: url),
                          let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode,
                          let model = try? JSONDecoder().decode(HFModel.self, from: data) else { continue }
                    let isMLX = model.id.hasPrefix("mlx-community/") || model.tags?.contains(where: { $0.caseInsensitiveCompare("mlx") == .orderedSame }) == true
                    if (modelCatalogBackend == .mlxLM) == isMLX { curated[model.id] = model }
                }
                let recommendations = curated.values.sorted { ($0.downloads ?? 0) > ($1.downloads ?? 0) }
                searchResults = q.isEmpty ? recommendations : recommendations.filter {
                    $0.id.localizedCaseInsensitiveContains(q) ||
                    ($0.tags?.contains { $0.localizedCaseInsensitiveContains(q) } ?? false)
                }
                return
            }
            var parts = URLComponents(string: "https://huggingface.co/api/models")!
            let runtimeFilter = modelCatalogBackend == .llamaCPP ? "gguf" : "mlx"
            var query: [URLQueryItem] = [.init(name: "filter", value: runtimeFilter), .init(name: "sort", value: modelCategory.sort), .init(name: "direction", value: "-1"), .init(name: "limit", value: "50"), .init(name: "full", value: "true")]
            if modelCatalogBackend == .mlxLM { query.append(.init(name: "author", value: "mlx-community")) }
            if let pipelineTag = modelCategory.pipelineTag { query.append(.init(name: "pipeline_tag", value: pipelineTag)) }
            if let tag = modelCategory.tag { query.append(.init(name: "filter", value: tag)) }
            if !q.isEmpty { query.insert(.init(name: "search", value: q), at: 0) }
            parts.queryItems = query
            let (data, response) = try await URLSession.shared.data(from: parts.url!)
            try Self.validate(response)
            let decoded = try JSONDecoder().decode([HFModel].self, from: data)
            searchResults = decoded.filter { model in
                let size = model.usedStorage ?? 0
                if let minimum = modelCategory.minimumSize, size > 0 && size < minimum { return false }
                if let maximum = modelCategory.maximumSize, size > 0 && size >= maximum { return false }
                return true
            }
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch { errorMessage = "Search failed: \(error.localizedDescription)" }
    }

    func loadFiles(for model: HFModel) async {
        selectedModel = model; isLoadingFiles = true; modelFiles = []; modelFileSizes = [:]; errorMessage = nil
        defer { isLoadingFiles = false }
        do {
            let encoded = model.id.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)! }.joined(separator: "/")
            guard let url = URL(string: "https://huggingface.co/api/models/\(encoded)?blobs=true") else { throw URLError(.badURL) }
            let (data, response) = try await URLSession.shared.data(from: url)
            try Self.validate(response)
            let detail = try JSONDecoder().decode(HFModelDetail.self, from: data)
            let entries = ModelVersionInventory.entries(modelID: model.id, backend: modelCatalogBackend, siblings: detail.siblings ?? [])
            modelFiles = entries.map(\.name)
            modelFileSizes = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0.size) })
            if modelCatalogBackend != .llamaCPP {
                return
            }
            let ggufFiles = (detail.siblings ?? []).filter { $0.rfilename.lowercased().hasSuffix(".gguf") }
            for file in ggufFiles {
                let filename = URL(fileURLWithPath: file.rfilename).lastPathComponent
                let localURL = configuredModelRoot.appendingPathComponent(filename)
                guard FileManager.default.fileExists(atPath: localURL.path) else { continue }
                let size = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber)?.int64Value ?? file.lfs?.size ?? file.size ?? 0
                recordModelMetadata(.init(sourceModelID: model.id, revision: model.sha, filename: filename, checksumSHA256: file.lfs?.sha256, checksumVerified: false, license: ModelProvenance.license(from: model.tags), quantization: ModelProvenance.quantization(from: filename), format: "GGUF", localPath: localURL.path, size: size, downloadedAt: Date()))
            }
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch { errorMessage = "Could not load files: \(error.localizedDescription)" }
    }

    func download(file: String, from model: HFModel, to directory: String, ownerProfileID: UUID? = nil) async {
        let jobID = "gguf:\(model.id):\(file)"
        guard downloadJobs[jobID] == nil else { return }
        downloadCancellationRequested = false
        errorMessage = nil
        downloadStatus = "Downloading \(file)…"
        downloadModelName = model.id
        downloadOwnerProfileID = ownerProfileID
        downloadBackend = .llamaCPP
        downloadPhase = "Downloading"
        downloadProgress = 0
        downloadedBytes = 0
        downloadTotalBytes = 0
        downloadBytesPerSecond = 0
        downloadCompletedFiles = 0
        downloadTotalFiles = 0
        isDownloading = true
        let root = URL(fileURLWithPath: NSString(string: directory).expandingTildeInPath, isDirectory: true)
        let destination = root.appendingPathComponent(URL(fileURLWithPath: file).lastPathComponent)
        downloadJobs[jobID] = DownloadJob(id: jobID, modelID: model.id, file: file, phase: "Downloading", backend: .llamaCPP, destination: destination.path, ownerProfileID: ownerProfileID)
        var keepInQueue = false
        defer {
            if !keepInQueue { downloadJobs.removeValue(forKey: jobID) }
            activeDownloaders.removeValue(forKey: jobID)
            isDownloading = !downloadJobs.isEmpty
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let path = "https://huggingface.co/\(model.id)/resolve/main/\(file)"
            guard let url = URL(string: path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path) else { throw URLError(.badURL) }
            let expectedChecksum = await repositorySHA256(modelID: model.id, file: file)
            defer { activeDownloader = nil; isDownloadPaused = false }
            var checksum: DownloadChecksumResult?
            for attempt in 1...2 {
                let startedAt = Date()
                downloadProgress = 0
                downloadedBytes = 0
                downloadTotalBytes = 0
                downloadBytesPerSecond = 0
                downloadPhase = attempt == 1 ? "Downloading" : "Retrying after checksum mismatch"
                downloadStatus = attempt == 1 ? "Downloading \(file)…" : "Checksum mismatch — downloading \(file) again…"

                let downloader = DownloadController()
                activeDownloader = downloader
                activeDownloaders[jobID] = downloader
                do {
                    checksum = try await downloader.download(from: url, to: destination, expectedSHA256: expectedChecksum, phase: { [weak self] phase in
                        self?.downloadPhase = phase
                        self?.downloadStatus = "\(phase): \(file)"
                        if var job = self?.downloadJobs[jobID] {
                            job.phase = phase
                            self?.downloadJobs[jobID] = job
                        }
                    }) { [weak self] received, total in
                        guard let self else { return }
                        downloadedBytes = received
                        downloadTotalBytes = total
                        downloadProgress = total > 0 ? min(Double(received) / Double(total), 1) : 0
                        let elapsed = max(Date().timeIntervalSince(startedAt), 0.001)
                        downloadBytesPerSecond = Double(received) / elapsed
                        if var job = downloadJobs[jobID] {
                            job.received = received
                            job.total = total
                            job.progress = total > 0 ? min(Double(received) / Double(total), 1) : 0
                            job.speed = Double(received) / elapsed
                            downloadJobs[jobID] = job
                        }
                    }
                    activeDownloader = nil
                    break
                } catch let error as NSError where error.domain == "InferenceBar.Checksum" && error.code == 2 && attempt == 1 {
                    if var job = downloadJobs[jobID] { job.phase = "Retrying after checksum mismatch"; downloadJobs[jobID] = job }
                    activeDownloader = nil
                    continue
                }
            }
            guard let checksum else { throw URLError(.cannotDecodeContentData) }
            downloadProgress = 1
            if var job = downloadJobs[jobID] { job.progress = 1; job.phase = "Completed"; downloadJobs[jobID] = job }
            downloadPhase = "Completed"
            let verification = checksum == .verified ? " · SHA-256 verified" : " · checksum not provided"
            let installedSize = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
            recordModelMetadata(.init(sourceModelID: model.id, revision: model.sha, filename: destination.lastPathComponent, checksumSHA256: expectedChecksum, checksumVerified: checksum == .verified, license: ModelProvenance.license(from: model.tags), quantization: ModelProvenance.quantization(from: destination.lastPathComponent), format: "GGUF", localPath: destination.path, size: installedSize, downloadedAt: Date()))
            if let index = profiles.firstIndex(where: {
                DownloadProfileOwnership.permitsAssignment(to: $0.id, ownerProfileID: ownerProfileID)
            }) {
                profiles[index].modelPath = destination.path
                downloadStatus = "Saved and assigned to \(profiles[index].name)\(verification)"
            } else {
                downloadStatus = "Saved to \(destination.path)\(verification)"
            }
        } catch is CancellationError {
            downloadStatus = "Download cancelled"
        } catch let error as URLError where error.code == .cancelled {
            downloadStatus = "Download cancelled"
        } catch let error as NSError where error.domain == "InferenceBar.Checksum" && error.code == 2 {
            keepInQueue = true
            if var job = downloadJobs[jobID] { job.phase = "Checksum failed — ready to retry"; job.isPaused = true; job.speed = 0; downloadJobs[jobID] = job }
            downloadStatus = "Integrity check failed"
            downloadPhase = "Checksum failed"
            errorMessage = "The download failed integrity verification twice and was not installed. Try again later; if it keeps failing, the file published by Hugging Face may have an incorrect checksum."
        } catch {
            keepInQueue = true
            if var job = downloadJobs[jobID] { job.phase = "Failed — ready to resume"; job.isPaused = true; job.speed = 0; downloadJobs[jobID] = job }
            downloadStatus = ""
            errorMessage = "Download failed: \(error.localizedDescription)"
        }
    }

    private func repositorySHA256(modelID: String, file: String) async -> String? {
        let encoded = modelID.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)! }.joined(separator: "/")
        guard let url = URL(string: "https://huggingface.co/api/models/\(encoded)?blobs=true"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode,
              let detail = try? JSONDecoder().decode(HFModelDetail.self, from: data) else { return nil }
        let wanted = URL(fileURLWithPath: file).lastPathComponent
        return detail.siblings?.first(where: {
            URL(fileURLWithPath: $0.rfilename).lastPathComponent.caseInsensitiveCompare(wanted) == .orderedSame
        })?.lfs?.sha256?.lowercased()
    }

    func downloadMLXModel(_ modelID: String) async {
        let jobID = "mlx:\(modelID)"
        guard downloadJobs[jobID] == nil else { return }
        cancelledDownloadJobs.remove(jobID)
        let hf: URL? = {
            if let server = resolveExecutable("mlx_lm.server") {
                let sibling = server.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("hf")
                if FileManager.default.isExecutableFile(atPath: sibling.path) { return sibling }
            }
            for path in ["/opt/homebrew/opt/mlx-lm/libexec/bin/hf", "/usr/local/opt/mlx-lm/libexec/bin/hf"] where FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
            return resolveExecutable("hf")
        }()
        guard let hf else {
            errorMessage = "The Hugging Face downloader was not found. Reinstall MLX support with: brew reinstall mlx-lm"
            return
        }
        isDownloading = true
        downloadJobs[jobID] = DownloadJob(id: jobID, modelID: modelID, file: "MLX repository", phase: "Downloading", backend: .mlxLM, destination: configuredModelRoot.path)
        downloadProgress = 0
        downloadedBytes = 0
        downloadTotalBytes = 0
        downloadBytesPerSecond = 0
        downloadCompletedFiles = 0
        downloadTotalFiles = 0
        downloadStatus = "Downloading \(modelID)…"
        downloadModelName = modelID
        downloadOwnerProfileID = nil
        downloadBackend = .mlxLM
        downloadPhase = "Downloading"
        errorMessage = nil
        var keepInQueue = false
        defer {
            if !keepInQueue { downloadJobs.removeValue(forKey: jobID) }
            mlxDownloadProcesses.removeValue(forKey: jobID)
            cancelledDownloadJobs.remove(jobID)
            completedDownloadJobs.remove(jobID)
            isDownloading = !downloadJobs.isEmpty
        }

        let repositoryTotal = await mlxRepositorySize(modelID)
        downloadTotalBytes = repositoryTotal
        if var job = downloadJobs[jobID] { job.total = repositoryTotal; downloadJobs[jobID] = job }
        let cacheRoot = mlxCacheRoot(modelID)
        let initialBytes = Self.directoryByteCount(cacheRoot)
        downloadedBytes = min(initialBytes, downloadTotalBytes > 0 ? downloadTotalBytes : initialBytes)

        let task = Process()
        mlxDownloadProcess = task
        mlxDownloadProcesses[jobID] = task
        defer { mlxDownloadProcess = nil }
        let pipe = Pipe()
        task.executableURL = hf
        task.arguments = ["download", modelID, "--cache-dir", configuredModelRoot.path]
        var environment = ProcessInfo.processInfo.environment
        environment["HF_HUB_CACHE"] = configuredModelRoot.path
        task.environment = environment
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
            let monitor = Task { [weak self] in
                var previousBytes = initialBytes
                var previousDate = Date()
                var stableCompleteChecks = 0
                while !Task.isCancelled && task.isRunning {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard let self else { return }
                    let currentBytes = Self.directoryByteCount(cacheRoot)
                    let now = Date()
                    let elapsed = max(now.timeIntervalSince(previousDate), 0.001)
                    downloadedBytes = currentBytes
                    let delta = currentBytes - previousBytes
                    if delta > 0 { downloadBytesPerSecond = Double(delta) / elapsed }
                    if repositoryTotal > 0 { downloadProgress = min(Double(currentBytes) / Double(repositoryTotal), 1) }
                    if repositoryTotal > 0 && currentBytes >= repositoryTotal { stableCompleteChecks += 1 }
                    else { stableCompleteChecks = 0 }
                    if var job = downloadJobs[jobID] {
                        job.received = currentBytes
                        job.total = repositoryTotal
                        if repositoryTotal > 0 { job.progress = min(Double(currentBytes) / Double(repositoryTotal), 1) }
                        if delta > 0 { job.speed = Double(delta) / elapsed }
                        downloadJobs[jobID] = job
                    }
                    let snapshotComplete = resolvedMLXSnapshot(for: modelID) != nil
                    let hasIncompleteFiles = Self.directoryContainsIncompleteFile(cacheRoot)
                    if DownloadCompletionReconciler.shouldFinalize(progress: downloadProgress, snapshotComplete: snapshotComplete, hasIncompleteFiles: hasIncompleteFiles, stableChecks: stableCompleteChecks) {
                        completedDownloadJobs.insert(jobID)
                        if var job = downloadJobs[jobID] { job.phase = "Finalizing"; job.speed = 0; downloadJobs[jobID] = job }
                        task.terminate()
                        return
                    }
                    previousBytes = currentBytes
                    previousDate = now
                }
            }
            let reader = Task { [weak self] in
                var progressLine = ""
                do {
                    for try await byte in pipe.fileHandleForReading.bytes {
                        let scalar = UnicodeScalar(byte)
                        self?.logs.unicodeScalars.append(scalar)
                        if byte == 10 || byte == 13 {
                            self?.updateMLXProgress(from: progressLine)
                            progressLine = ""
                        } else {
                            progressLine.unicodeScalars.append(scalar)
                            if progressLine.count > 1_024 { progressLine.removeFirst(progressLine.count - 1_024) }
                        }
                    }
                    self?.updateMLXProgress(from: progressLine)
                } catch { }
            }
            let status: Int32 = await withCheckedContinuation { continuation in
                task.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            }
            try? pipe.fileHandleForWriting.close()
            await reader.value
            monitor.cancel()
            if cancelledDownloadJobs.contains(jobID) {
                downloadStatus = "Download cancelled"
            } else if status == 0 || completedDownloadJobs.contains(jobID) {
                downloadProgress = 1
                downloadBytesPerSecond = 0
                downloadPhase = "Verifying checksums"
                downloadStatus = "Verifying Hugging Face checksums…"
                if var job = downloadJobs[jobID] { job.phase = "Verifying checksums"; job.progress = 1; job.speed = 0; downloadJobs[jobID] = job }
                let verificationRoot = configuredModelRoot
                let result = try await Task.detached(priority: .utility) { try ChecksumVerifier.verifyCachedModel(modelID, cacheRoot: verificationRoot) }.value
                if let snapshot = resolvedMLXSnapshot(for: modelID) {
                    recordModelMetadata(.init(sourceModelID: modelID, revision: snapshot.lastPathComponent, filename: snapshot.lastPathComponent, checksumSHA256: nil, format: "MLX", localPath: snapshot.path, size: Self.directoryByteCount(snapshot), downloadedAt: Date()))
                }
                downloadPhase = "Completed"
                downloadStatus = result > 0 ? "Downloaded \(modelID) · verified \(result) SHA-256 object(s)" : "Downloaded \(modelID) · checksum metadata unavailable"
            } else {
                keepInQueue = true
                if var job = downloadJobs[jobID] { job.phase = "Failed — ready to resume"; job.isPaused = true; job.speed = 0; downloadJobs[jobID] = job }
                downloadStatus = ""
                errorMessage = "The MLX model download failed with exit status \(status). Check Logs for details."
            }
        } catch {
            keepInQueue = true
            if var job = downloadJobs[jobID] { job.phase = "Failed — ready to resume"; job.isPaused = true; job.speed = 0; downloadJobs[jobID] = job }
            downloadStatus = ""
            errorMessage = "Could not start the MLX model download: \(error.localizedDescription)"
        }
    }

    private func mlxRepositorySize(_ modelID: String) async -> Int64 {
        let encoded = modelID.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)! }.joined(separator: "/")
        guard let url = URL(string: "https://huggingface.co/api/models/\(encoded)?blobs=true"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode,
              let detail = try? JSONDecoder().decode(HFModelDetail.self, from: data) else { return 0 }
        return detail.siblings?.reduce(Int64(0)) { $0 + ($1.lfs?.size ?? $1.size ?? 0) } ?? 0
    }

    private func mlxCacheRoot(_ modelID: String) -> URL {
        let repo = "models--" + modelID.replacingOccurrences(of: "/", with: "--")
        return configuredModelRoot.appendingPathComponent("\(repo)/blobs")
    }

    nonisolated private static func directoryByteCount(_ root: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    nonisolated private static func directoryContainsIncompleteFile(_ root: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { return false }
        for case let path as String in enumerator where path.hasSuffix(".incomplete") { return true }
        return false
    }

    private func updateMLXProgress(from output: String) {
        let clean = output.replacingOccurrences(of: "\u{001B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        var didUpdate = false
        if let expression = try? NSRegularExpression(pattern: #"(\d{1,3})%"#),
           let match = expression.matches(in: clean, range: NSRange(clean.startIndex..., in: clean)).last,
           let range = Range(match.range(at: 1), in: clean),
           let percent = Double(clean[range]) {
            if downloadTotalBytes == 0 { downloadProgress = min(max(percent / 100, 0), 1) }
            didUpdate = true
        }
        if let expression = try? NSRegularExpression(pattern: #"(\d+)\s*/\s*(\d+)"#),
           let match = expression.matches(in: clean, range: NSRange(clean.startIndex..., in: clean)).last,
           let completedRange = Range(match.range(at: 1), in: clean),
           let totalRange = Range(match.range(at: 2), in: clean),
           let completed = Int(clean[completedRange]),
           let total = Int(clean[totalRange]), total > 0 {
            downloadCompletedFiles = completed
            downloadTotalFiles = total
            if downloadProgress == 0 { downloadProgress = min(Double(completed) / Double(total), 1) }
            didUpdate = true
        }
        if didUpdate { downloadStatus = "Downloading model files…" }
    }

    func toggleDownloadPause() {
        isDownloadPaused.toggle()
        if let activeDownloader {
            isDownloadPaused ? activeDownloader.pause() : activeDownloader.resume()
        } else if let mlxDownloadProcess, mlxDownloadProcess.isRunning {
            kill(mlxDownloadProcess.processIdentifier, isDownloadPaused ? SIGSTOP : SIGCONT)
        } else {
            isDownloadPaused = false
            return
        }
        if isDownloadPaused { downloadBytesPerSecond = 0 }
        downloadStatus = isDownloadPaused ? "Download paused" : "Downloading…"
        downloadPhase = isDownloadPaused ? "Paused" : "Downloading"
    }

    func cancelDownload() {
        downloadCancellationRequested = true
        activeDownloader?.cancel()
        if let mlxDownloadProcess, mlxDownloadProcess.isRunning {
            if isDownloadPaused { kill(mlxDownloadProcess.processIdentifier, SIGCONT) }
            mlxDownloadProcess.terminate()
        }
        isResolvingDownload = false
        isDownloadPaused = false
        downloadStatus = "Download cancelled"
        downloadPhase = "Cancelled"
    }

    func downloadMissingModel(for profileID: UUID) async {
        guard let profile = profiles.first(where: { $0.id == profileID }) else { return }
        let expanded = NSString(string: profile.modelPath).expandingTildeInPath
        let destination = URL(fileURLWithPath: expanded)
        let expectedFile = destination.lastPathComponent
        guard !expectedFile.isEmpty, expectedFile.lowercased().hasSuffix(".gguf") else {
            errorMessage = "Set an expected .gguf model filename before downloading."
            return
        }
        isResolvingDownload = true
        downloadOwnerProfileID = profileID
        downloadCancellationRequested = false
        defer { isResolvingDownload = false }
        downloadStatus = "Finding \(expectedFile) on Hugging Face…"
        errorMessage = nil
        do {
            var parts = URLComponents(string: "https://huggingface.co/api/models")!
            let stem = String(expectedFile.dropLast(5))
            let familyQuery = Self.ggufFamilyQuery(from: stem)
            parts.queryItems = [.init(name: "search", value: familyQuery), .init(name: "filter", value: "gguf"), .init(name: "sort", value: "downloads"), .init(name: "direction", value: "-1"), .init(name: "limit", value: "30")]
            let (data, response) = try await URLSession.shared.data(from: parts.url!)
            guard !downloadCancellationRequested else { throw CancellationError() }
            try Self.validate(response)
            let candidates = try JSONDecoder().decode([HFModel].self, from: data)
            var fallback: (model: HFModel, file: String, score: Int)?
            for model in candidates {
                guard !downloadCancellationRequested else { throw CancellationError() }
                let encoded = model.id.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)! }.joined(separator: "/")
                guard let detailURL = URL(string: "https://huggingface.co/api/models/\(encoded)") else { continue }
                let (detailData, detailResponse) = try await URLSession.shared.data(from: detailURL)
                guard !downloadCancellationRequested else { throw CancellationError() }
                try Self.validate(detailResponse)
                let detail = try JSONDecoder().decode(HFModelDetail.self, from: detailData)
                if let file = detail.siblings?.map(\.rfilename).first(where: { URL(fileURLWithPath: $0).lastPathComponent.caseInsensitiveCompare(expectedFile) == .orderedSame }) {
                    selectedProfileID = profileID
                    await download(file: file, from: model, to: destination.deletingLastPathComponent().path, ownerProfileID: profileID)
                    return
                }
                for file in detail.siblings?.map(\.rfilename).filter({ $0.lowercased().hasSuffix(".gguf") }) ?? [] {
                    let score = Self.ggufCompatibilityScore(file: file, expected: expectedFile, family: familyQuery, repository: model.id)
                    if fallback == nil || score > fallback!.score { fallback = (model, file, score) }
                }
            }
            if let fallback, fallback.score > 0 {
                let resolvedName = URL(fileURLWithPath: fallback.file).lastPathComponent
                if let index = profiles.firstIndex(where: { $0.id == profileID }) {
                    profiles[index].modelPath = destination.deletingLastPathComponent().appendingPathComponent(resolvedName).path
                }
                selectedProfileID = profileID
                downloadStatus = "Using compatible file \(resolvedName)…"
                await download(file: fallback.file, from: fallback.model, to: destination.deletingLastPathComponent().path, ownerProfileID: profileID)
                return
            }
            errorMessage = "Could not find a compatible GGUF file for “\(familyQuery)” on Hugging Face. Open Manage models to choose a model manually."
            downloadStatus = ""
        } catch is CancellationError {
            downloadStatus = ""
            return
        } catch let error as URLError where error.code == .cancelled {
            downloadStatus = ""
            return
        } catch {
            errorMessage = "Could not locate the model: \(error.localizedDescription)"
            downloadStatus = ""
        }
    }

    private static func ggufFamilyQuery(from filenameStem: String) -> String {
        var query = filenameStem.replacingOccurrences(of: "_", with: "-")
        query = query.replacingOccurrences(of: #"-(?:Q\d+(?:-[A-Z0-9]+)*|IQ\d+(?:-[A-Z0-9]+)*|F16|F32)$"#, with: "", options: [.regularExpression, .caseInsensitive])
        query = query.replacingOccurrences(of: #"^(Qwen|Meta|Google)-\1-"#, with: "$1-", options: [.regularExpression, .caseInsensitive])
        return query
    }

    private static func ggufCompatibilityScore(file: String, expected: String, family: String, repository: String) -> Int {
        let candidate = URL(fileURLWithPath: file).lastPathComponent.lowercased()
        guard !candidate.contains("mmproj") else { return -1_000 }
        let familyTokens = family.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).filter { $0.count > 1 }
        var score = familyTokens.reduce(0) { $0 + (candidate.contains($1) ? 12 : -8) }
        score += repository.lowercased().contains(family.lowercased()) ? 50 : 0
        if let quant = expected.range(of: #"(?:Q\d+(?:_[A-Z0-9]+)*|IQ\d+(?:_[A-Z0-9]+)*)\.gguf$"#, options: [.regularExpression, .caseInsensitive]) {
            let preferred = expected[quant].dropLast(5).lowercased()
            if candidate.contains(preferred) { score += 100 }
        }
        if candidate.contains("q5_k_m") { score += 18 }
        else if candidate.contains("q5_k") { score += 14 }
        else if candidate.contains("q4_k_m") { score += 10 }
        return score
    }

    func start() {
        guard canStartProfile, let selectedProfileID,
              let selectedIndex = profiles.firstIndex(where: { $0.id == selectedProfileID }) else { return }
        if !profiles[selectedIndex].runtime.usesGGUF,
           let snapshot = resolvedMLXSnapshot(for: profiles[selectedIndex].modelPath) {
            profiles[selectedIndex].modelPath = snapshot.path
        }
        guard let profile = selectedProfile else { return }
        guard !profile.modelPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "No model is selected for “\(profile.name)”. Download a GGUF model or choose an existing file in the profile."
            return
        }
        if profile.runtime.usesGGUF {
            let expandedModelPath = NSString(string: profile.modelPath).expandingTildeInPath
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: expandedModelPath, isDirectory: &isDirectory), !isDirectory.boolValue else {
                errorMessage = "The model for “\(profile.name)” has not been downloaded at:\n\n\(expandedModelPath)\n\nDownload it from Models or choose an existing GGUF file in the profile."
                logs += "Model validation failed: file not found at \(expandedModelPath)\n"
                return
            }
            guard expandedModelPath.lowercased().hasSuffix(".gguf") else {
                errorMessage = "The selected model must be a .gguf file for llama-server."
                return
            }
        } else {
            let expandedModelPath = NSString(string: profile.modelPath).expandingTildeInPath
            if expandedModelPath.lowercased().hasSuffix(".gguf") {
                errorMessage = "MLX cannot load GGUF files. Choose an MLX Hugging Face model ID, such as:\n\nmlx-community/Qwen3.6-35B-A3B-4bit\n\nor select a local MLX model directory containing config.json."
                logs += "Model validation failed: \(profile.runtime.title) cannot load GGUF file \(expandedModelPath)\n"
                return
            }
            var isDirectory: ObjCBool = false
            if profile.modelPath.contains("/") && FileManager.default.fileExists(atPath: expandedModelPath, isDirectory: &isDirectory) {
                guard isDirectory.boolValue,
                      FileManager.default.fileExists(atPath: (expandedModelPath as NSString).appendingPathComponent("config.json")) else {
                    errorMessage = "The selected local MLX model must be a directory containing config.json and MLX weights."
                    return
                }
            }
        }
        guard !networkSettings.authenticationEnabled || !networkSettings.apiKey.isEmpty else {
            errorMessage = "API-key authentication is enabled, but no API key has been configured in Server Settings."
            return
        }
        guard let executableURL = resolveExecutable(profile.executable) else {
            let expected = profile.executable.contains("/") ? NSString(string: profile.executable).expandingTildeInPath : "/opt/homebrew/bin/\(profile.executable)"
            serverLifecycle = .failed("\(profile.runtime.defaultExecutable) executable not found")
            failedProfileID = profile.id
            let installHint: String
            switch profile.runtime {
            case .llamaCPP: installHint = "Install llama.cpp with Homebrew or select the llama-server executable."
            case .mlxLM: installHint = "Install with: brew install mlx-lm"
            case .vllmMLX: installHint = "Install with: uv tool install vllm-mlx"
            }
            errorMessage = "Could not find \(profile.runtime.defaultExecutable). It was expected at:\n\n\(expected)\n\n\(installHint)"
            logs = "Start failed: executable not found for \(profile.executable)\n"
            return
        }
        var preflight: ModelPreflightReport
        let localModel = URL(fileURLWithPath: NSString(string: profile.modelPath).expandingTildeInPath)
        if profile.runtime.usesGGUF {
            preflight = ModelCompatibilityValidator.inspectGGUF(
                at: localModel,
                contextSize: profile.contextSize,
                hardware: .current(modelDirectory: configuredModelRoot.path)
            )
        } else if FileManager.default.fileExists(atPath: localModel.appendingPathComponent("config.json").path) {
            preflight = ModelCompatibilityValidator.inspectMLX(at: localModel)
        } else {
            preflight = ModelPreflightReport(warnings: ["Remote MLX metadata will be validated after the model is downloaded."])
        }
        let version = Self.runtimeVersion(executableURL)
        if version == nil { preflight.warnings.append("Runtime version could not be reported; compatibility will be confirmed by the readiness probe.") }
        else { preflight.warnings.append("Runtime: \(version!)") }
        compatibilityReport = preflight
        if !preflight.isCompatible {
            let details = preflight.errors.map { "• \($0)" }.joined(separator: "\n")
            logs += "Compatibility preflight failed:\n\(details)\n"
            errorMessage = "Model compatibility check failed:\n\n\(details)"
            return
        }
        stopRequested = false
        stopForceKillTask?.cancel(); stopForceKillTask = nil
        failedProfileID = nil
        serverLifecycle = profile.runtime == .mlxLM && !isMLXModelCached(profile.modelPath) ? .downloading : .starting
        logs = "Starting \(profile.name)…\n"
        let task = Process()
        let pipe = Pipe()
        task.standardOutput = pipe; task.standardError = pipe
        task.executableURL = executableURL
        task.arguments = profile.arguments(network: networkSettings)
        if !profile.runtime.usesGGUF {
            var environment = ProcessInfo.processInfo.environment
            environment["HF_HUB_CACHE"] = configuredModelRoot.path
            task.environment = environment
        }
        task.terminationHandler = { [weak self] ended in
            Task { @MainActor in
                guard let self else { return }
                self.readinessTask?.cancel()
                self.healthTask?.cancel()
                if self.stopRequested { self.serverLifecycle = .stopping }
                await self.outputTask?.value
                self.appendLogEntry("Process exited with status \(ended.terminationStatus).")
                if self.stopRequested {
                    self.serverLifecycle = .stopped
                    self.failedProfileID = nil
                } else {
                    let reason = ended.terminationStatus == 127 ? "executable not found" : "exit status \(ended.terminationStatus)"
                    self.serverLifecycle = .failed(reason)
                    self.failedProfileID = profile.id
                    self.errorMessage = "“\(profile.name)” failed to start (\(reason)). Check Logs for details. If the log says it could not bind, port \(self.networkSettings.port) is already in use."
                    self.scheduleAutoRestart(for: profile.id)
                }
                self.stopForceKillTask?.cancel(); self.stopForceKillTask = nil
                self.process = nil; self.runningProfileID = nil; self.outputTask = nil
                self.runtimeMemoryBytes = 0; self.runtimeStartedAt = nil; self.lastObservedActiveRequests = 0
            }
        }
        do {
            try task.run(); process = task; runningProfileID = profile.id; runtimeStartedAt = Date()
            healthTask?.cancel()
            healthTask = Task { [weak self, weak task] in
                while !Task.isCancelled, task?.isRunning == true {
                    guard let pid = task?.processIdentifier else { break }
                    self?.runtimeMemoryBytes = await Self.residentMemoryBytes(pid: pid)
                    // Piggybacks on this existing 1-second poll instead of
                    // adding a second timer: any client hitting the running
                    // server (InferenceBar's own chat, the CLI tool,
                    // opencode, anything else on the OpenAI-compatible API)
                    // shows up in the server's own log output, which
                    // runtimeHealth already parses regardless of who sent
                    // the request. Only posts when the count actually
                    // changes, so an idle server generates no extra
                    // notifications or icon redraws.
                    if let self {
                        let activeRequests = self.runtimeHealth.activeRequests
                        if activeRequests != self.lastObservedActiveRequests {
                            self.lastObservedActiveRequests = activeRequests
                            NotificationCenter.default.post(name: .inferenceServerLifecycleChanged, object: nil)
                        }
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            readinessTask = Task { [weak self, weak task] in await self?.waitForServerReadiness(process: task, profileID: profile.id) }
            outputTask = Task { [weak self] in
                var lineBuffer = ProcessLogLineBuffer()
                do {
                    for try await byte in pipe.fileHandleForReading.bytes {
                        guard !Task.isCancelled else { break }
                        if let line = lineBuffer.append(byte) { self?.logs += line }
                    }
                    if let remainder = lineBuffer.flush() { self?.logs += remainder }
                } catch {
                    if let remainder = lineBuffer.flush() { self?.logs += remainder }
                    self?.appendLogEntry("Log stream ended: \(error.localizedDescription)")
                }
            }
        } catch {
            logs += "Failed to start: \(error.localizedDescription)\n"
            serverLifecycle = .failed(error.localizedDescription); failedProfileID = profile.id
            errorMessage = "Could not start \(profile.runtime.title): \(error.localizedDescription)"
        }
    }

    func stop() {
        crashRestartTask?.cancel(); crashRestartTask = nil; crashRestartAttempts = 0
        guard let process, process.isRunning else { return }
        stopRequested = true
        serverLifecycle = .stopping
        appendLogEntry("Stopping…"); process.terminate()
        // SIGTERM alone can leave a wedged process (stuck in a syscall, a
        // bad state, whatever) sitting on "Stopping…" forever, with no way
        // back short of quitting InferenceBar entirely — which already has
        // this same fallback (shutdownServerForAppTermination). That one
        // can block synchronously since the app is already exiting; this
        // one can't block the UI, so it's a timer instead.
        let pid = process.processIdentifier
        stopForceKillTask?.cancel()
        stopForceKillTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            guard self.stopRequested, self.process?.processIdentifier == pid, self.process?.isRunning == true else { return }
            self.appendLogEntry("Stop timed out after 5s; forcing quit (SIGKILL).")
            Darwin.kill(pid, SIGKILL)
        }
    }

    // Only called from the termination handler's genuine-crash branch
    // (task exited without stop() having been requested) — not from the
    // preflight/validation failures that also set serverLifecycle to
    // .failed, since retrying those (a missing executable, a compatibility
    // check that will fail identically every time) would just loop without
    // ever succeeding until the user fixes something by hand.
    private func scheduleAutoRestart(for profileID: UUID) {
        guard autoRestartOnCrash, selectedProfileID == profileID else { return }
        guard crashRestartAttempts < Self.maxCrashRestartAttempts else {
            appendLogEntry("Auto-restart: giving up after \(Self.maxCrashRestartAttempts) attempts.")
            return
        }
        crashRestartAttempts += 1
        let delay = min(pow(2.0, Double(crashRestartAttempts)), 60)
        let attempt = crashRestartAttempts
        appendLogEntry("Auto-restart: retrying in \(Int(delay))s (attempt \(attempt)/\(Self.maxCrashRestartAttempts)).")
        crashRestartTask?.cancel()
        crashRestartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            guard self.selectedProfileID == profileID else { return }
            guard case .failed = self.serverLifecycle else { return }
            self.start()
        }
    }

    private func appendLogEntry(_ entry: String) {
        if !logs.isEmpty && !logs.hasSuffix("\n") { logs += "\n" }
        logs += entry
        if !logs.hasSuffix("\n") { logs += "\n" }
    }

    // Called from `logs`'s didSet for every assignment, including the many
    // call sites that mutate it directly with `+=` rather than going
    // through appendLogEntry above — so this is the one place that has to
    // reliably tell "more output for the current session" apart from "a
    // new session just started" (a plain reassignment like `logs =
    // "Starting …"`), since only the former should be appended to the
    // existing file.
    private func persistLogChange(from oldValue: String, to newValue: String) {
        guard !newValue.isEmpty else { return } // "Clear" in the Logs window — the on-disk record is untouched.
        if !oldValue.isEmpty, newValue.hasPrefix(oldValue) {
            appendToLogFile(String(newValue.dropFirst(oldValue.count)))
        } else {
            // A new session started (or the very first one). Keep the
            // previous session's file instead of overwriting it, so a
            // server that crashed mid-session is still readable afterward
            // even if nobody had the Logs window open at the time.
            rotateLogFile()
            appendToLogFile(newValue)
        }
    }

    private func capLogsInMemoryIfNeeded() {
        guard logs.count > Self.maxInMemoryLogCharacters else { return }
        isApplyingLogCap = true
        defer { isApplyingLogCap = false }
        logs = "[Earlier output trimmed from view to limit memory use — the full session log is on disk; see logFileURL.]\n" + String(logs.suffix(Self.maxInMemoryLogCharacters))
    }

    private func rotateLogFile() {
        logFileHandle?.closeFile(); logFileHandle = nil
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: logFileURL.path) else { return }
        try? fileManager.removeItem(at: previousLogFileURL)
        try? fileManager.moveItem(at: logFileURL, to: previousLogFileURL)
    }

    private func appendToLogFile(_ text: String) {
        guard !text.isEmpty, let data = text.data(using: .utf8) else { return }
        if logFileHandle == nil {
            if !FileManager.default.fileExists(atPath: logFileURL.path) {
                FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
            }
            logFileHandle = try? FileHandle(forWritingTo: logFileURL)
            logFileHandle?.seekToEndOfFile()
        }
        logFileHandle?.write(data)
    }

    func closeLogFile() {
        logFileHandle?.closeFile()
        logFileHandle = nil
    }

    nonisolated private static func residentMemoryBytes(pid: Int32) async -> Int64 {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-o", "rss=", "-p", String(pid)]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run(); task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return (Int64(value) ?? 0) * 1_024
        } catch { return 0 }
    }

    nonisolated private static func runtimeVersion(_ executable: URL) -> String? {
        let task = Process(); let pipe = Pipe()
        let finished = DispatchSemaphore(value: 0)
        task.executableURL = executable; task.arguments = ["--version"]
        task.standardOutput = pipe; task.standardError = pipe
        task.terminationHandler = { _ in finished.signal() }
        do {
            try task.run()
            guard finished.wait(timeout: .now() + 2) == .success else {
                task.terminate()
                return nil
            }
            let value = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return task.terminationStatus == 0 && !value.isEmpty ? String(value.prefix(240)) : nil
        } catch { return nil }
    }

    func shutdownServerForAppTermination() {
        guard let process, process.isRunning else { return }
        stopRequested = true
        readinessTask?.cancel()
        logs += "\nInferenceBar is quitting; stopping llama-server…\n"
        let pid = process.processIdentifier
        process.terminate()
        let deadline = Date().addingTimeInterval(4)
        while process.isRunning && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if process.isRunning {
            Darwin.kill(pid, SIGKILL)
            process.waitUntilExit()
        }
        self.process = nil
        runningProfileID = nil
        serverLifecycle = .stopped
    }

    func beginSendingPrompt() {
        guard chatGenerationTask == nil, !isSending else { return }
        chatGenerationTask = Task { [weak self] in await self?.sendPrompt() }
    }

    func cancelPrompt() { chatGenerationTask?.cancel() }

    /// Redoes the last answer: drops it (and any tool-call notes that
    /// went with it) and resends the same history — everything up to and
    /// including the last user message — for a fresh response, without
    /// adding a new user turn or requiring anything be retyped.
    func regenerateLastResponse() {
        // Checked here, before removeTrailingAssistantTurn() destructively
        // drops the previous answer, so a regenerate that can't actually
        // run (server not started) never loses that answer for nothing.
        guard chatGenerationTask == nil, !isSending, isRunning, serverLifecycle == .running,
              removeTrailingAssistantTurn() else { return }
        chatGenerationTask = Task { [weak self] in await self?.sendPrompt(appendingUserPrompt: false) }
    }

    /// Edits an earlier user message and continues the conversation from
    /// there: everything from that message onward (that answer, and
    /// anything after it) is discarded, the edited text takes its place
    /// as a new user turn, and a response is generated for it — the same
    /// outcome as retyping the conversation up to that point and sending
    /// the corrected message, minus the retyping.
    func editAndResend(messageID: UUID, newText: String) {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard chatGenerationTask == nil, !isSending, !trimmed.isEmpty,
              let index = ChatRegenerationPolicy.editTruncationIndex(for: messageID, in: messages) else { return }
        messages.removeSubrange(index...)
        prompt = trimmed
        beginSendingPrompt()
    }

    /// Removes every message after the most recent user message (the
    /// previous answer, plus any transient tool-call notes alongside
    /// it), leaving that user message as the new end of the
    /// conversation. Returns false — and leaves `messages` untouched —
    /// when there's nothing there to regenerate: no user message yet, or
    /// the user message is already the last thing in the transcript.
    private func removeTrailingAssistantTurn() -> Bool {
        guard let range = ChatRegenerationPolicy.trailingAssistantTurnRange(in: messages) else { return false }
        messages.removeSubrange(range)
        return true
    }

    // A tool call streams in as fragments — the id/name usually arrive
    // once, on the first fragment for a given index, while `arguments`
    // (a JSON string) is appended to piece by piece across many deltas —
    // so these are accumulated per index until the stream ends.
    private struct PendingToolCall {
        var id = ""
        var name = ""
        var arguments = ""
    }

    // A safety valve, not a normal outcome: stops a model that keeps
    // calling tools instead of ever answering from looping forever.
    private static let maximumToolRounds = 4
    // Prefix of the note shown in the transcript while a search runs.
    // Purely local UI, like the error prefixes alongside it below — never
    // actually said by either side of the conversation, so it's filtered
    // back out before the history is resent to the model.
    private static let webSearchNotePrefix = "🔎 Searched the web for "
    private static let fetchURLNotePrefix = "🌐 Fetched "

    // `appendingUserPrompt: false` is regenerateLastResponse()'s entry
    // point: the trailing assistant turn has already been stripped by
    // the time this runs, so this just resends the history exactly as
    // it stands (up to and including the last user message) rather than
    // pulling a new message from `prompt`/pendingChatAttachments.
    private func sendPrompt(appendingUserPrompt: Bool = true) async {
        // Registered before the early-return guard below on purpose: that
        // guard can bail out before ever reaching the isSending-scoped
        // defer further down, which would otherwise leave
        // chatGenerationTask stuck non-nil forever -- every future send
        // silently no-ops on beginSendingPrompt()'s own `chatGenerationTask
        // == nil` guard, with no error shown and the Send button still
        // looking enabled, since it only checks isRunning.
        defer { chatGenerationTask = nil }
        guard isRunning, serverLifecycle == .running,
              let profile = profiles.first(where: { $0.id == runningProfileID }),
              let base = networkSettings.baseURL(runtime: profile.runtime),
              !appendingUserPrompt || !prompt.isEmpty || !pendingChatAttachments.isEmpty || !pendingChatImageAttachments.isEmpty else {
            if appendingUserPrompt, !prompt.isEmpty || !pendingChatAttachments.isEmpty || !pendingChatImageAttachments.isEmpty {
                messages.append(.init(role: "assistant", content: "No local model is running. Start a profile before sending a message."))
            }
            return
        }
        let generationChatID = activeChatID
        // Needed below by looksLikeUnexpectedHTML — kept in scope for the
        // rest of the function (rather than declared only inside the
        // block below) since a regenerate (appendingUserPrompt == false)
        // never recomputes it: the request being responded to there is
        // whatever the last user message already in history says.
        let userText: String
        if appendingUserPrompt {
            let attachments = pendingChatAttachments
            let rendered = ChatAttachmentPayload.render(prompt: prompt, attachments: attachments)
            let images = persistPendingImages(pendingChatImageAttachments)
            prompt = ""; pendingChatAttachments = []; pendingChatImageAttachments = []
            messages.append(.init(role: "user", content: rendered, imageAttachments: images))
            userText = rendered
        } else {
            userText = messages.last(where: { $0.role == "user" })?.content ?? ""
        }
        isSending = true
        let reasoningMode = profile.reasoning.lowercased()
        engineActivity = reasoningMode == "auto" ? .thinking : (!reasoningMode.isEmpty && reasoningMode != "none" && reasoningMode != "off" ? .reasoning : .generating)
        defer { engineActivity = .idle; isSending = false }
        do {
            // llama-server assigns requests to reusable KV slots. Other clients
            // (notably OpenCode) may have populated those slots on the same
            // endpoint, so by default erase them before evaluating our
            // complete history. If the profile is marked exclusive to
            // InferenceBar (no other client ever talks to this server),
            // skip this — the whole point of a working prompt cache is
            // that InferenceBar's own turns get to reuse it too.
            let sharedServer = profile.exclusiveToInferenceBar != true
            if profile.runtime == .llamaCPP && sharedServer { await eraseAllServerSlots() }
            let url = base.appendingPathComponent("v1/chat/completions")
            let localNotePrefixes = ["Could not reach llama-server:", "Server error ", "No local model is running.", Self.webSearchNotePrefix, Self.fetchURLNotePrefix]
            // Explicitly [String: Any] (rather than the [String: String]
            // these literals would otherwise infer) so wireMessages below
            // can also hold the heterogeneous tool_calls/tool messages a
            // search round appends — a nested array, not a string.
            let cleanHistory: [[String: Any]] = messages.filter { message in
                !localNotePrefixes.contains(where: { message.content.hasPrefix($0) })
            }.map { ["role": $0.role, "content": wireContent(for: $0)] }
            let system: [String: Any] = ["role": "system", "content": profile.effectiveSystemPrompt(fallback: defaultSystemPrompt)]
            // Sent on every round below, not just the first — the model
            // needs it present on the follow-up request too, to either
            // call the tool again or (typically) answer using the result.
            var toolDefinitions: [[String: Any]] = []
            if webSearchEnabled && webSearchEnabledThisChat && WebSearch.normalizedBaseURL(webSearchSearXNGURL) != nil { toolDefinitions.append(WebSearch.toolDefinition) }
            if fetchURLEnabled { toolDefinitions.append(FetchURL.toolDefinition) }
            let tools: [[String: Any]]? = toolDefinitions.isEmpty ? nil : toolDefinitions
            var wireMessages: [[String: Any]] = [system] + cleanHistory
            var round = 0
            roundLoop: while true {
                round += 1
                var body: [String: Any] = [
                    "messages": wireMessages,
                    "stream": true,
                    "temperature": 0.7,
                    "max_tokens": profile.effectiveMaximumOutputTokens
                ]
                // mlx_lm.server uses its launch-time default model when the request
                // omits `model`. Supplying a friendly profile alias makes it try to
                // resolve that alias as another Hugging Face repository.
                if profile.runtime != .mlxLM { body["model"] = profile.alias }
                // Prevent a context submitted by another OpenAI-compatible client
                // (for example OpenCode) from being reused for this conversation.
                // This is a llama.cpp extension, so never send it to MLX servers.
                // Skipped for an exclusive profile for the same reason as the
                // slot erase above — see sharedServer.
                if profile.runtime == .llamaCPP && sharedServer { body["cache_prompt"] = false }
                if let tools { body["tools"] = tools }
                var request = URLRequest(url: url); request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                if networkSettings.authenticationEnabled && !networkSettings.apiKey.isEmpty { request.setValue("Bearer \(networkSettings.apiKey)", forHTTPHeaderField: "Authorization") }
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                guard 200..<300 ~= http.statusCode else {
                    var responseText = ""
                    for try await line in bytes.lines { responseText += line + "\n" }
                    if responseText.isEmpty { responseText = "No response body" }
                    messages.append(.init(role: "assistant", content: "Server error \(http.statusCode): \(responseText)"))
                    return
                }
                var streamedContent = ""
                var rawResponse = ""
                var assistantID: UUID?
                var reachedOutputLimit = false
                var toolCallsByIndex: [Int: PendingToolCall] = [:]
                for try await line in bytes.lines {
                    try Task.checkCancellation()
                    rawResponse += line + "\n"
                    guard line.hasPrefix("data:") else { continue }
                    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    guard !payload.isEmpty, payload != "[DONE]", let eventData = payload.data(using: .utf8),
                          let event = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any],
                          let choice = (event["choices"] as? [[String: Any]])?.first else { continue }
                    if (choice["finish_reason"] as? String) == "length" { reachedOutputLimit = true }
                    let delta = choice["delta"] as? [String: Any] ?? choice
                    if let calls = delta["tool_calls"] as? [[String: Any]] {
                        engineActivity = .toolCalling
                        for call in calls {
                            let index = call["index"] as? Int ?? 0
                            var pending = toolCallsByIndex[index] ?? PendingToolCall()
                            if let id = call["id"] as? String, !id.isEmpty { pending.id = id }
                            if let function = call["function"] as? [String: Any] {
                                if let name = function["name"] as? String, !name.isEmpty { pending.name = name }
                                if let argsFragment = function["arguments"] as? String { pending.arguments += argsFragment }
                            }
                            toolCallsByIndex[index] = pending
                        }
                    }
                    else if delta["function_call"] != nil { engineActivity = .functionCalling }
                    if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty { engineActivity = .reasoning }
                    guard let token = (delta["content"] as? String) ?? (delta["text"] as? String), !token.isEmpty else { continue }
                    guard activeChatID == generationChatID else { throw CancellationError() }
                    engineActivity = .streaming
                    streamedContent += token
                    if let assistantID, let index = messages.firstIndex(where: { $0.id == assistantID }) {
                        messages[index].content = streamedContent
                    } else {
                        let message = ChatMessage(role: "assistant", content: streamedContent)
                        assistantID = message.id
                        messages.append(message)
                    }
                }
                let toolCalls = toolCallsByIndex.sorted { $0.key < $1.key }.map(\.value).filter { !$0.name.isEmpty }
                if !toolCalls.isEmpty, tools != nil {
                    guard round <= Self.maximumToolRounds else {
                        messages.append(.init(role: "assistant", content: "Stopped after \(Self.maximumToolRounds) tool calls without a final answer. Try rephrasing your question."))
                        break roundLoop
                    }
                    // The model asked to call one or more tools instead of
                    // (or in addition to) answering directly. Run each
                    // one, feed the results back as `tool` messages, and
                    // loop for another round rather than treating this as
                    // the final answer. Any partial text streamed
                    // alongside the call (rare, but some models narrate
                    // before calling a tool) stays in the transcript as-is.
                    let toolCallsWire: [[String: Any]] = toolCalls.enumerated().map { offset, call in
                        ["id": call.id.isEmpty ? "call_\(round)_\(offset)" : call.id, "type": "function", "function": ["name": call.name, "arguments": call.arguments]]
                    }
                    wireMessages.append(["role": "assistant", "content": streamedContent, "tool_calls": toolCallsWire])
                    for (offset, call) in toolCalls.enumerated() {
                        guard activeChatID == generationChatID else { throw CancellationError() }
                        let callID = call.id.isEmpty ? "call_\(round)_\(offset)" : call.id
                        let resultText: String
                        if call.name == WebSearch.toolName {
                            let query = WebSearch.query(fromArguments: call.arguments) ?? call.arguments
                            messages.append(.init(role: "assistant", content: "\(Self.webSearchNotePrefix)“\(query)”"))
                            resultText = WebSearch.formatForModel(await WebSearch.search(query: query, baseURLString: webSearchSearXNGURL), query: query)
                        } else if call.name == FetchURL.toolName {
                            let requestedURL = FetchURL.url(fromArguments: call.arguments) ?? call.arguments
                            messages.append(.init(role: "assistant", content: "\(Self.fetchURLNotePrefix)\(requestedURL)"))
                            resultText = FetchURL.formatForModel(await FetchURL.fetch(urlString: requestedURL))
                        } else {
                            resultText = "The \"\(call.name)\" tool is not available."
                        }
                        wireMessages.append(["role": "tool", "tool_call_id": callID, "name": call.name, "content": resultText])
                    }
                    continue roundLoop
                }
                if reachedOutputLimit {
                    streamedContent += "\n\n> Response reached the profile’s \(profile.effectiveMaximumOutputTokens)-token output limit. Increase Maximum output tokens in this profile or ask the model to continue."
                    if let assistantID, let index = messages.firstIndex(where: { $0.id == assistantID }) { messages[index].content = streamedContent }
                }
                if streamedContent.isEmpty, let data = rawResponse.data(using: .utf8) {
                    streamedContent = Self.parseChatContent(data) ?? "(Empty response)"
                    messages.append(.init(role: "assistant", content: streamedContent))
                }
                if Self.looksLikeUnexpectedHTML(streamedContent, request: userText) {
                    if let assistantID { messages.removeAll { $0.id == assistantID } }
                    messages.append(.init(role: "assistant", content: "The model returned an unrelated HTML document. This usually indicates an incompatible llama.cpp build or chat template for this GGUF model. Update llama.cpp (`brew upgrade llama.cpp`) and restart the profile.\n\nRaw response begins:\n\n```html\n\(String(streamedContent.prefix(1200)))\n```"))
                }
                break roundLoop
            }
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            guard activeChatID == generationChatID else { return }
            messages.append(.init(role: "assistant", content: "Could not reach llama-server: \(error.localizedDescription)\n\nEndpoint: \(networkSettings.baseURL(runtime: profile.runtime)?.absoluteString ?? "not configured")"))
        }
    }

    func attachChatFiles(_ urls: [URL]) {
        var total = pendingChatAttachments.reduce(0) { $0 + $1.byteCount }
        for url in urls {
            if Self.isImageFile(url) {
                attachChatImage(url)
                continue
            }
            guard !pendingChatAttachments.contains(where: { $0.path == url.path }) else { continue }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true else { throw CocoaError(.fileReadUnsupportedScheme) }
                let size = values.fileSize ?? 0
                guard size <= ChatAttachmentPayload.maximumFileBytes else { throw CocoaError(.fileReadTooLarge) }
                let data = try Data(contentsOf: url)
                guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else { throw CocoaError(.fileReadInapplicableStringEncoding) }
                guard total + data.count <= ChatAttachmentPayload.maximumTotalBytes else { throw CocoaError(.fileReadTooLarge) }
                pendingChatAttachments.append(.init(name: url.lastPathComponent, path: url.path, text: text))
                total += data.count
            } catch {
                errorMessage = "Could not attach \(url.lastPathComponent). Use a UTF-8 text file up to 2 MB (8 MB total)."
            }
        }
    }

    private static func isImageFile(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType { return type.conforms(to: .image) }
        return UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }

    /// Attaches an image file for a vision-capable profile to see —
    /// llama-server accepts these as OpenAI-style image_url content
    /// parts once launched with its mmproj projector (see
    /// MultimodalProjector and ServerProfile.arguments(network:)).
    /// Always decodes, downscales to ChatImageAttachmentPolicy's bounds,
    /// and re-encodes (stripping EXIF/location metadata along the way)
    /// rather than passing the original bytes through — this bounds the
    /// eventual request size regardless of the source photo's resolution
    /// and normalizes odd source formats (HEIC, TIFF, WebP, ...) down to
    /// PNG or JPEG, the two formats llama.cpp's image decoder actually
    /// understands.
    private func attachChatImage(_ url: URL) {
        guard !pendingChatImageAttachments.contains(where: { $0.path == url.path }) else { return }
        guard !runningProfileLacksVisionProjector else {
            handleMissingRunningProjector()
            return
        }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .contentTypeKey])
            guard values.isRegularFile == true else { throw CocoaError(.fileReadUnsupportedScheme) }
            let size = values.fileSize ?? 0
            guard size <= ChatImageAttachmentPolicy.maximumSourceFileBytes else { throw CocoaError(.fileReadTooLarge) }
            let sourceData = try Data(contentsOf: url)
            let preferPNG = values.contentType?.conforms(to: .png) ?? false
            try ingestImageData(sourceData, name: url.lastPathComponent, path: url.path, preferPNG: preferPNG)
        } catch {
            errorMessage = "Could not attach \(url.lastPathComponent). Use a common image format (PNG, JPEG, HEIC, and similar) up to 40 MB."
        }
    }

    /// Same pipeline as attachChatImage(_:), for an image handed over as
    /// raw bytes rather than a file on disk — a paste from the clipboard
    /// (⌘V of a screenshot) rather than a dropped or picked file.
    func attachChatImage(pasteboardData data: Data, suggestedName: String) {
        guard !runningProfileLacksVisionProjector else {
            handleMissingRunningProjector()
            return
        }
        do {
            try ingestImageData(data, name: suggestedName, path: "clipboard-\(UUID().uuidString)", preferPNG: true)
        } catch {
            errorMessage = "Could not attach the pasted image."
        }
    }

    /// Called wherever an image attachment is refused because the running
    /// profile has no vision projector on disk yet. Previously this just
    /// dead-ended with a static "switch to a vision-capable model" alert
    /// -- even for one of this app's own vision presets (Qwen3-VL,
    /// Mistral Small 3.1, Gemma 3 12B), whose profile really is the right
    /// model, just missing the mmproj file an older build of this app
    /// never fetched (see ProfilePreset.mmprojFilename). When the running
    /// profile matches one of those by runtime+modelPath, start fetching
    /// just the missing projector (the same backfill "Add all presets"
    /// uses) instead of leaving the user stuck re-discovering that fix on
    /// their own. Anything else -- a custom or unconfirmed model -- still
    /// gets the original message.
    private func handleMissingRunningProjector() {
        guard let profile = profiles.first(where: { $0.id == runningProfileID }) else {
            errorMessage = "The running profile has no vision support — it can't be sent an image. Switch to a vision-capable model (one with a projector file) first."
            return
        }
        if let preset = ProfilePreset.all.first(where: { $0.profile.runtime == profile.runtime && $0.profile.modelPath == profile.modelPath }),
           preset.mmprojFilename != nil {
            errorMessage = "This model's vision projector file isn't downloaded yet -- fetching it now. Check the Downloads window, then try attaching the image again once it finishes."
            enqueuePresetDownload(preset, ownerProfileID: profile.id)
        } else {
            errorMessage = "The running profile has no vision support — it can't be sent an image. Switch to a vision-capable model (one with a projector file) first."
        }
    }

    private func ingestImageData(_ sourceData: Data, name: String, path: String, preferPNG: Bool) throws {
        guard let sourceImage = NSImage(data: sourceData),
              let cgImage = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let target = ChatImageAttachmentPolicy.targetSize(width: cgImage.width, height: cgImage.height)
        guard let (encoded, mimeType) = Self.encodedImage(cgImage, targetSize: target, preferPNG: preferPNG) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard encoded.count <= ChatImageAttachmentPolicy.maximumEncodedBytes else { throw CocoaError(.fileReadTooLarge) }
        let thumbnail = NSImage(cgImage: cgImage, size: NSSize(width: target.width, height: target.height))
        pendingChatImageAttachments.append(.init(name: name, path: path, data: encoded, mimeType: mimeType, thumbnail: thumbnail))
    }

    private static func encodedImage(_ cgImage: CGImage, targetSize: (width: Int, height: Int), preferPNG: Bool) -> (Data, String)? {
        let resized: CGImage
        if targetSize.width == cgImage.width && targetSize.height == cgImage.height {
            resized = cgImage
        } else {
            guard let context = CGContext(
                data: nil, width: targetSize.width, height: targetSize.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetSize.width, height: targetSize.height))
            guard let scaled = context.makeImage() else { return nil }
            resized = scaled
        }
        let rep = NSBitmapImageRep(cgImage: resized)
        if preferPNG {
            guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
            return (data, "image/png")
        } else {
            guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return nil }
            return (data, "image/jpeg")
        }
    }

    private static let chatImageCache = NSCache<NSString, NSImage>()

    /// Loads an already-persisted attachment's image data for display in
    /// the transcript, cached in memory since a filename's bytes never
    /// change once written.
    func loadedChatImage(_ attachment: ChatImageAttachment) -> NSImage? {
        let key = attachment.filename as NSString
        if let cached = Self.chatImageCache.object(forKey: key) { return cached }
        guard let image = NSImage(contentsOf: chatImagesDirectory.appendingPathComponent(attachment.filename)) else { return nil }
        Self.chatImageCache.setObject(image, forKey: key)
        return image
    }

    /// Copies each pending image's already-encoded bytes out to
    /// chatImagesDirectory under a fresh filename, returning the
    /// persisted references a new ChatMessage should carry. Images that
    /// fail to write are silently dropped rather than blocking the rest
    /// of the message from sending.
    private func persistPendingImages(_ pending: [PendingChatImageAttachment]) -> [ChatImageAttachment] {
        pending.compactMap { attachment in
            let ext = attachment.mimeType == "image/png" ? "png" : "jpg"
            let filename = "\(UUID().uuidString).\(ext)"
            do {
                try attachment.data.write(to: chatImagesDirectory.appendingPathComponent(filename), options: .atomic)
                return ChatImageAttachment(filename: filename, mimeType: attachment.mimeType)
            } catch {
                return nil
            }
        }
    }

    /// The `content` value to send for one message: a plain string for
    /// an ordinary text-only message (every message before this feature
    /// existed, and still the overwhelmingly common case), or — only
    /// when the message actually has image attachments — the
    /// OpenAI/llama-server vision shape: an array of {"type": "text"} /
    /// {"type": "image_url"} parts, each image read fresh off disk and
    /// base64-encoded. Reading happens once per turn here (wireMessages
    /// is built once before sendPrompt's round-loop starts), not on
    /// every streamed token or tool round.
    private func wireContent(for message: ChatMessage) -> Any {
        guard !message.imageAttachments.isEmpty else { return message.content }
        var parts: [[String: Any]] = []
        if !message.content.isEmpty { parts.append(["type": "text", "text": message.content]) }
        for image in message.imageAttachments {
            guard let data = try? Data(contentsOf: chatImagesDirectory.appendingPathComponent(image.filename)) else { continue }
            parts.append(["type": "image_url", "image_url": ["url": "data:\(image.mimeType);base64,\(data.base64EncodedString())"]])
        }
        return parts
    }

    /// Whether the running profile can't take image input, and image
    /// attachments should therefore be refused outright rather than
    /// queued and sent — see ChatImageAttachmentPolicy.blocksImageAttachment.
    var runningProfileLacksVisionProjector: Bool {
        guard let profile = profiles.first(where: { $0.id == runningProfileID }) else { return false }
        return ChatImageAttachmentPolicy.blocksImageAttachment(
            runtime: profile.runtime,
            hasProjector: MultimodalProjector.path(forModelPath: profile.modelPath) != nil
        )
    }

    func newChat(projectID: UUID? = nil) {
        cancelPrompt()
        let chat = SavedChat(title: "New conversation", projectID: projectID, messages: [])
        chats.insert(chat, at: 0)
        selectChat(chat.id)
    }

    func selectChat(_ id: UUID) {
        guard let chat = chats.first(where: { $0.id == id }) else { return }
        guard activeChatID != id else { return }
        freezeActiveChatTimer()
        cancelPrompt()
        isLoadingChat = true
        activeChatID = id
        activeChatStartedAt = Date()
        messages = chat.messages
        isLoadingChat = false
    }

    func chatElapsedSeconds(_ chat: SavedChat, at date: Date = Date()) -> TimeInterval {
        let stored = chat.elapsedSeconds ?? 0
        guard chat.id == activeChatID, let activeChatStartedAt else { return stored }
        return stored + max(0, date.timeIntervalSince(activeChatStartedAt))
    }

    private func freezeActiveChatTimer(at date: Date = Date()) {
        guard let id = activeChatID, let started = activeChatStartedAt,
              let index = chats.firstIndex(where: { $0.id == id }) else { return }
        chats[index].elapsedSeconds = (chats[index].elapsedSeconds ?? 0) + max(0, date.timeIntervalSince(started))
        activeChatStartedAt = nil
    }

    func renameChat(_ id: UUID, to title: String) {
        guard let index = chats.firstIndex(where: { $0.id == id }) else { return }
        chats[index].title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled chat" : title
        chats[index].updatedAt = Date()
    }

    func deleteChat(_ id: UUID) {
        chats.removeAll { $0.id == id }
        if activeChatID == id {
            if let next = chats.first { selectChat(next.id) } else { newChat() }
        }
        pruneOrphanedChatImages()
    }

    // Deletes any file under chatImagesDirectory that no message in any
    // chat still references. Run at startup and after deleting a whole
    // chat -- the two moments most likely to actually orphan something;
    // an image dropped by editing or regenerating mid-session is caught
    // the next time either of those runs rather than immediately, which
    // is a fine trade against pruning on every single message mutation.
    private func pruneOrphanedChatImages() {
        let referenced = Set(chats.flatMap { $0.messages.flatMap(\.imageAttachments).map(\.filename) })
        let onDisk = (try? FileManager.default.contentsOfDirectory(atPath: chatImagesDirectory.path)) ?? []
        for filename in ChatImageStorage.orphanedFilenames(referenced: referenced, onDisk: onDisk) {
            try? FileManager.default.removeItem(at: chatImagesDirectory.appendingPathComponent(filename))
        }
    }

    func createChatProject(named name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        chatProjects.append(.init(name: clean.isEmpty ? "New project" : clean))
    }

    func renameChatProject(_ id: UUID, to name: String) {
        guard let index = chatProjects.firstIndex(where: { $0.id == id }) else { return }
        chatProjects[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled project" : name
    }

    func deleteChatProject(_ id: UUID) {
        chatProjects.removeAll { $0.id == id }
        for index in chats.indices where chats[index].projectID == id { chats[index].projectID = nil }
    }

    func moveChat(_ chatID: UUID, to projectID: UUID?) {
        guard let index = chats.firstIndex(where: { $0.id == chatID }) else { return }
        chats[index].projectID = projectID
        chats[index].updatedAt = Date()
    }

    func clearConversation() { newChat() }

    private func updateActiveChat() {
        guard !isLoadingChat, let id = activeChatID, let index = chats.firstIndex(where: { $0.id == id }) else { return }
        chats[index].messages = messages
        chats[index].updatedAt = Date()
        if chats[index].title == "New conversation", let first = messages.first(where: { $0.role == "user" }) {
            chats[index].title = String(first.content.prefix(52))
        }
    }

    private func saveChats() { try? JSONEncoder().encode(chats).write(to: chatsURL, options: .atomic) }
    private func saveChatProjects() { try? JSONEncoder().encode(chatProjects).write(to: chatProjectsURL, options: .atomic) }

    func isMLXModelCached(_ modelID: String) -> Bool {
        let expanded = NSString(string: modelID).expandingTildeInPath
        if FileManager.default.fileExists(atPath: (expanded as NSString).appendingPathComponent("config.json")), mlxWeightsExist(at: URL(fileURLWithPath: expanded)) { return true }
        return resolvedMLXSnapshot(for: modelID) != nil
    }

    func resolvedMLXSnapshot(for modelID: String) -> URL? {
        MLXSnapshotResolver.resolve(modelID: modelID, root: configuredModelRoot)
    }

    private func reconcileMLXProfilePaths() {
        for index in profiles.indices where !profiles[index].runtime.usesGGUF {
            let modelID = profiles[index].modelPath
            if let snapshot = resolvedMLXSnapshot(for: modelID) {
                recordModelMetadata(.init(sourceModelID: modelID, revision: snapshot.lastPathComponent, filename: snapshot.lastPathComponent, checksumSHA256: nil, format: "MLX", localPath: snapshot.path, size: Self.directoryByteCount(snapshot), downloadedAt: Date()))
                profiles[index].modelPath = snapshot.path
            }
        }
    }

    private func mlxWeightsExist(at directory: URL) -> Bool {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return false }
        return files.contains { $0.pathExtension.lowercased() == "safetensors" && FileManager.default.fileExists(atPath: $0.path) }
    }

    private func eraseAllServerSlots() async {
        guard !slotEraseUnsupported,
              let profile = profiles.first(where: { $0.id == runningProfileID }),
              let base = networkSettings.baseURL(runtime: profile.runtime) else { return }
        let slotCount = max(profile.parallel, 1)
        var erased = 0
        for id in 0..<slotCount {
            do {
                guard var components = URLComponents(url: base.appendingPathComponent("slots/\(id)"), resolvingAgainstBaseURL: false) else { continue }
                components.queryItems = [URLQueryItem(name: "action", value: "erase")]
                guard let url = components.url else { continue }
                var eraseRequest = URLRequest(url: url)
                eraseRequest.httpMethod = "POST"
                eraseRequest.timeoutInterval = 3
                eraseRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                eraseRequest.httpBody = Data("{}".utf8)
                if networkSettings.authenticationEnabled && !networkSettings.apiKey.isEmpty {
                    eraseRequest.setValue("Bearer \(networkSettings.apiKey)", forHTTPHeaderField: "Authorization")
                }
                let (data, response) = try await URLSession.shared.data(for: eraseRequest)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if 200..<300 ~= status {
                    erased += 1
                } else if status == 501 {
                    // llama-server only supports the erase action when
                    // launched with --slot-save-path, which InferenceBar
                    // never sets (that would mean choosing and creating a
                    // directory for a save/restore feature nothing here
                    // ever calls). cache_prompt: false on every request
                    // already prevents another client's cached prefix from
                    // being reused for this conversation, so this is an
                    // expected, harmless no-op here — not a real failure,
                    // and every launched llama-server will report it the
                    // same way, so it's remembered for the rest of this
                    // app session rather than retried (and logged) on
                    // every single message.
                    slotEraseUnsupported = true
                    return
                } else {
                    let body = String(data: data, encoding: .utf8) ?? "non-text response"
                    logs += "Chat isolation: slot \(id) erase returned HTTP \(status): \(body.prefix(240)).\n"
                }
            } catch {
                logs += "Chat isolation: slot \(id) erase failed (\(error.localizedDescription)).\n"
            }
        }
        logs += "Chat isolation: erased \(erased) of \(slotCount) llama-server slot(s).\n"
    }

    private static func parseChatContent(_ data: Data) -> String? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let choices = json["choices"] as? [[String: Any]], let first = choices.first {
            if let message = first["message"] as? [String: Any] {
                if let content = message["content"] as? String { return content }
                if let reasoning = message["reasoning_content"] as? String { return reasoning }
                if let parts = message["content"] as? [[String: Any]] {
                    let text = parts.compactMap { $0["text"] as? String }.joined()
                    if !text.isEmpty { return text }
                }
            }
            if let text = first["text"] as? String { return text }
        }
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        var streamed = ""
        for line in raw.split(whereSeparator: \.isNewline) {
            let value = line.hasPrefix("data:") ? line.dropFirst(5).trimmingCharacters(in: .whitespaces) : ""
            guard !value.isEmpty, value != "[DONE]", let eventData = value.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any],
                  let choices = event["choices"] as? [[String: Any]], let first = choices.first else { continue }
            if let delta = first["delta"] as? [String: Any] { streamed += delta["content"] as? String ?? delta["reasoning_content"] as? String ?? "" }
            else { streamed += first["text"] as? String ?? "" }
        }
        if !streamed.isEmpty { return streamed }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func looksLikeUnexpectedHTML(_ content: String, request: String) -> Bool {
        let response = content.lowercased()
        let prompt = request.lowercased()
        return (response.contains("<!doctype html") || response.contains("<html")) &&
            !prompt.contains("html") && !prompt.contains("website") && !prompt.contains("web page") && !prompt.contains("code")
    }

    @discardableResult
    func restoreExistingMainWindow() -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        guard let window = NSApp.windows.first(where: {
            $0.canBecomeMain && ($0.title == "InferenceBar" || $0.isMiniaturized)
        }) else { return false }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        return true
    }

    private func loadProfiles() {
        guard let data = try? Data(contentsOf: profilesURL), let saved = try? JSONDecoder().decode([ServerProfile].self, from: data) else { return }
        profiles = saved
    }
    private func saveProfiles() { if let data = try? JSONEncoder().encode(profiles) { try? data.write(to: profilesURL, options: .atomic) } }
    private func saveNetworkSettings() {
        // apiKey is deliberately excluded from GlobalServerSettings' Codable
        // keys, so this JSON never carries it; it goes to the keychain
        // instead, separately, below.
        if let data = try? JSONEncoder().encode(networkSettings) { try? data.write(to: networkSettingsURL, options: .atomic) }
        APIKeyKeychain.save(networkSettings.apiKey)
    }
    private func saveFavorites() { if let data = try? JSONEncoder().encode(favoriteProfileIDs) { try? data.write(to: favoritesURL, options: .atomic) } }
    private func resolveExecutable(_ configured: String) -> URL? {
        let fileManager = FileManager.default
        if configured.contains("/") {
            let path = NSString(string: configured).expandingTildeInPath
            return fileManager.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = ["/opt/homebrew/bin/\(configured)", "/usr/local/bin/\(configured)", "/usr/bin/\(configured)", "\(home)/.local/bin/\(configured)", "\(home)/.venvs/mlx/bin/\(configured)", "\(home)/.venv/bin/\(configured)"]
        if let pythonBins = try? FileManager.default.contentsOfDirectory(atPath: "\(home)/Library/Python") {
            for version in pythonBins { candidates.append("\(home)/Library/Python/\(version)/bin/\(configured)") }
        }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/\(configured)" }
        }
        return candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    private func waitForServerReadiness(process: Process?, profileID: UUID) async {
        guard let profile = profiles.first(where: { $0.id == profileID }),
              let base = networkSettings.baseURL(runtime: profile.runtime) else { return }
        if profile.runtime == .mlxLM {
            // mlx_lm.server publishes both /health and /v1/models before its
            // background downloader/loader has produced a usable model. A tiny
            // completion is the only reliable end-to-end readiness probe.
            let readinessURL = base.appendingPathComponent("v1/chat/completions")
            for _ in 0..<120 {
                guard !Task.isCancelled, process?.isRunning == true else { return }
                var request = URLRequest(url: readinessURL)
                request.httpMethod = "POST"
                request.timeoutInterval = 30
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try? JSONSerialization.data(withJSONObject: [
                    "messages": [["role": "user", "content": "Reply with OK."]],
                    "max_tokens": 1,
                    "temperature": 0,
                    "stream": false
                ])
                if let (_, response) = try? await URLSession.shared.data(for: request),
                   let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode {
                    guard runningProfileID == profileID else { return }
                    serverLifecycle = .running
                    appendLogEntry("Apple MLX · mlx-lm finished loading and is ready at \(base.absoluteString).")
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
            guard process?.isRunning == true else { return }
            serverLifecycle = .failed("model load timed out")
            failedProfileID = profileID
            errorMessage = "mlx-lm is running but the model did not finish downloading and loading. Check Logs and available disk space, then retry."
            return
        }
        let readinessURLs = profile.runtime == .llamaCPP ? [base.appendingPathComponent("health")] : [base.appendingPathComponent("v1/models")]
        for _ in 0..<1200 {
            guard !Task.isCancelled, process?.isRunning == true else { return }
            for readinessURL in readinessURLs {
                var request = URLRequest(url: readinessURL); request.timeoutInterval = 0.4
                if networkSettings.authenticationEnabled && !networkSettings.apiKey.isEmpty { request.setValue("Bearer \(networkSettings.apiKey)", forHTTPHeaderField: "Authorization") }
                if let (_, response) = try? await URLSession.shared.data(for: request), let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode {
                    guard runningProfileID == profileID else { return }
                    serverLifecycle = .running
                    appendLogEntry("\(profile.runtime.title) is ready at \(base.absoluteString).")
                    return
                }
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard process?.isRunning == true else { return }
        serverLifecycle = .failed("readiness timed out")
        failedProfileID = profileID
        errorMessage = "The inference server is still running but did not become ready within 5 minutes. Check Logs for model-loading or port errors."
    }
    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { throw URLError(.badServerResponse) }
    }
}

extension Notification.Name {
    static let inferenceServerLifecycleChanged = Notification.Name("InferenceBar.serverLifecycleChanged")
    static let inferenceHotkeySettingChanged = Notification.Name("InferenceBar.hotkeySettingChanged")
}

private enum DownloadChecksumResult: Equatable { case verified, unavailable }

private enum ChecksumVerifier {
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func verifyCachedModel(_ modelID: String, cacheRoot: URL) throws -> Int {
        let repo = "models--" + modelID.replacingOccurrences(of: "/", with: "--")
        let blobs = cacheRoot.appendingPathComponent("\(repo)/blobs")
        guard let files = try? FileManager.default.contentsOfDirectory(at: blobs, includingPropertiesForKeys: nil) else { return 0 }
        var verified = 0
        for file in files {
            let expected = file.lastPathComponent.lowercased()
            guard expected.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { continue }
            let actual = try sha256(of: file)
            guard actual == expected else { throw NSError(domain: "InferenceBar.Checksum", code: 1, userInfo: [NSLocalizedDescriptionKey: "Checksum mismatch for \(file.lastPathComponent)"]) }
            verified += 1
        }
        return verified
    }
}

/// Downloads one GGUF file, either as a single stream (the original
/// behavior, still used as a fallback) or as several concurrent HTTP
/// Range requests sharing one destination file (see
/// ParallelDownloadPlanner in Models.swift for why that's faster
/// against Hugging Face's CDN). Callers (AppStore.download(file:...))
/// don't need to know which path ran -- both report progress and
/// return a DownloadChecksumResult the same way.
///
/// Only the single-stream path can resume across a pause/cancel that
/// outlives the app process: its resumeData is opaque URLSession state
/// with nowhere to persist an equivalent for four independent byte
/// ranges, so a parallel download that's cancelled or fails restarts
/// from scratch on the next attempt -- the same thing the existing
/// checksum-mismatch retry already does today, and still fast since it
/// re-splits into parallel ranges again rather than falling back to one
/// stream. Pausing and resuming *within* the same run (the common
/// case -- the pause button in ProfileEditor) works for both paths,
/// since URLSessionTask.suspend()/resume() applies equally to a data
/// task and a download task.
///
/// All the delegate callbacks below run one at a time on `session`'s
/// own private delegate queue (URLSession's guarantee when it's handed
/// `delegateQueue: nil`), even though up to four of this session's data
/// tasks are in flight together -- so the mutable per-chunk bookkeeping
/// here needs no locking of its own.
private final class DownloadController: NSObject, URLSessionDataDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<DownloadChecksumResult, Error>?
    private var destination: URL?
    private var progressHandler: (@MainActor @Sendable (Int64, Int64) -> Void)?
    private var phaseHandler: (@MainActor @Sendable (String) -> Void)?
    private var session: URLSession?
    private var finished = false
    private var expectedSHA256: String?
    private var source: URL?

    // Single-stream fallback: used when the source doesn't advertise
    // Range support, is too small to be worth splitting, or a previous
    // run of this same destination already left resumeData behind.
    private var fallbackTask: URLSessionDownloadTask?

    // Parallel chunked download.
    private struct Chunk {
        let range: ClosedRange<Int64>
        var written: Int64 = 0
        var task: URLSessionDataTask?
    }
    private var chunks: [Chunk] = []
    private var chunkIndexByTaskIdentifier: [Int: Int] = [:]
    private var fileHandle: FileHandle?
    private var totalBytesExpected: Int64 = 0
    private var completedChunkCount = 0
    private var chunksFailed = false
    // Covers the brief async gap (the Range probe below) between
    // activeDownloader being handed to the caller and any actual task
    // existing to cancel -- without this, a cancel() that lands in that
    // window would silently do nothing instead of stopping the download.
    private var cancelRequested = false

    func download(
        from source: URL,
        to destination: URL,
        expectedSHA256: String?,
        phase: @escaping @MainActor @Sendable (String) -> Void,
        progress: @escaping @MainActor @Sendable (Int64, Int64) -> Void
    ) async throws -> DownloadChecksumResult {
        self.destination = destination
        self.source = source
        self.expectedSHA256 = expectedSHA256
        self.progressHandler = progress
        self.phaseHandler = phase

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session

        if let resumeData = DownloadResumeStore.load(for: destination), !resumeData.isEmpty {
            if let phaseHandler = self.phaseHandler { Task { @MainActor in phaseHandler("Resuming download") } }
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let task = session.downloadTask(withResumeData: resumeData)
                self.fallbackTask = task
                task.resume()
            }
        }

        let totalBytes = await Self.probeRangeSupport(source: source)
        if cancelRequested { throw CancellationError() }
        if let totalBytes, ParallelDownloadPlanner.shouldSplit(totalBytes: totalBytes) {
            do {
                return try await runParallel(totalBytes: totalBytes)
            } catch is ParallelSetupFailure {
                // Couldn't even get as far as issuing the chunk requests
                // (e.g. the destination file couldn't be preallocated) --
                // fall through to the plain single-stream path below
                // rather than failing the whole download over something
                // that path doesn't need at all.
            }
        }
        return try await runFallback()
    }

    func pause() {
        if let fallbackTask { fallbackTask.suspend(); return }
        for chunk in chunks { chunk.task?.suspend() }
    }

    func resume() {
        if let fallbackTask { fallbackTask.resume(); return }
        for chunk in chunks { chunk.task?.resume() }
    }

    func cancel() {
        if let fallbackTask, let destination {
            fallbackTask.cancel { resumeData in
                if let resumeData, !resumeData.isEmpty { try? DownloadResumeStore.save(resumeData, for: destination) }
            }
            return
        }
        if !chunks.isEmpty {
            for chunk in chunks { chunk.task?.cancel() }
            return
        }
        cancelRequested = true
    }

    // MARK: - Single-stream fallback

    private func runFallback() async throws -> DownloadChecksumResult {
        guard let source, let session else { throw URLError(.unknown) }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            var request = URLRequest(url: source, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 120)
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            request.setValue("no-cache", forHTTPHeaderField: "Pragma")
            let task = session.downloadTask(with: request)
            self.fallbackTask = task
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let total = max(totalBytesExpectedToWrite, 0)
        if let progressHandler {
            Task { @MainActor in progressHandler(totalBytesWritten, total) }
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let destination else { return finish(.failure(URLError(.cannotCreateFile))) }
        do {
            let checksum: DownloadChecksumResult
            if let expected = expectedSHA256 {
                if let phaseHandler { Task { @MainActor in phaseHandler("Verifying checksum") } }
                let actual = try ChecksumVerifier.sha256(of: location)
                guard actual == expected else { throw NSError(domain: "InferenceBar.Checksum", code: 2, userInfo: [NSLocalizedDescriptionKey: "Downloaded file checksum mismatch. Expected \(expected), got \(actual)."]) }
                checksum = .verified
            } else { checksum = .unavailable }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            DownloadResumeStore.remove(for: destination)
            finish(.success(checksum))
        } catch {
            if (error as NSError).domain == "InferenceBar.Checksum" {
                DownloadResumeStore.remove(for: destination)
            }
            finish(.failure(error))
        }
    }

    // MARK: - Parallel chunked download

    private struct ParallelSetupFailure: Error {}

    /// A lightweight "Range: bytes=0-0" probe: if Hugging Face's CDN
    /// answers 206 with a Content-Range total, splitting is worth
    /// trying; anything else (200 meaning the range was ignored, a
    /// non-CDN host, a network hiccup) means "don't know, don't split".
    /// Uses a plain, delegate-less session so it can't interfere with
    /// the real download's URLSession below.
    private static func probeRangeSupport(source: URL) async -> Int64? {
        var request = URLRequest(url: source, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 206,
              let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
              let slashIndex = contentRange.lastIndex(of: "/"),
              let total = Int64(contentRange[contentRange.index(after: slashIndex)...]) else { return nil }
        return total
    }

    private func runParallel(totalBytes: Int64) async throws -> DownloadChecksumResult {
        guard let destination, let source, let session else { throw ParallelSetupFailure() }
        let directory = destination.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: destination.path) {
                guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw ParallelSetupFailure() }
            }
            let handle = try FileHandle(forWritingTo: destination)
            try handle.truncate(atOffset: UInt64(totalBytes))
            self.fileHandle = handle
        } catch {
            throw ParallelSetupFailure()
        }
        self.totalBytesExpected = totalBytes
        self.chunks = ParallelDownloadPlanner.chunkRanges(totalBytes: totalBytes).map { Chunk(range: $0) }
        self.completedChunkCount = 0
        self.chunksFailed = false
        if let phaseHandler { Task { @MainActor in phaseHandler("Downloading (parallel)") } }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            for index in chunks.indices {
                var request = URLRequest(url: source, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 120)
                request.setValue("bytes=\(chunks[index].range.lowerBound)-\(chunks[index].range.upperBound)", forHTTPHeaderField: "Range")
                request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                let task = session.dataTask(with: request)
                chunkIndexByTaskIdentifier[task.taskIdentifier] = index
                chunks[index].task = task
                task.resume()
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 206 else {
            completionHandler(.cancel)
            failChunks(with: URLError(.cannotDecodeContentData))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let index = chunkIndexByTaskIdentifier[dataTask.taskIdentifier], let fileHandle else { return }
        let offset = chunks[index].range.lowerBound + chunks[index].written
        do {
            try fileHandle.seek(toOffset: UInt64(offset))
            try fileHandle.write(contentsOf: data)
        } catch {
            failChunks(with: error)
            return
        }
        chunks[index].written += Int64(data.count)
        let totalWritten = chunks.reduce(Int64(0)) { $0 + $1.written }
        if let progressHandler {
            let total = totalBytesExpected
            Task { @MainActor in progressHandler(totalWritten, total) }
        }
    }

    /// Shared by the fallback (download task) and parallel (data task)
    /// paths -- URLSession calls this for either kind, distinguished by
    /// which one is actually in flight for this controller.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let dataTask = task as? URLSessionDataTask, let index = chunkIndexByTaskIdentifier[dataTask.taskIdentifier] {
            handleChunkCompletion(index: index, error: error)
            return
        }
        if let error {
            let nsError = error as NSError
            if let destination,
               let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
               !resumeData.isEmpty {
                try? DownloadResumeStore.save(resumeData, for: destination)
            }
            finish(.failure(error))
        }
    }

    private func handleChunkCompletion(index: Int, error: Error?) {
        if let error {
            failChunks(with: error)
            return
        }
        let expectedLength = chunks[index].range.upperBound - chunks[index].range.lowerBound + 1
        guard chunks[index].written >= expectedLength else {
            // The connection closed without an error but also without
            // delivering this chunk's full range -- a short read is
            // still a failure, not a silently-truncated file.
            failChunks(with: URLError(.zeroByteResource))
            return
        }
        completedChunkCount += 1
        guard completedChunkCount == chunks.count else { return }
        finishParallelDownload()
    }

    private func failChunks(with error: Error) {
        guard !chunksFailed else { return }
        chunksFailed = true
        for chunk in chunks { chunk.task?.cancel() }
        try? fileHandle?.close()
        fileHandle = nil
        if let destination { try? FileManager.default.removeItem(at: destination) }
        finish(.failure(error))
    }

    private func finishParallelDownload() {
        guard let destination else { return finish(.failure(URLError(.cannotCreateFile))) }
        do {
            try fileHandle?.close()
            fileHandle = nil
            let checksum: DownloadChecksumResult
            if let expectedSHA256 {
                if let phaseHandler { Task { @MainActor in phaseHandler("Verifying checksum") } }
                let actual = try ChecksumVerifier.sha256(of: destination)
                guard actual == expectedSHA256 else { throw NSError(domain: "InferenceBar.Checksum", code: 2, userInfo: [NSLocalizedDescriptionKey: "Downloaded file checksum mismatch. Expected \(expectedSHA256), got \(actual)."]) }
                checksum = .verified
            } else { checksum = .unavailable }
            finish(.success(checksum))
        } catch {
            if (error as NSError).domain == "InferenceBar.Checksum" {
                try? FileManager.default.removeItem(at: destination)
            }
            finish(.failure(error))
        }
    }

    private func finish(_ result: Result<DownloadChecksumResult, Error>) {
        guard !finished else { return }
        finished = true
        session?.finishTasksAndInvalidate()
        continuation?.resume(with: result)
        continuation = nil
    }
}
