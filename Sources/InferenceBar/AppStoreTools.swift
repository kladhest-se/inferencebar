import AppKit
import Foundation

// The store's side of the speed test, the OpenCode launcher and the in-app
// update download. The pure logic they rely on is in Utilities.swift; the
// stored properties (an @Observable class cannot gain them in an extension)
// are declared in AppStore.swift beside `lastUpdateCheck`.

extension AppStore {
    /// Profiles that came from a "Coding" preset, i.e. the ones OpenCode gets.
    var codingPresetProfiles: [ServerProfile] {
        profiles.filter { profile in
            ProfilePreset.all.contains { $0.matches(profile) && $0.useCases.contains(.coding) }
        }
    }

    // MARK: Speed test

    /// Measures the running profile: generation speed from a short story
    /// prompt, and prompt-processing speed from a long filler prompt asking
    /// for a single token. Two requests, no streaming, nothing saved.
    func runSpeedTest() async {
        guard !isRunningSpeedTest else { return }
        guard serverLifecycle == .running,
              let id = runningProfileID,
              let profile = profiles.first(where: { $0.id == id }),
              let base = networkSettings.baseURL(runtime: profile.runtime) else {
            speedTestError = "Start a profile and wait until it is running, then try again."
            return
        }
        isRunningSpeedTest = true
        speedTestError = nil
        defer { isRunningSpeedTest = false }

        let url = base.appendingPathComponent("v1/chat/completions")
        // mlx_lm.server resolves a `model` name as a repository, so it is omitted there.
        let model: String? = profile.runtime == .mlxLM ? nil : profile.alias
        let isLlamaCPP = profile.runtime == .llamaCPP

        let generation = await speedTestRequest(
            url: url,
            body: SpeedTest.requestBody(model: model, prompt: SpeedTest.generationPrompt, maxTokens: SpeedTest.generationTokenLimit, llamaCPP: isLlamaCPP)
        )
        guard speedTestError == nil else { return }
        let targetTokens = SpeedTest.promptTokenTarget(contextSize: profile.contextSize, parallel: profile.parallel)
        let prompt = await speedTestRequest(
            url: url,
            body: SpeedTest.requestBody(model: model, prompt: SpeedTest.longPrompt(approximateTokens: targetTokens, nonce: UUID().uuidString), maxTokens: 1, llamaCPP: isLlamaCPP)
        )
        guard speedTestError == nil else { return }
        guard let summary = SpeedTest.summary(profileName: profile.name, prompt: prompt, generation: generation) else {
            speedTestError = "The server's reply did not include token counts, so no speed could be worked out."
            return
        }
        speedTestSummary = summary
    }

    private func speedTestRequest(url: URL, body: [String: Any]) async -> SpeedMeasurement? {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if networkSettings.authenticationEnabled && !networkSettings.apiKey.isEmpty {
            request.setValue("Bearer \(networkSettings.apiKey)", forHTTPHeaderField: "Authorization")
        }
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let started = Date()
            let (data, response) = try await URLSession.shared.data(for: request)
            let elapsed = Date().timeIntervalSince(started)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard 200..<300 ~= http.statusCode else {
                speedTestError = "Server error \(http.statusCode): " + String(decoding: data.prefix(300), as: UTF8.self)
                return nil
            }
            return SpeedTest.parse(data, elapsedSeconds: elapsed)
        } catch {
            speedTestError = "Speed test failed: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: Open OpenCode in a project folder

    /// Opens Terminal in `directory` running OpenCode, starting a coding
    /// profile first when no server is up. The terminal script waits for the
    /// server itself, so a model that is still loading is not a race.
    func launchOpenCode(in directory: URL) {
        let isActive: Bool
        switch serverLifecycle {
        case .stopped, .failed: isActive = false
        default: isActive = true
        }
        let plan = OpenCodeLauncher.plan(
            codingProfileIDs: codingPresetProfiles.map(\.id),
            runningProfileID: runningProfileID,
            serverIsActive: isActive,
            defaultProfileID: defaultCodingProfileID
        )
        let profileID: UUID
        switch plan {
        case .noProfile:
            errorMessage = "No profile from a \"Coding\" preset has been added yet. Add one first (Manage → Add preset)."
            return
        case .blocked(let message):
            errorMessage = message
            return
        case .useRunning(let id):
            profileID = id
        case .startProfile(let id):
            guard canStartProfile else {
                errorMessage = "The server is busy changing state. Wait a moment and try again."
                return
            }
            selectedProfileID = id
            errorMessage = nil
            start()
            // start() reports its own problems (model not downloaded, runtime
            // missing, ...) through errorMessage; don't open a terminal that
            // has nothing to talk to.
            guard errorMessage == nil, serverLifecycle != .stopped else { return }
            profileID = id
        }
        // Someone who never picked a default gets the profile used here, so
        // OpenCode opens with it selected instead of with no model.
        if defaultCodingProfileID == nil { defaultCodingProfileID = profileID }
        syncCodingProfilesToOpenCode()

        guard let profile = profiles.first(where: { $0.id == profileID }),
              let base = networkSettings.baseURL(runtime: profile.runtime) else { return }
        let probe = base.appendingPathComponent(profile.runtime == .llamaCPP ? "health" : "v1/models").absoluteString
        let script = OpenCodeLauncher.script(directory: directory.path, healthURL: probe, authenticationEnabled: networkSettings.authenticationEnabled)
        do {
            try OpenCodeLauncher.launch(script: script)
        } catch {
            errorMessage = "Could not open Terminal: \(error.localizedDescription)"
        }
    }

    // MARK: Update download

    /// Downloads the release's DMG from GitHub into Downloads, checks it
    /// against the published SHA-256 when there is one, and opens it. A
    /// release without a DMG on GitHub opens its release page instead.
    func downloadAndOpenUpdate(tag: String) async {
        guard !isInstallingUpdate else { return }
        isInstallingUpdate = true
        defer { isInstallingUpdate = false }

        let filename = UpdateDownload.dmgFilename(tag: tag)
        guard let dmgURL = UpdateDownload.assetURL(tag: tag, filename: filename),
              let checksumURL = UpdateDownload.assetURL(tag: tag, filename: filename + ".sha256") else {
            updateInstallStatus = "Could not build a download address for \(tag)."
            return
        }
        updateInstallStatus = "Downloading \(filename)…"
        do {
            var request = URLRequest(url: dmgURL)
            request.setValue("InferenceBar/\(Self.appVersion)", forHTTPHeaderField: "User-Agent")
            let (temporaryURL, response) = try await URLSession.shared.download(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if http.statusCode == 404 {
                openReleasePage(tag: tag)
                updateInstallStatus = "This release has no \(filename) on GitHub, so its page was opened instead."
                return
            }
            guard 200..<300 ~= http.statusCode else { throw URLError(.badServerResponse) }

            var note = "no SHA-256 was published for it"
            if let (checksumData, checksumResponse) = try? await URLSession.shared.data(from: checksumURL),
               let checksumHTTP = checksumResponse as? HTTPURLResponse, 200..<300 ~= checksumHTTP.statusCode,
               let expected = UpdateDownload.expectedSHA256(fromChecksumFile: String(decoding: checksumData, as: UTF8.self)) {
                let actual = try UpdateDownload.sha256Hex(of: temporaryURL)
                guard actual == expected else {
                    try? FileManager.default.removeItem(at: temporaryURL)
                    updateInstallStatus = "The downloaded file does not match its published SHA-256, so it was discarded. Try again, or download it from the release page."
                    return
                }
                note = "SHA-256 verified"
            }

            let downloads = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let destination = downloads.appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            NSWorkspace.shared.open(destination)
            updateInstallStatus = "Opened \(filename) from your Downloads folder (\(note)). Drag InferenceBar to Applications, replace the old copy, and open it again."
        } catch {
            updateInstallStatus = "Download failed: \(error.localizedDescription)"
        }
    }

    func openReleasePage(tag: String) {
        let encoded = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tag
        if let url = URL(string: "https://github.com/\(UpdateDownload.repository)/releases/tag/\(encoded)") {
            NSWorkspace.shared.open(url)
        }
    }
}
