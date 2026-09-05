import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AboutInferenceBarView: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().scaledToFit().frame(width: 92, height: 92)
            VStack(spacing: 5) {
                Text("InferenceBar").font(.largeTitle.weight(.semibold))
                Text("Version 0.5").foregroundStyle(.secondary)
                Text("A native macOS manager for running, downloading, and chatting with local language models.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 390)
            }
            Divider()
            VStack(spacing: 10) {
                Link(destination: URL(string: "https://inferencebar.kladhest.se")!) { Label("inferencebar.kladhest.se", systemImage: "globe") }
                Link(destination: URL(string: "https://github.com/kladhest-se/inferencebar")!) { Label("github.com/kladhest-se/inferencebar", systemImage: "chevron.left.forwardslash.chevron.right") }
            }
            Text("Licensed under the GNU General Public License v3 or later.")
                .font(.callout.weight(.medium)).multilineTextAlignment(.center)
            Link("Read the GPLv3 license", destination: URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!).font(.caption)
        }
        .padding(30).frame(minWidth: 460, minHeight: 390)
    }
}

enum ModelArea: String, CaseIterable, Identifiable {
    case downloaded = "Downloaded", recommendedCoding = "Coding Picks", recommendedChat = "Chat Picks", recommendedSystems = "Sysadmin Picks", recommendedHomeAutomation = "Home Automation", recommendedAppleSilicon = "Apple Silicon", trending = "Trending", mostDownloaded = "Most downloaded", recentlyUpdated = "Recently updated", text = "Text & Chat", coding = "Coding", multimodal = "Multimodal", vision = "Vision", audio = "Audio", languages = "Languages"
    var id: Self { self }
    var categories: [ModelCategory] {
        switch self {
        case .downloaded: []
        case .recommendedCoding: [.recommendedCoding]
        case .recommendedChat: [.recommendedChat]
        case .recommendedSystems: [.recommendedSystems]
        case .recommendedHomeAutomation: [.recommendedHomeAutomation]
        case .recommendedAppleSilicon: [.recommendedAppleSilicon]
        case .trending: [.trending]
        case .mostDownloaded: [.mostDownloaded]
        case .recentlyUpdated: [.recentlyUpdated]
        case .text: [.all] + ModelCategory.nlp
        case .coding: [.all] + ModelCategory.coding
        case .multimodal: [.all] + ModelCategory.multimodal
        case .vision: [.all] + ModelCategory.computerVision
        case .audio: [.all] + ModelCategory.audio
        case .languages: [.all] + ModelCategory.languages
        }
    }
}

struct ContentView: View {
    @Environment(AppStore.self) private var store
    @State private var modelArea: ModelArea = .recommendedChat

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            List(selection: $store.requestedSection) {
                Label("Profiles", systemImage: "slider.horizontal.3").tag(AppSection.profiles)
                Label("Models", systemImage: "square.and.arrow.down").tag(AppSection.models)
                if store.requestedSection == .models {
                    Section("Models") {
                        modelAreaButton(.downloaded, icon: "arrow.down.circle.fill")
                    }
                    Section("Discover") {
                        modelAreaButton(.trending, icon: "flame")
                        modelAreaButton(.mostDownloaded, icon: "arrow.down.circle")
                        modelAreaButton(.recentlyUpdated, icon: "clock.arrow.circlepath")
                    }
                    Section("Curated") {
                        modelAreaButton(.recommendedCoding, icon: "chevron.left.forwardslash.chevron.right")
                        modelAreaButton(.recommendedChat, icon: "bubble.left.and.bubble.right.fill")
                        modelAreaButton(.recommendedSystems, icon: "server.rack")
                        modelAreaButton(.recommendedHomeAutomation, icon: "house.and.flag.fill")
                        modelAreaButton(.recommendedAppleSilicon, icon: "apple.logo")
                    }
                    Section("Categories") {
                        modelAreaButton(.text, icon: "text.bubble")
                        modelAreaButton(.coding, icon: "chevron.left.forwardslash.chevron.right")
                        modelAreaButton(.multimodal, icon: "square.stack.3d.up")
                        modelAreaButton(.vision, icon: "eye")
                        modelAreaButton(.audio, icon: "waveform")
                        modelAreaButton(.languages, icon: "character.book.closed")
                    }
                }
            }
                .navigationTitle("InferenceBar")
                .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 240)
        } detail: {
            Group {
                switch store.requestedSection {
                case .profiles: ProfilesView()
                case .models: ModelsView(area: $modelArea)
                default: ProfilesView()
                }
            }.environment(store)
        }
        .alert("InferenceBar", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) { Button("OK") { store.errorMessage = nil } } message: { Text(store.errorMessage ?? "") }
    }

    private func modelAreaButton(_ area: ModelArea, icon: String) -> some View {
        Button { modelArea = area } label: { Label(area.rawValue, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading) }
            .buttonStyle(.plain).foregroundStyle(modelArea == area ? Color.accentColor : Color.primary)
    }
}

struct ProfilesView: View {
    @Environment(AppStore.self) private var store
    @State private var showsDeleteConfirm = false
    var body: some View {
        @Bindable var store = store
        HSplitView {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Profiles").font(.title2).fontWeight(.semibold)
                }.padding(12)
                Divider()
                List(store.profiles, selection: $store.selectedProfileID) { p in
                    HStack {
                        Circle().fill(profileColor(p.id)).frame(width: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name).lineLimit(1)
                            Text(p.runtime.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if store.isDefaultProfile(p.id) { Image(systemName: "checkmark.seal.fill").font(.caption).foregroundStyle(.blue).help("Default profile") }
                        if store.isFavorite(p.id) { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow) }
                        if store.runningProfileID == p.id && store.serverLifecycle != .running { ProgressView().controlSize(.mini) }
                    }
                }
                HStack {
                    Button(action: store.addProfile) { Image(systemName: "plus") }
                        .help("Add profile").accessibilityLabel("Add profile")
                    Menu {
                        Section("Downloaded model presets") {
                            ForEach(store.availablePresets) { preset in
                                Button { store.addPreset(preset) } label: { Text("\(preset.hardware) — \(preset.title)") }
                            }
                            if store.availablePresets.isEmpty { Text("Download a matching model to enable presets") }
                        }
                    } label: { Image(systemName: "sparkles") }
                        .help("Add a hardware preset; unified memory matters more than chip generation")
                        .accessibilityLabel("Add a hardware preset")
                    Button(action: store.duplicateProfile) { Image(systemName: "plus.square.on.square") }
                        .help("Duplicate profile").accessibilityLabel("Duplicate profile")
                    Button { showsDeleteConfirm = true } label: { Image(systemName: "trash") }
                        .help("Delete profile").accessibilityLabel("Delete profile")
                        .disabled(store.selectedProfile == nil)
                        .confirmationDialog(
                            "Delete “\(store.selectedProfile?.name ?? "this profile")”?",
                            isPresented: $showsDeleteConfirm,
                            titleVisibility: .visible
                        ) {
                            Button("Delete", role: .destructive) { store.deleteSelectedProfile() }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("This removes its configuration permanently. This can't be undone.")
                        }
                    Spacer()
                }.padding(8)
            }.frame(minWidth: 210, idealWidth: 250, maxWidth: 290)
            if let index = store.selectedProfileIndex { ProfileEditor(profile: $store.profiles[index]).frame(minWidth: 380) } else { ContentUnavailableView("Select a profile", systemImage: "slider.horizontal.3").frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity) }
        }
        .frame(minWidth: 760, minHeight: 560)
        .navigationTitle("Server profiles")
    }

    private func profileColor(_ id: UUID) -> Color {
        if store.failedProfileID == id { return .red }
        if store.runningProfileID == id { return store.serverLifecycle == .running ? .green : .orange }
        return .secondary
    }
}

struct ProfileEditor: View {
    @Environment(AppStore.self) private var store
    @Binding var profile: ServerProfile
    @State private var showsNetworkExposureConfirm = false
    private var expandedPath: String { NSString(string: profile.modelPath).expandingTildeInPath }
    private var modelExists: Bool {
        var isDirectory: ObjCBool = false
        return !profile.modelPath.isEmpty
            && FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && expandedPath.lowercased().hasSuffix(".gguf")
    }
    private var modelAvailable: Bool { profile.runtime.usesGGUF ? modelExists : store.isMLXModelCached(profile.modelPath) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.name).font(.title2).fontWeight(.semibold)
                    if store.failedProfileID == profile.id {
                        Label(store.serverLifecycle.label, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    } else if store.runningProfileID == profile.id {
                        Label(store.serverLifecycle.label, systemImage: store.serverLifecycle == .running ? "checkmark.circle.fill" : "clock.fill").foregroundStyle(store.serverLifecycle == .running ? .green : .orange)
                    } else {
                        Label(modelAvailable ? "Model downloaded" : "Model missing", systemImage: modelAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(modelAvailable ? .green : .orange)
                    }
                }
                Spacer()
                Button { store.setDefaultProfile(store.isDefaultProfile(profile.id) ? nil : profile.id) } label: {
                    Image(systemName: store.isDefaultProfile(profile.id) ? "checkmark.seal.fill" : "checkmark.seal")
                }
                    .buttonStyle(.bordered).tint(store.isDefaultProfile(profile.id) ? Color.blue : Color.secondary)
                    .help(store.isDefaultProfile(profile.id) ? "Remove as default profile" : "Set as default profile")
                    .accessibilityLabel(store.isDefaultProfile(profile.id) ? "Remove as default profile" : "Set as default profile")
                Button { store.toggleFavorite(profile.id) } label: { Image(systemName: store.isFavorite(profile.id) ? "star.fill" : "star") }
                    .buttonStyle(.bordered).tint(store.isFavorite(profile.id) ? Color.yellow : Color.secondary)
                    .help(store.isFavorite(profile.id) ? "Remove from menu-bar favorites" : "Add to menu-bar favorites")
                    .accessibilityLabel(store.isFavorite(profile.id) ? "Remove from menu-bar favorites" : "Add to menu-bar favorites")
                if profile.runtime.usesGGUF && !modelExists {
                    Button("Download model") { Task { await store.downloadMissingModel(for: profile.id) } }
                        .disabled(store.isDownloading || store.isResolvingDownload)
                }
                Button(store.runningProfileID == profile.id ? "Stop server" : "Start server") {
                    if store.runningProfileID == profile.id { store.stop() }
                    else if store.networkSettings.exposedWithoutAuthentication { showsNetworkExposureConfirm = true }
                    else { store.start() }
                }.buttonStyle(.borderedProminent).tint(store.runningProfileID == profile.id ? .red : .accentColor)
                .confirmationDialog("Start without authentication?", isPresented: $showsNetworkExposureConfirm, titleVisibility: .visible) {
                    Button("Start anyway", role: .destructive) { store.start() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Network access is enabled in Server Settings with no API key required. Anyone who can reach this Mac on the network will be able to use “\(profile.name)” once it starts.")
                }
            }.padding()
            if store.runningProfileID == profile.id {
                Label("Editing settings here won't change the running server — stop and start it again to apply them.", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
                    .padding(.horizontal).padding(.bottom, 8)
            }
            Divider()
            if (store.isDownloading || store.isResolvingDownload) && store.downloadOwnerProfileID == profile.id {
                VStack(alignment: .leading, spacing: 5) {
                    if store.isDownloading && store.downloadTotalBytes > 0 {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                ProgressView(value: store.downloadProgress, total: 1)
                                Text("\(store.downloadProgress.formatted(.percent.precision(.fractionLength(1)))) · \(store.downloadPhase) · \(ByteCountFormatter.string(fromByteCount: Int64(store.downloadBytesPerSecond), countStyle: .file))/s")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Button { store.toggleDownloadPause() } label: { Image(systemName: store.isDownloadPaused ? "play.fill" : "pause.fill") }.help(store.isDownloadPaused ? "Resume download" : "Pause download")
                        }
                    } else {
                        ProgressView()
                        Text(store.downloadStatus).font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal).padding(.top, 8)
            }
            Form {
            if let report = store.compatibilityReport, store.selectedProfileID == profile.id {
                Section("Compatibility preflight") {
                    Label(report.isCompatible ? "Compatible" : "Launch blocked", systemImage: report.isCompatible ? "checkmark.shield.fill" : "xmark.shield.fill")
                        .foregroundStyle(report.isCompatible ? .green : .red)
                    if let architecture = report.architecture { LabeledContent("Architecture", value: architecture) }
                    if let version = report.formatVersion { LabeledContent("GGUF version", value: String(version)) }
                    ForEach(report.errors, id: \.self) { Text($0).foregroundStyle(.red) }
                    ForEach(report.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
            }
            if store.runningProfileID == profile.id {
                Section("Runtime health") { RuntimeHealthPanel(health: store.runtimeHealth, lifecycle: store.serverLifecycle) }
            }
            Section("Identity") {
                TextField("Profile name", text: $profile.name)
                Picker("Runtime", selection: runtimeBinding) {
                    ForEach(compatibleRuntimes) { runtime in Text(runtime.title).tag(runtime) }
                }
                TextField("Server executable", text: $profile.executable)
                Picker("Downloaded model", selection: downloadedModelBinding) {
                    Text("Select a downloaded model…").tag(store.defaultModelPath)
                    ForEach(store.downloadedModelOptions(for: profile.runtime)) { model in
                        Text("\(model.name) · \(model.format.rawValue) · \(ByteCountFormatter.string(fromByteCount: model.size, countStyle: .file))").tag(model.path)
                    }
                }
                HStack {
                    TextField(profile.runtime.usesGGUF ? "Custom GGUF file path" : "Custom MLX model directory", text: $profile.modelPath)
                    Button("Browse…") { chooseModel() }
                }
                Text("Downloaded models come from the model directory configured in Settings. Browse to override it for this profile.").font(.caption).foregroundStyle(.secondary)
                if profile.runtime.usesGGUF && !modelExists { Text("Download this model in Models or choose an existing GGUF file.").font(.caption).foregroundStyle(.orange) }
                if !profile.runtime.usesGGUF { Text("Hugging Face IDs are downloaded and cached automatically by the MLX runtime.").font(.caption).foregroundStyle(.secondary) }
                TextField("Model alias", text: $profile.alias)
            }
            Section("Runtime") {
                LabeledContent("Maximum output tokens") {
                    TextField("", value: Binding(
                        get: { profile.effectiveMaximumOutputTokens },
                        set: { profile.maximumOutputTokens = min(max($0, 256), 65_536) }
                    ), format: .number).frame(width: 120)
                }
                Text("Increase this for long scripts and reports. Larger limits can take substantially longer to generate.").font(.caption).foregroundStyle(.secondary)
                if profile.runtime == .llamaCPP {
                    LabeledContent("Context size") { TextField("", value: $profile.contextSize, format: .number).frame(width: 120) }
                }
                LabeledContent("Parallel requests") { Stepper(value: $profile.parallel, in: 1...32) { Text("\(profile.parallel)") } }
                if profile.runtime == .llamaCPP {
                    Toggle("Flash attention", isOn: $profile.flashAttention); Toggle("Jinja templates", isOn: $profile.jinja)
                    LabeledContent("RAM cache (MiB)") { TextField("", value: $profile.cacheRAM, format: .number).frame(width: 120) }
                } else if profile.runtime == .mlxLM {
                    LabeledContent("Prompt cache entries") { TextField("", value: $profile.cacheRAM, format: .number).frame(width: 120) }
                } else {
                    LabeledContent("Cache memory (MiB)") { TextField("", value: $profile.cacheRAM, format: .number).frame(width: 120) }
                }
            }
            if profile.runtime == .llamaCPP { Section("Cache") {
                Toggle("Only used by InferenceBar", isOn: Binding(
                    get: { profile.exclusiveToInferenceBar ?? false },
                    set: { profile.exclusiveToInferenceBar = $0 }
                ))
                Text("Turn this on only if nothing else (such as OpenCode) ever talks to this server. It lets InferenceBar's own chat reuse the prompt cache across turns instead of erasing every slot before each message.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                LabeledContent("Cache reuse (tokens)") {
                    TextField("0", value: Binding(
                        get: { profile.cacheReuse ?? 0 },
                        set: { profile.cacheReuse = $0 > 0 ? $0 : nil }
                    ), format: .number).frame(width: 120)
                }
                Text("llama-server's --cache-reuse: reuses cached chunks even when the new prompt isn't an exact prefix match. 0 disables it.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Toggle("Full SWA cache (--swa-full)", isOn: Binding(
                    get: { profile.swaFull ?? false },
                    set: { profile.swaFull = $0 }
                ))
                Text("For sliding-window / hybrid models (for example Qwen 3.6) that still force full prompt reprocessing with caching otherwise enabled.")
                    .font(.caption).foregroundStyle(.secondary)
            } }
            if profile.runtime == .llamaCPP { Section("Reasoning") {
                TextField("Mode", text: $profile.reasoning); TextField("Format", text: $profile.reasoningFormat)
                LabeledContent("Budget") { TextField("", value: $profile.reasoningBudget, format: .number).frame(width: 120) }
                Toggle("Preserve reasoning", isOn: $profile.reasoningPreserve)
            } }
            Section("System prompt") {
                Toggle("Override the default system prompt for this profile", isOn: overridesSystemPromptBinding)
                if profile.systemPrompt != nil {
                    Divider()
                    TextEditor(text: Binding(get: { profile.systemPrompt ?? "" }, set: { profile.systemPrompt = $0 }))
                        .font(.body).frame(minHeight: 100, maxHeight: 220)
                        .padding(6).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    Text("Sent instead of Settings' default system prompt whenever this profile runs. Give it a persona, coding-specific instructions, or a language preference.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Uses the default system prompt from Settings.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Advanced") { TextField("Extra arguments", text: $profile.extraArguments) }
            }
            .formStyle(.grouped).padding().navigationTitle(profile.name)
        }
    }

    private var runtimeBinding: Binding<InferenceBackend> {
        Binding(get: { profile.runtime }, set: { newRuntime in
            let oldDefault = profile.runtime.defaultExecutable
            profile.backend = newRuntime
            if profile.executable.isEmpty || profile.executable == oldDefault { profile.executable = newRuntime.defaultExecutable }
            if newRuntime == .mlxLM {
                profile.alias = "default_model"
                profile.cacheRAM = 10
                if profile.modelPath.lowercased().hasSuffix(".gguf") {
                    profile.modelPath = profile.modelPath.localizedCaseInsensitiveContains("qwen3.6") ? "mlx-community/Qwen3.6-35B-A3B-4bit" : ""
                }
            } else if newRuntime == .vllmMLX {
                profile.alias = "default"
                profile.cacheRAM = 0
                if profile.modelPath.lowercased().hasSuffix(".gguf") {
                    profile.modelPath = profile.modelPath.localizedCaseInsensitiveContains("qwen3.6") ? "mlx-community/Qwen3.6-35B-A3B-4bit" : ""
                }
            }
            if !store.downloadedModelOptions(for: newRuntime).contains(where: { $0.path == profile.modelPath }) {
                profile.modelPath = store.defaultModelPath
            }
        })
    }

    private var overridesSystemPromptBinding: Binding<Bool> {
        Binding(get: { profile.systemPrompt != nil }, set: { on in
            profile.systemPrompt = on ? (profile.systemPrompt ?? "") : nil
        })
    }

    private var downloadedModelBinding: Binding<String> {
        Binding(get: {
            let expanded = NSString(string: profile.modelPath).expandingTildeInPath
            return store.downloadedModelOptions(for: profile.runtime).first(where: {
                URL(fileURLWithPath: $0.path).standardizedFileURL.path == URL(fileURLWithPath: expanded).standardizedFileURL.path
            })?.path ?? store.defaultModelPath
        }, set: { selected in
            profile.modelPath = selected
            if selected != store.defaultModelPath {
                let name = URL(fileURLWithPath: selected).deletingPathExtension().lastPathComponent
                profile.alias = name.lowercased().replacingOccurrences(of: " ", with: "-")
            }
        })
    }

    private var compatibleRuntimes: [InferenceBackend] {
        let path = profile.modelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if path == store.defaultModelPath { return InferenceBackend.allCases }
        if path.lowercased().hasSuffix(".gguf") { return [.llamaCPP] }
        if !path.isEmpty { return [.mlxLM, .vllmMLX] }
        return InferenceBackend.allCases
    }

    private func chooseModel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = profile.runtime.usesGGUF ? [.init(filenameExtension: "gguf")!] : []
        panel.canChooseDirectories = !profile.runtime.usesGGUF
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { profile.modelPath = url.path }
    }
}

/// Shared color coding for ContextUsageLevel across the Runtime Health
/// panel and the Chat window's own context indicator, so a user sees the
/// same "getting full" signal wherever they look.
private func contextUsageTint(_ level: ContextUsageLevel) -> Color {
    switch level {
    case .normal: return .secondary
    case .elevated: return .orange
    case .critical: return .red
    }
}

private struct RuntimeHealthPanel: View {
    let health: RuntimeHealth
    let lifecycle: ServerLifecycle
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 10) {
            GridRow {
                metric("Process ID", health.pid.map(String.init) ?? "—", "number")
                metric("Memory", health.memoryBytes > 0 ? ByteCountFormatter.string(fromByteCount: health.memoryBytes, countStyle: .memory) : "Measuring…", "memorychip")
                metric("Uptime", Duration.seconds(health.uptime).formatted(.time(pattern: .hourMinuteSecond)), "clock")
            }
            GridRow {
                metric("Requests", String(health.activeRequests), "arrow.trianglehead.2.clockwise.rotate.90")
                metric("Generation", health.tokensPerSecond.map { String(format: "%.1f tok/s", $0) } ?? "Waiting…", "gauge.with.dots.needle.67percent")
                metric("Context", health.contextLimit > 0 ? "\(health.contextTokens.formatted()) / \(health.contextLimit.formatted())" : "Unavailable", "text.alignleft")
            }
        }
        if health.contextLimit > 0 { ProgressView(value: health.contextFraction).tint(contextUsageTint(health.contextUsageLevel)).help("Current context usage") }
        if lifecycle != .running {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: health.loadingProgress ?? 0)
                Text(health.loadingProgress.map { "Model loading: \($0.formatted(.percent.precision(.fractionLength(0))))" } ?? lifecycle.label).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func metric(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.body.monospacedDigit()).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A button showing the current global shortcut that, when clicked, records
/// the next key combination the user presses (requiring at least one
/// modifier, so an accidental bare keystroke can never become the new
/// shortcut) and writes it back into the two bindings. Escape with no
/// modifiers cancels without changing anything.
private struct HotkeyRecorderField: View {
    @Binding var keyCode: UInt16
    @Binding var modifierFlags: NSEvent.ModifierFlags
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            isRecording ? stopRecording() : startRecording()
        } label: {
            Text(isRecording ? "Press a key combination…" : GlobalHotkey.displayString(keyCode: keyCode, modifierFlags: modifierFlags))
                .foregroundStyle(isRecording ? .secondary : .primary)
                .frame(minWidth: 140)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(isRecording ? 0.12 : 0.07)))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(isRecording ? Color.accentColor : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .help(isRecording ? "Press Escape to cancel" : "Click, then press the new shortcut")
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        isRecording = true
        // NSEvent's monitor handler is a plain synchronous closure that
        // AppKit may treat as running outside this view's own isolation,
        // the same reason InferenceBarDelegate's hotkey monitors hop back
        // to the main actor before touching any state — so the match
        // check here (pure, only touches the event parameter and
        // GlobalHotkey's static helpers) stays inline, and every actual
        // state mutation is deferred through Task { @MainActor in ... }.
        // Every path returns nil so no keystroke leaks through to
        // whatever's behind this button while recording.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(GlobalHotkey.recordableModifiers)
            if event.keyCode == 53, flags.isEmpty {
                // Escape with no modifiers cancels rather than recording
                // "Escape" itself as the new shortcut.
                Task { @MainActor in stopRecording() }
                return nil
            }
            guard !flags.isEmpty else { return nil } // require at least one modifier
            let newKeyCode = event.keyCode
            Task { @MainActor in
                keyCode = newKeyCode
                modifierFlags = flags
                stopRecording()
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }
}

struct GlobalServerSettingsView: View {
    @Environment(AppStore.self) private var store
    @AppStorage("modelDirectory") private var modelDirectory = "~/ai-models"
    @State private var brewURL: URL?
    @State private var installedDependencies: Set<String> = []
    @State private var installingDependencies: Set<String> = []
    @State private var installationOutput = ""
    @State private var isTestingWebSearch = false
    @State private var webSearchTestResult: String?
    @State private var webSearchTestFailed = false
    @State private var cliInstallResult: String?
    @State private var cliInstallFailed = false

    var body: some View {
        @Bindable var store = store
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Settings").font(.largeTitle).fontWeight(.semibold)
                settingsCard {
                    Label("Startup model", systemImage: "bolt.circle").font(.headline)
                    Picker("Default profile", selection: Binding(get: { store.defaultProfileID }, set: { store.setDefaultProfile($0) })) {
                        Text("No default profile").tag(nil as UUID?)
                        ForEach(store.profiles) { profile in Text(profile.name).tag(profile.id as UUID?) }
                    }
                    Divider()
                    settingToggle(icon: "play.circle", title: "Start default profile when InferenceBar opens", detail: "The selected model and inference runtime will launch automatically at application startup.", value: $store.autoStartDefaultProfile)
                        .disabled(store.defaultProfileID == nil)
                    if store.defaultProfileID == nil {
                        Text("Choose a default profile to enable automatic startup.").font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    settingToggle(icon: "arrow.clockwise.circle", title: "Restart automatically if the server crashes", detail: "Retries with backoff (up to 5 attempts) after the process exits unexpectedly. Never retries a deliberate stop, a missing executable, or a compatibility failure.", value: $store.autoRestartOnCrash)
                }
                settingsCard {
                    settingToggle(icon: "keyboard", title: "Global keyboard shortcut", detail: "Shows or hides the Chat window from anywhere, even when another app is focused.", value: $store.globalHotkeyEnabled)
                    if store.globalHotkeyEnabled {
                        Divider()
                        HStack {
                            Text("Shortcut").fontWeight(.medium)
                            Spacer()
                            HotkeyRecorderField(keyCode: $store.hotkeyKeyCode, modifierFlags: $store.hotkeyModifierFlags)
                            if store.hotkeyKeyCode != GlobalHotkey.defaultKeyCode || store.hotkeyModifierFlags != GlobalHotkey.defaultModifierFlags {
                                Button("Reset") {
                                    store.hotkeyKeyCode = GlobalHotkey.defaultKeyCode
                                    store.hotkeyModifierFlags = GlobalHotkey.defaultModifierFlags
                                }.buttonStyle(.link)
                            }
                        }
                        Divider()
                        Text("If it doesn't respond while another app is focused, grant InferenceBar Accessibility access in System Settings → Privacy & Security → Accessibility.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                settingsCard {
                    Label("Default system prompt", systemImage: "text.bubble").font(.headline)
                    Text("Sent with every message in InferenceBar's own chat, unless a profile sets its own in its editor.")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    TextEditor(text: $store.defaultSystemPrompt)
                        .font(.body).frame(minHeight: 90, maxHeight: 160)
                        .padding(6).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    HStack {
                        Spacer()
                        Button("Reset to default") { store.defaultSystemPrompt = AppStore.defaultSystemPromptText }
                            .disabled(store.defaultSystemPrompt == AppStore.defaultSystemPromptText)
                    }
                }
                settingsCard {
                    settingToggle(icon: "magnifyingglass", title: "Let the assistant search the web", detail: "InferenceBar's own Chat window can search the web via a SearXNG instance you provide, when the model decides a question needs it.", value: $store.webSearchEnabled)
                    if store.webSearchEnabled {
                        Divider()
                        TextField("SearXNG URL", text: $store.webSearchSearXNGURL, prompt: Text("https://searxng.example.com"))
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            if let webSearchTestResult {
                                Label(webSearchTestResult, systemImage: webSearchTestFailed ? "xmark.circle.fill" : "checkmark.circle.fill")
                                    .font(.caption).foregroundStyle(webSearchTestFailed ? .red : .green).lineLimit(2)
                            }
                            Spacer()
                            if isTestingWebSearch { ProgressView().controlSize(.small) }
                            Button("Test") { Task { await testWebSearch() } }
                                .disabled(isTestingWebSearch || WebSearch.normalizedBaseURL(store.webSearchSearXNGURL) == nil)
                        }
                        Divider()
                        Text("Needs a SearXNG instance with JSON responses enabled (add `json` to `formats` in its settings.yml — otherwise it returns 403 Forbidden). Only the search queries the model chooses to run are sent to this address.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                settingsCard {
                    settingToggle(icon: "doc.text.magnifyingglass", title: "Let the assistant fetch web pages", detail: "InferenceBar's own Chat window can read the text of a specific URL — a search result, or a link you paste in — when the model decides it needs to.", value: $store.fetchURLEnabled)
                    if store.fetchURLEnabled {
                        Divider()
                        Text("The model chooses which URLs to fetch. Only pages it requests are contacted, and only their text is sent back to it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                settingsCard {
                    settingToggle(icon: "arrow.triangle.2.circlepath", title: "Check for updates", detail: "Check GitHub tags when InferenceBar starts and once every hour while it is running.", value: $store.updateChecksEnabled)
                    if store.updateChecksEnabled {
                        Divider()
                        HStack {
                            if let tag = store.availableUpdateTag {
                                // Points at the specific release, not just the generic tag
                                // list, so this is a click straight to the download/notes
                                // instead of one more page to search from.
                                Link("Update \(tag) is available", destination: URL(string: "https://github.com/kladhest-se/inferencebar/releases/tag/\(tag)")!)
                                    .fontWeight(.semibold)
                            } else if let error = store.updateCheckError {
                                Text("Last check failed: \(error)").font(.caption).foregroundStyle(.orange).lineLimit(2)
                            } else if let date = store.lastUpdateCheck {
                                Text("Up to date · checked \(date.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                            } else { Text("Not checked yet").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            if store.isCheckingForUpdates { ProgressView().controlSize(.small) }
                            Button("Check now") { Task { await store.checkForUpdates() } }.disabled(store.isCheckingForUpdates)
                        }
                    }
                }
                settingsCard {
                    Label("Runtime dependencies", systemImage: "shippingbox.and.arrow.backward").font(.headline)
                    if brewURL == nil {
                        Label("Homebrew is not installed", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).fontWeight(.semibold)
                        Text("Homebrew is required to install and update the local inference runtimes. Install it from the official Homebrew website, then return here and check again.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Link("Open brew.sh", destination: URL(string: "https://brew.sh")!)
                            Button("Check again") { refreshDependencies() }
                        }
                    } else {
                        ForEach(BrewDependency.required) { dependency in
                            Divider()
                            HStack(spacing: 12) {
                                Image(systemName: installedDependencies.contains(dependency.id) ? "checkmark.circle.fill" : "circle.dashed")
                                    .foregroundStyle(installedDependencies.contains(dependency.id) ? .green : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(dependency.title).fontWeight(.medium)
                                    Text(dependency.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if installingDependencies.contains(dependency.id) { ProgressView().controlSize(.small) }
                                Button(installedDependencies.contains(dependency.id) ? "Reinstall…" : "Install…") { install(dependency) }
                                    .disabled(!installingDependencies.isEmpty)
                            }
                        }
                        HStack {
                            Label("Homebrew found", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                            Spacer()
                            Button("Refresh") { refreshDependencies() }
                        }.font(.caption)
                    }
                    if !installationOutput.isEmpty {
                        Text(installationOutput).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(8)
                    }
                }
                settingsCard {
                    Label("App theme", systemImage: "paintpalette").font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 10) {
                        ForEach(AppTheme.allCases) { theme in themeButton(theme) }
                    }
                    Divider()
                    Label("Menu bar icon", systemImage: "menubar.rectangle").font(.headline)
                    HStack(spacing: 10) { ForEach(MenuBarIconStyle.allCases) { style in menuIconButton(style) } }
                    Text("Match System follows the menu bar appearance. Colour uses the selected theme accent. Monochrome keeps the icon white.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                settingsCard {
                    settingToggle(icon: "wifi", title: "Expose InferenceBar to the network", detail: "Allow other devices and OpenAI-compatible clients to connect.", value: $store.networkSettings.networkEnabled)
                    Divider()
                    HStack { Label("Listen address", systemImage: "network"); Spacer(); TextField("0.0.0.0", text: $store.networkSettings.listenAddress).frame(width: 180).disabled(!store.networkSettings.networkEnabled) }
                    Divider()
                    HStack { Label("Port", systemImage: "number"); Spacer(); TextField("8080", text: portBinding).frame(width: 100).monospacedDigit() }
                    Divider()
                    LabeledContent("Effective endpoint") {
                        Text(verbatim: EndpointFormatter.endpoint(address: store.networkSettings.effectiveListenAddress, port: store.networkSettings.port, scheme: store.networkSettings.tlsConfigured ? "https" : "http"))
                            .textSelection(.enabled).foregroundStyle(.secondary).monospacedDigit()
                    }
                    if store.networkSettings.networkEnabled { Label("Use authentication on untrusted networks.", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange) }
                }
                settingsCard {
                    settingToggle(icon: "key", title: "Require API-key authentication", detail: "The built-in chat sends this key as a Bearer token.", value: $store.networkSettings.authenticationEnabled)
                    if store.networkSettings.authenticationEnabled {
                        Divider(); SecureField("API key", text: $store.networkSettings.apiKey)
                        if store.networkSettings.apiKey.isEmpty { Text("Enter an API key before starting the server.").font(.caption).foregroundStyle(.orange) }
                        Text("Stored in the login keychain, not in a plain settings file.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                settingsCard {
                    Label("TLS (llama.cpp only)", systemImage: "lock.shield").font(.headline)
                    Text("Encrypts traffic to a llama.cpp profile, including the API key above. Requires an llama-server build with OpenSSL support (LLAMA_OPENSSL) — most Homebrew builds do not have this enabled. Has no effect on MLX or vLLM-MLX profiles.")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    HStack { Label("Certificate file", systemImage: "doc.text"); Spacer(); TextField("~/path/to/cert.pem", text: $store.networkSettings.sslCertPath).frame(width: 220) }
                    Divider()
                    HStack { Label("Private key file", systemImage: "key.horizontal"); Spacer(); TextField("~/path/to/key.pem", text: $store.networkSettings.sslKeyPath).frame(width: 220) }
                    if store.networkSettings.tlsConfigured { Label("TLS enabled for llama.cpp profiles.", systemImage: "checkmark.shield.fill").font(.caption).foregroundStyle(.green) }
                }
                settingsCard {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "folder").frame(width: 24)
                        VStack(alignment: .leading, spacing: 4) { Text("Model location").fontWeight(.medium); Text("Downloaded GGUF and MLX models are stored and discovered here.").font(.caption).foregroundStyle(.secondary); TextField("Model directory", text: $modelDirectory) }
                        Button("Browse…") { chooseModelDirectory() }
                    }
                }
                settingsCard {
                    Label("Command-line tool", systemImage: "terminal").font(.headline)
                    Text("Installs a small `inferencebar` command you can run from Terminal — `inferencebar ask \"...\"` sends a one-off prompt to whatever profile is currently running and prints the answer, so you can script against your local model without opening the Chat window.")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    HStack {
                        if let cliInstallResult {
                            Label(cliInstallResult, systemImage: cliInstallFailed ? "xmark.circle.fill" : "checkmark.circle.fill")
                                .font(.caption).foregroundStyle(cliInstallFailed ? .red : .green).lineLimit(3)
                        }
                        Spacer()
                        Button("Install") { installCLITool() }
                    }
                }
            }.padding(28).frame(maxWidth: 900)
        }
        .navigationTitle("Server Settings")
        .task { refreshDependencies() }
    }

    private var portBinding: Binding<String> {
        Binding(get: { String(store.networkSettings.port) }, set: { value in
            let digits = value.filter(\.isNumber)
            if let port = Int(digits.prefix(5)), (1...65535).contains(port) { store.networkSettings.port = port }
        })
    }

    private func themeButton(_ theme: AppTheme) -> some View {
        Button { store.appTheme = theme } label: {
            VStack(alignment: .leading, spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7).fill(theme.previewBackground)
                    VStack(spacing: 4) {
                        HStack { Circle().fill(theme.accent).frame(width: 7); RoundedRectangle(cornerRadius: 2).fill(theme.previewForeground.opacity(0.7)).frame(height: 5) }
                        HStack { RoundedRectangle(cornerRadius: 3).fill(theme.previewSurface).frame(width: 28); RoundedRectangle(cornerRadius: 3).fill(theme.previewSurface).frame(height: 25) }
                    }.padding(8)
                }.frame(height: 55).overlay(RoundedRectangle(cornerRadius: 7).stroke(store.appTheme == theme ? theme.accent : .secondary.opacity(0.25), lineWidth: store.appTheme == theme ? 2 : 1))
                HStack { Text(theme.rawValue).font(.caption).lineLimit(1); Spacer(); if store.appTheme == theme { Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.accent) } }
            }
        }.buttonStyle(.plain)
    }

    private func menuIconButton(_ style: MenuBarIconStyle) -> some View {
        Button { store.menuBarIconStyle = style } label: {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7).fill(style == .matchSystem ? Color.primary.opacity(0.1) : (style == .colour ? store.appTheme.accent.opacity(0.18) : Color.black))
                    Image(systemName: "bubble.left.fill").font(.title2).foregroundStyle(style == .colour ? store.appTheme.accent : (style == .monochrome ? .white : .primary))
                    Image(systemName: "bolt.fill").font(.caption).foregroundStyle(style == .colour ? .white : (style == .monochrome ? .black : store.appTheme.background))
                }.frame(height: 45).overlay(RoundedRectangle(cornerRadius: 7).stroke(store.menuBarIconStyle == style ? store.appTheme.accent : .clear, lineWidth: 2))
                Text(style.rawValue).font(.caption)
            }.frame(maxWidth: .infinity)
        }.buttonStyle(.plain)
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14, content: content).padding(18).background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
    }

    private func settingToggle(icon: String, title: String, detail: String, value: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).frame(width: 24)
            VStack(alignment: .leading, spacing: 4) { Text(title).fontWeight(.medium); Text(detail).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            // labelsHidden() drops the empty title from view, but also from
            // the accessibility tree — without this, VoiceOver (and any
            // test driving this toggle by name) sees a control with no name
            // at all, next to a title Text it's never actually connected to.
            Toggle("", isOn: value).labelsHidden().accessibilityLabel(title)
        }
    }

    private func chooseModelDirectory() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { modelDirectory = url.path }
    }

    private func refreshDependencies() {
        brewURL = HomebrewRuntimeManager.brewURL()
        installedDependencies = Set(BrewDependency.required.filter { HomebrewRuntimeManager.isInstalled($0) }.map(\.id))
    }

    private func testWebSearch() async {
        isTestingWebSearch = true
        webSearchTestResult = nil
        defer { isTestingWebSearch = false }
        switch await WebSearch.search(query: "InferenceBar connectivity test", baseURLString: store.webSearchSearXNGURL) {
        case .success(let results):
            webSearchTestFailed = false
            webSearchTestResult = results.isEmpty ? "Reached the server, but it returned zero results." : "Reached the server — got \(results.count) result(s)."
        case .failure(let reason):
            webSearchTestFailed = true
            webSearchTestResult = reason.isEmpty ? reason : reason.prefix(1).uppercased() + String(reason.dropFirst())
        }
    }

    private func installCLITool() {
        switch store.installCLITool() {
        case .installed(let path, let onPATH):
            cliInstallFailed = false
            cliInstallResult = onPATH
                ? "Installed to \(path). Open a new Terminal window and run `inferencebar ask \"...\"`."
                : "Installed to \(path), but that folder isn't on your PATH — run it with the full path, or add \(path) to your shell's PATH."
        case .bundledBinaryMissing:
            cliInstallFailed = true
            cliInstallResult = "This build of InferenceBar doesn't include the command-line tool."
        case .failed(let reason):
            cliInstallFailed = true
            cliInstallResult = "Couldn't install the command-line tool: \(reason)"
        }
    }

    private func install(_ dependency: BrewDependency) {
        guard let brewURL else { refreshDependencies(); return }
        installingDependencies.insert(dependency.id)
        installationOutput = "Installing \(dependency.title) with Homebrew…"
        Task {
            let result = await HomebrewRuntimeManager.install(dependency, using: brewURL)
            installingDependencies.remove(dependency.id)
            installationOutput = result.output
            refreshDependencies()
            if !result.succeeded { store.errorMessage = "Homebrew could not install \(dependency.title).\n\n\(result.output)" }
        }
    }
}

struct ModelStoreWindowView: View {
    @Environment(AppStore.self) private var store
    @State private var area: ModelArea = .recommendedChat

    var body: some View {
        NavigationSplitView {
            List {
                Section("Models") {
                    areaButton(.downloaded, icon: "arrow.down.circle.fill")
                }
                Section("Discover") {
                    areaButton(.trending, icon: "flame")
                    areaButton(.mostDownloaded, icon: "arrow.down.circle")
                    areaButton(.recentlyUpdated, icon: "clock.arrow.circlepath")
                }
                Section("Curated") {
                    areaButton(.recommendedCoding, icon: "chevron.left.forwardslash.chevron.right")
                    areaButton(.recommendedChat, icon: "bubble.left.and.bubble.right.fill")
                    areaButton(.recommendedSystems, icon: "server.rack")
                    areaButton(.recommendedHomeAutomation, icon: "house.and.flag.fill")
                    areaButton(.recommendedAppleSilicon, icon: "apple.logo")
                }
                Section("Categories") {
                    areaButton(.text, icon: "text.bubble")
                    areaButton(.coding, icon: "chevron.left.forwardslash.chevron.right")
                    areaButton(.multimodal, icon: "square.stack.3d.up")
                    areaButton(.vision, icon: "eye")
                    areaButton(.audio, icon: "waveform")
                    areaButton(.languages, icon: "character.book.closed")
                }
            }.navigationTitle("Model Store").navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 250)
        } detail: {
            ModelsView(area: $area).environment(store)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .alert("InferenceBar", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }

    private func areaButton(_ value: ModelArea, icon: String) -> some View {
        Button { area = value } label: { Label(value.rawValue, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading) }
            .buttonStyle(.plain).foregroundStyle(area == value ? Color.accentColor : Color.primary)
    }
}

struct ModelsView: View {
    @Environment(AppStore.self) private var store
    @AppStorage("modelDirectory") private var directory = "~/ai-models"
    @Binding var area: ModelArea
    @State private var category: ModelCategory = .recommendedChat
    @State private var localGGUFPaths: [String: String] = [:]
    @State private var installedRuntimeExecutables: Set<String> = []
    @AppStorage("showUnsupportedModelFormats") private var showUnsupportedFormats = false
    private var hardware: MacHardwareProfile { .current(modelDirectory: directory) }

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            if area == .downloaded {
                    DownloadedModelsView(ggufDirectory: directory).frame(minWidth: 620)
                } else {
                VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(area.rawValue).font(.title2).fontWeight(.semibold)
                Spacer()
                Toggle("Show unsupported formats", isOn: $showUnsupportedFormats)
                    .toggleStyle(.checkbox).font(.caption)
            }.padding(.horizontal).padding(.vertical, 12)
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search models", text: $store.searchQuery).textFieldStyle(.plain).font(.title3).onSubmit { Task { await searchAllFormats() } }
                if !store.searchQuery.isEmpty { Button { store.searchQuery = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear search") }
                Button(store.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty ? "Refresh" : "Search") { Task { await searchAllFormats() } }.buttonStyle(.borderedProminent).disabled(store.isSearching)
                if store.isSearching { ProgressView().controlSize(.small) }
            }.padding(12).background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal).padding(.bottom, area.categories.count > 1 ? 8 : 12)
            if area.categories.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(area.categories) { option in
                            Button {
                                category = option
                            } label: {
                                Label(option.title, systemImage: option.icon)
                                    .font(.subheadline.weight(category == option ? .semibold : .regular))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .foregroundStyle(category == option ? Color.white : Color.primary)
                                    .background(category == option ? store.appTheme.accent : Color.primary.opacity(0.06), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(category == option ? .isSelected : [])
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.bottom, 12)
            }
            HSplitView {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(visibleResults) { model in
                            let modelBackend = backend(for: model)
                            ModelCard(model: model, backend: modelBackend, isRuntimeSupported: runtimeSupports(modelBackend), isSelected: store.selectedModel == model, isDownloaded: isModelDownloaded(model), versionCounts: store.modelVersionCounts(for: model, backend: modelBackend)) {
                                store.modelCatalogBackend = backend(for: model)
                                store.selectedModel = model
                                if let path = localGGUFPaths[model.id] {
                                    let file = URL(fileURLWithPath: path).lastPathComponent
                                    store.modelFiles = [file]
                                    store.modelFileSizes = [file: model.usedStorage ?? 0]
                                } else {
                                    Task { await store.loadFiles(for: model) }
                                }
                            }
                        }
                        if visibleResults.isEmpty && !store.isSearching {
                            ContentUnavailableView("No compatible models", systemImage: "shippingbox", description: Text("Try another category or search term."))
                        }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id("\(area.rawValue)-\(category.id)")
                .frame(width: 500, alignment: .leading)
                VStack(alignment: .leading, spacing: 12) {
                    if let model = store.selectedModel {
                        Text(model.id.split(separator: "/").last.map(String.init) ?? model.id).font(.title2).fontWeight(.semibold)
                        Text("by \(model.id.split(separator: "/").first.map(String.init) ?? "Hugging Face")").foregroundStyle(.secondary)
                        Label(isModelDownloaded(model) ? "Available on this Mac" : "Not downloaded", systemImage: isModelDownloaded(model) ? "checkmark.circle.fill" : "icloud.and.arrow.down")
                            .font(.subheadline).foregroundStyle(isModelDownloaded(model) ? .green : .secondary)
                    } else {
                        ContentUnavailableView("Select a model", systemImage: "cube.transparent", description: Text("Choose a model to see its details and available downloads."))
                    }
                    LabeledContent("Download folder") { TextField("", text: $directory).frame(minWidth: 280) }
                    if store.isLoadingFiles { ProgressView("Loading files…") }
                    let currentHardware = hardware
                    HStack(spacing: 14) {
                        Label(currentHardware.chip, systemImage: "cpu")
                        Label(byteString(currentHardware.physicalMemory) + " unified memory", systemImage: "memorychip")
                        Label(byteString(currentHardware.availableDisk) + " available", systemImage: "internaldrive")
                    }.font(.caption).foregroundStyle(.secondary)
                    List {
                        Section {
                        ForEach(store.modelFiles, id: \.self) { file in
                        let size = store.modelFileSizes[file] ?? 0
                        let isGGUF = store.modelCatalogBackend == .llamaCPP
                        let onDisk = isGGUF ? ggufFileExists(file) : (store.selectedModel.map(isModelDownloaded) ?? false)
                        let assessment = ModelHardwareAdvisor.assess(fileSize: size, filename: file, contextSize: 32_768, hardware: currentHardware, alreadyDownloaded: onDisk)
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(file).lineLimit(1)
                                Text(size > 0 ? "\(byteString(size)) · ~\(byteString(assessment.requiredMemory)) memory including ~\(byteString(assessment.kvCache)) KV cache at 32K context" : "Size metadata unavailable")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(assessment.fit.rawValue).modelFitBadge(assessment.fit).help(assessment.reason).fixedSize()
                            if onDisk { Label("On disk", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                            else if let model = store.selectedModel, let job = store.downloadJob(modelID: model.id, file: isGGUF ? file : nil) {
                                ProgressView(value: job.progress).frame(width: 80)
                                Button { store.toggleDownloadPause(job.id) } label: { Image(systemName: job.isPaused ? "play.fill" : "pause.fill") }
                                    .help(job.isPaused ? "Resume download" : "Pause download")
                                    .accessibilityLabel(job.isPaused ? "Resume download" : "Pause download")
                                Button { store.cancelDownload(job.id) } label: { Image(systemName: "xmark") }
                                    .help("Cancel download").accessibilityLabel("Cancel download")
                            } else {
                                Button("Download") {
                                    if let model = store.selectedModel {
                                        if isGGUF { Task { await store.download(file: file, from: model, to: directory) } }
                                        else { Task { await store.downloadMLXModel(model.id) } }
                                    }
                                }.disabled(assessment.fit == .unsupported || size <= 0)
                            }
                        }
                        }
                        } header: {
                            HStack {
                                Text("Version")
                                Spacer()
                                Text("Compatibility").frame(width: 96, alignment: .leading)
                                Text("Action").frame(width: 92, alignment: .trailing)
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(nil)
                        }
                    }
                    if let selected = store.selectedModel, let job = store.downloadJob(modelID: selected.id) {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: job.progress, total: 1)
                            HStack {
                                Text("\(job.progress.formatted(.percent.precision(.fractionLength(1))))")
                                Text("\(byteString(job.received)) / \(job.total > 0 ? byteString(job.total) : "Unknown size")")
                                Spacer()
                                if job.speed > 0 { Text("\(byteString(Int64(job.speed)))/s") }
                                Button { store.toggleDownloadPause(job.id) } label: { Image(systemName: job.isPaused ? "play.fill" : "pause.fill") }.buttonStyle(.borderless)
                                    .help(job.isPaused ? "Resume download" : "Pause download")
                                    .accessibilityLabel(job.isPaused ? "Resume download" : "Pause download")
                            }.font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    if let selected = store.selectedModel, store.downloadJob(modelID: selected.id) != nil, !store.downloadStatus.isEmpty { Text(store.downloadStatus).font(.caption).textSelection(.enabled) }
                }.padding().frame(minWidth: 320, idealWidth: 440, maxHeight: .infinity, alignment: .topLeading)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Model Store")
        .task(id: category.id) {
            guard area != .downloaded else { return }
            installedRuntimeExecutables = RuntimeAvailability.installedExecutables()
            store.searchQuery = ""
            await searchAllFormats()
        }
        .onChange(of: showUnsupportedFormats) { _, _ in Task { await searchAllFormats() } }
        .onChange(of: area) { _, newArea in
            if let first = newArea.categories.first { category = first }
        }
    }

    private func byteString(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    private func recommendedRAM(_ fileSize: Int64) -> String {
        let estimate = max(Int64(Double(fileSize) * 1.25), fileSize + 2_000_000_000)
        return ByteCountFormatter.string(fromByteCount: estimate, countStyle: .memory)
    }

    private var visibleResults: [HFModel] {
        showUnsupportedFormats ? store.searchResults : store.searchResults.filter { runtimeSupports(backend(for: $0)) }
    }

    private func backend(for model: HFModel) -> InferenceBackend {
        if model.id.hasPrefix("mlx-community/") || model.tags?.contains(where: { $0.lowercased() == "mlx" }) == true { return .mlxLM }
        return .llamaCPP
    }

    private func searchAllFormats() async {
        installedRuntimeExecutables = RuntimeAvailability.installedExecutables()
        store.selectedModel = nil
        store.modelFiles = []
        var gguf: [HFModel] = []
        var mlx: [HFModel] = []
        if showUnsupportedFormats || runtimeSupports(.llamaCPP) {
            store.modelCatalogBackend = .llamaCPP
            await store.search(category: category)
            gguf = store.searchResults
        }
        if showUnsupportedFormats || runtimeSupports(.mlxLM) {
            store.modelCatalogBackend = .mlxLM
            await store.search(category: category)
            mlx = store.searchResults
        }
        var unique: [String: HFModel] = [:]
        for model in gguf + mlx { unique[model.id] = model }
        localGGUFPaths = [:]
        for (model, path) in matchingLocalGGUFModels() {
            unique[model.id] = model
            localGGUFPaths[model.id] = path
        }
        store.searchResults = unique.values.sorted {
            let lhsLocal = localGGUFPaths[$0.id] != nil
            let rhsLocal = localGGUFPaths[$1.id] != nil
            if lhsLocal != rhsLocal { return lhsLocal }
            return ($0.downloads ?? 0) > ($1.downloads ?? 0)
        }
    }

    private func runtimeSupports(_ backend: InferenceBackend) -> Bool {
        if backend == .mlxLM {
            return RuntimeAvailability.supports(.mlxLM, installedExecutables: installedRuntimeExecutables)
                || RuntimeAvailability.supports(.vllmMLX, installedExecutables: installedRuntimeExecutables)
        }
        return RuntimeAvailability.supports(backend, installedExecutables: installedRuntimeExecutables)
    }

    private func matchingLocalGGUFModels() -> [(HFModel, String)] {
        let query = normalizedModelSearch(store.searchQuery)
        guard !query.isEmpty else { return [] }
        let root = NSString(string: directory).expandingTildeInPath
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: root) else { return [] }
        var matches: [(HFModel, String)] = []
        for case let relative as String in enumerator where relative.lowercased().hasSuffix(".gguf") {
            let filename = URL(fileURLWithPath: relative).lastPathComponent
            guard normalizedModelSearch(filename).contains(query) else { continue }
            let path = (root as NSString).appendingPathComponent(relative)
            let size = (try? fm.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
            let id = "Local/\(filename)"
            matches.append((HFModel(id: id, downloads: nil, likes: nil, lastModified: nil, pipeline_tag: nil, tags: ["local", "gguf"], usedStorage: size), path))
        }
        return matches
    }

    private func normalizedModelSearch(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: ".gguf", with: "")
    }

    private func isModelDownloaded(_ model: HFModel) -> Bool {
        let fm = FileManager.default
        if let path = localGGUFPaths[model.id] { return fm.fileExists(atPath: path) }
        if backend(for: model) == .mlxLM {
            if store.isDownloading && store.downloadModelName == model.id { return false }
            let repo = "models--" + model.id.replacingOccurrences(of: "/", with: "--")
            let snapshots = URL(fileURLWithPath: NSString(string: directory).expandingTildeInPath, isDirectory: true).appendingPathComponent("\(repo)/snapshots")
            guard let revisions = try? fm.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil) else { return false }
            return revisions.contains { revision in
                guard fm.fileExists(atPath: revision.appendingPathComponent("config.json").path),
                      let files = try? fm.contentsOfDirectory(at: revision, includingPropertiesForKeys: nil) else { return false }
                return files.contains { $0.pathExtension.lowercased() == "safetensors" && fm.fileExists(atPath: $0.path) }
            }
        }
        let repoName = model.id.split(separator: "/").last.map(String.init) ?? model.id
        let key = repoName.lowercased().replacingOccurrences(of: "-gguf", with: "")
        guard !key.isEmpty else { return false }
        return store.profiles.contains { profile in
            let path = NSString(string: profile.modelPath).expandingTildeInPath
            return profile.runtime.usesGGUF
                && fm.fileExists(atPath: path)
                && URL(fileURLWithPath: path).lastPathComponent.lowercased().contains(key)
        }
    }

    private func ggufFileExists(_ remotePath: String) -> Bool {
        if let selected = store.selectedModel, let localPath = localGGUFPaths[selected.id], URL(fileURLWithPath: localPath).lastPathComponent == URL(fileURLWithPath: remotePath).lastPathComponent {
            return FileManager.default.fileExists(atPath: localPath)
        }
        let root = NSString(string: directory).expandingTildeInPath
        return FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent(URL(fileURLWithPath: remotePath).lastPathComponent))
    }

    private func selectArea(_ newArea: ModelArea) {
        area = newArea
        if let first = newArea.categories.first { category = first }
    }

}

private struct LocalModelItem: Identifiable {
    enum Format { case gguf, mlx }
    let id: String
    let name: String
    let path: String
    let format: Format
    let size: Int64
}

private struct DownloadedModelsView: View {
    @Environment(AppStore.self) private var store
    let ggufDirectory: String
    @State private var models: [LocalModelItem] = []
    @State private var isScanning = false
    @State private var modelToRemove: LocalModelItem?
    @State private var selectedModel: LocalModelItem?
    @State private var selectedDownloadID: String?
    @State private var searchText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search downloaded models", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
            if isScanning { ProgressView("Scanning local model caches…") }
            if filteredModels.isEmpty && !isScanning && !hasActiveDownload {
                ContentUnavailableView(
                    searchText.isEmpty ? "No downloaded models" : "No matching models",
                    systemImage: searchText.isEmpty ? "externaldrive" : "magnifyingglass",
                    description: Text(searchText.isEmpty ? "Models you download will appear here." : "Try another model name or file name.")
                )
            } else {
                HSplitView {
                    List {
                    ForEach(store.downloadJobs.values.sorted { $0.modelID < $1.modelID }) { job in
                        HStack(spacing: 14) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(job.modelID).font(.headline)
                                Text(job.file).font(.caption).foregroundStyle(.secondary)
                                Label(job.phase, systemImage: job.phase.localizedCaseInsensitiveContains("verif") ? "checkmark.shield" : "arrow.down.circle").font(.caption).foregroundStyle(.secondary)
                                ProgressView(value: job.progress, total: 1)
                                Text("\(job.progress.formatted(.percent.precision(.fractionLength(1)))) · \(ByteCountFormatter.string(fromByteCount: job.received, countStyle: .file)) of \(job.total > 0 ? ByteCountFormatter.string(fromByteCount: job.total, countStyle: .file) : "unknown size")\(job.speed > 0 ? " · \(ByteCountFormatter.string(fromByteCount: Int64(job.speed), countStyle: .file))/s" : "")").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { store.toggleDownloadPause(job.id) } label: { Image(systemName: job.isPaused ? "play.fill" : "pause.fill") }.buttonStyle(.bordered).help(job.isPaused ? "Resume" : "Pause")
                                .accessibilityLabel(job.isPaused ? "Resume download" : "Pause download")
                            Button(role: .destructive) { store.cancelDownload(job.id) } label: { Image(systemName: "xmark") }.buttonStyle(.bordered).help("Cancel download")
                                .accessibilityLabel("Cancel download")
                        }.padding(.vertical, 9)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedDownloadID = job.id; selectedModel = nil }
                            .listRowBackground(selectedDownloadID == job.id ? store.appTheme.accent.opacity(0.14) : Color.clear)
                    }
                        ForEach(filteredModels) { model in
                            HStack(spacing: 14) {
                                Image(systemName: model.format == .gguf ? "shippingbox" : "apple.logo").frame(width: 28)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(model.name).font(.headline).lineLimit(1)
                                    HStack(spacing: 5) {
                                        Text(model.format == .gguf ? "GGUF" : "MLX")
                                        if model.size > 0 { Text("·"); Text(ByteCountFormatter.string(fromByteCount: model.size, countStyle: .file)) }
                                        Text("·"); Text(model.path).lineLimit(1)
                                    }.font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                                Spacer()
                                Button(role: .destructive) { modelToRemove = model } label: { Image(systemName: "trash") }.buttonStyle(.plain).help("Move model to Trash")
                                    .accessibilityLabel("Move model to Trash")
                            }
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedModel = model; selectedDownloadID = nil }
                            .listRowBackground(selectedModel?.id == model.id ? store.appTheme.accent.opacity(0.14) : Color.clear)
                        }
                    }
                    .frame(minWidth: 430, idealWidth: 620)
                    if let selectedDownloadID, let job = store.downloadJobs[selectedDownloadID] {
                        VStack(alignment: .leading, spacing: 18) {
                            Image(systemName: job.backend == .llamaCPP ? "shippingbox.fill" : "apple.logo").font(.system(size: 38)).foregroundStyle(store.appTheme.accent)
                            Text(job.modelID).font(.title2).fontWeight(.semibold).textSelection(.enabled)
                            Label(job.phase, systemImage: job.phase == "Finalizing" ? "checkmark.shield" : "arrow.down.circle")
                                .foregroundStyle(job.phase == "Finalizing" ? .orange : store.appTheme.accent)
                            LabeledContent("Format", value: job.backend == .llamaCPP ? "GGUF" : "MLX")
                            LabeledContent("Version", value: job.file)
                            LabeledContent("Progress", value: job.progress.formatted(.percent.precision(.fractionLength(1))))
                            LabeledContent("Downloaded", value: ByteCountFormatter.string(fromByteCount: job.received, countStyle: .file))
                            LabeledContent("Total", value: job.total > 0 ? ByteCountFormatter.string(fromByteCount: job.total, countStyle: .file) : "Calculating…")
                            if job.speed > 0 { LabeledContent("Speed", value: "\(ByteCountFormatter.string(fromByteCount: Int64(job.speed), countStyle: .file))/s") }
                            if !job.destination.isEmpty {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("Destination").font(.caption).foregroundStyle(.secondary)
                                    Text(job.destination).font(.caption.monospaced()).textSelection(.enabled)
                                }
                            }
                            Spacer()
                        }.padding(26).frame(minWidth: 310, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(store.appTheme.background)
                    } else if let selectedModel {
                        VStack(alignment: .leading, spacing: 18) {
                            Image(systemName: selectedModel.format == .gguf ? "shippingbox.fill" : "apple.logo").font(.system(size: 38)).foregroundStyle(store.appTheme.accent)
                            Text(selectedModel.name).font(.title2).fontWeight(.semibold).textSelection(.enabled)
                            LabeledContent("Format", value: selectedModel.format == .gguf ? "GGUF" : "MLX")
                            LabeledContent("Size", value: selectedModel.size > 0 ? ByteCountFormatter.string(fromByteCount: selectedModel.size, countStyle: .file) : "Calculating…")
                            if let provenance = provenance(for: selectedModel) {
                                Divider()
                                Text("Provenance").font(.headline)
                                if let url = ModelProvenance.repositoryURL(for: provenance.sourceModelID) {
                                    LabeledContent("Repository") { Link(provenance.sourceModelID, destination: url) }
                                } else {
                                    LabeledContent("Repository", value: provenance.sourceModelID.isEmpty ? "Unknown" : provenance.sourceModelID)
                                }
                                if let revision = provenance.revision, !revision.isEmpty {
                                    LabeledContent("Revision") {
                                        if let url = ModelProvenance.revisionURL(for: provenance) { Link(String(revision.prefix(12)), destination: url) }
                                        else { Text(String(revision.prefix(12))) }
                                    }
                                } else { LabeledContent("Revision", value: "Unknown") }
                                LabeledContent("License", value: provenance.license?.uppercased() ?? "Unknown")
                                LabeledContent("Quantization", value: provenance.quantization ?? ModelProvenance.quantization(from: selectedModel.name) ?? (selectedModel.format == .mlx ? "MLX" : "Unknown"))
                                VStack(alignment: .leading, spacing: 5) {
                                    Label(provenance.checksumVerified == true ? "SHA-256 verified" : "Checksum not verified", systemImage: provenance.checksumVerified == true ? "checkmark.shield.fill" : "exclamationmark.shield")
                                        .foregroundStyle(provenance.checksumVerified == true ? .green : .orange)
                                    Text(provenance.checksumSHA256 ?? "No checksum recorded")
                                        .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Location").font(.caption).foregroundStyle(.secondary)
                                Text(selectedModel.path).font(.caption.monospaced()).textSelection(.enabled)
                            }
                            } else {
                                Divider()
                                Label("Provenance unavailable for this legacy or externally added model", systemImage: "questionmark.diamond")
                                    .font(.caption).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("Location").font(.caption).foregroundStyle(.secondary)
                                    Text(selectedModel.path).font(.caption.monospaced()).textSelection(.enabled)
                                }
                            }
                            Spacer()
                        }.padding(26).frame(minWidth: 310, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(store.appTheme.background)
                    } else {
                        ContentUnavailableView("Select a downloaded model", systemImage: "shippingbox", description: Text("Choose a model to see its format, size, and local location."))
                            .frame(minWidth: 310, maxWidth: .infinity, maxHeight: .infinity).background(store.appTheme.background)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding().task { scan() }
        .onChange(of: store.isDownloading) { _, active in if !active { scan() } }
        .onChange(of: store.downloadJobs.count) { _, _ in
            scan()
            if let selectedDownloadID, store.downloadJobs[selectedDownloadID] == nil { self.selectedDownloadID = nil }
        }
        .onChange(of: store.serverLifecycle) { _, lifecycle in if lifecycle == .running { scan() } }
        .onChange(of: searchText) { _, _ in
            if let selectedModel, !filteredModels.contains(where: { $0.id == selectedModel.id }) {
                self.selectedModel = nil
            }
        }
        .alert("Remove downloaded model?", isPresented: Binding(get: { modelToRemove != nil }, set: { if !$0 { modelToRemove = nil } })) {
            Button("Move to Trash", role: .destructive) { if let model = modelToRemove { remove(model) }; modelToRemove = nil }
            Button("Cancel", role: .cancel) { modelToRemove = nil }
        } message: { Text("The model will be moved to the Trash. Profiles that reference it will remain, but cannot start until another model is selected.") }
    }

    private var hasActiveDownload: Bool { store.isDownloading || store.isResolvingDownload || store.serverLifecycle == .downloading }
    private func provenance(for model: LocalModelItem) -> ModelManifestEntry? {
        store.modelManifestEntries.first {
            URL(fileURLWithPath: $0.localPath).standardizedFileURL.path == URL(fileURLWithPath: model.path).standardizedFileURL.path
                || ($0.filename.caseInsensitiveCompare(model.name) == .orderedSame && FileManager.default.fileExists(atPath: $0.localPath))
        }
    }
    private var filteredModels: [LocalModelItem] {
        let query = normalizedSearchText(searchText)
        guard !query.isEmpty else { return models }
        return models.filter {
            normalizedSearchText($0.name).contains(query)
                || normalizedSearchText($0.path).contains(query)
        }
    }

    private func normalizedSearchText(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
    }
    private var activeDownloadName: String {
        if store.isDownloading { return store.downloadModelName.isEmpty ? "Downloading model" : store.downloadModelName }
        if store.isResolvingDownload { return store.downloadStatus.isEmpty ? "Finding model…" : store.downloadStatus }
        return store.profiles.first(where: { $0.id == store.runningProfileID })?.name ?? "MLX model"
    }

    private func remove(_ model: LocalModelItem) {
        let item = URL(fileURLWithPath: model.path)
        let target = model.format == .mlx ? item.deletingLastPathComponent().deletingLastPathComponent() : item
        NSWorkspace.shared.recycle([target]) { _, error in
            DispatchQueue.main.async {
                if let error { store.errorMessage = "Could not move the model to Trash: \(error.localizedDescription)" }
                scan()
            }
        }
    }

    private func scan() {
        isScanning = true
        let ggufRoot = NSString(string: ggufDirectory).expandingTildeInPath
        models = DownloadedModelCatalog.scan(root: URL(fileURLWithPath: ggufRoot, isDirectory: true)).map {
            .init(id: $0.path, name: $0.name, path: $0.path, format: $0.format == .gguf ? .gguf : .mlx, size: $0.size)
        }
        isScanning = false
    }
}

private struct ModelCard: View {
    let model: HFModel
    let backend: InferenceBackend
    let isRuntimeSupported: Bool
    let isSelected: Bool
    let isDownloaded: Bool
    let versionCounts: (total: Int, downloaded: Int, downloading: Int)
    let action: () -> Void

    private var name: String { model.id.split(separator: "/").last.map(String.init) ?? model.id }
    private var author: String { model.id.split(separator: "/").first.map(String.init) ?? "Community" }
    private var visibleTags: [String] {
        let preferred = ["thinking", "vision", "tools", "multilingual", "code", "text-generation"]
        return preferred.filter { tag in model.tags?.contains(where: { $0.localizedCaseInsensitiveContains(tag) }) == true }.prefix(3).map { $0 }
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                ZStack { RoundedRectangle(cornerRadius: 10).fill(.quaternary); Text(String(name.prefix(1)).uppercased()).font(.title2).fontWeight(.semibold) }.frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 7) {
                    HStack { Text(name).font(.headline).lineLimit(1); Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                    Text(author).font(.subheadline).foregroundStyle(.secondary)
                    ViewThatFits(in: .horizontal) {
                        tagRow(limit: visibleTags.count)
                        tagRow(limit: min(2, visibleTags.count))
                        tagRow(limit: min(1, visibleTags.count))
                        tagRow(limit: 0)
                    }
                    HStack(spacing: 9) {
                        if versionCounts.total > 0 {
                            Label("\(versionCounts.total)", systemImage: "square.stack.3d.up")
                                .font(.caption).foregroundStyle(.secondary).fixedSize()
                                .help("\(versionCounts.total) available \(versionCounts.total == 1 ? "version" : "versions")")
                        }
                        if versionCounts.downloaded > 0 {
                            Label("\(versionCounts.downloaded)", systemImage: "arrow.down.circle.fill").font(.caption).foregroundStyle(.green).fixedSize()
                                .help("\(versionCounts.downloaded) downloaded")
                        }
                        if versionCounts.downloading > 0 {
                            Label("\(versionCounts.downloading)", systemImage: "arrow.down.circle.fill").font(.caption).foregroundStyle(Color.accentColor).fixedSize()
                                .help("\(versionCounts.downloading) downloading")
                        }
                        Spacer()
                        if let size = model.usedStorage, size > 0 { Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)).font(.caption).foregroundStyle(.secondary).fixedSize() }
                        Label(compact(model.downloads ?? 0), systemImage: "arrow.down").font(.caption).foregroundStyle(.secondary).fixedSize().help("Repository downloads")
                        Label(compact(model.likes ?? 0), systemImage: "heart").font(.caption).foregroundStyle(.secondary).fixedSize().help("Hugging Face likes")
                    }
                }
            }.padding(12).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(isSelected ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.08)))
    }

    @ViewBuilder
    private func tagRow(limit: Int) -> some View {
        HStack(spacing: 7) {
            Text(backend == .llamaCPP ? "GGUF" : "MLX").modelBadge().fixedSize()
            if !isRuntimeSupported {
                Label("Runtime unavailable", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.caption2).fixedSize()
            }
            ForEach(Array(visibleTags.prefix(limit)), id: \.self) { tag in
                Text(tag).lineLimit(1).modelBadge().fixedSize()
            }
            if visibleTags.count > limit {
                Text("+\(visibleTags.count - limit)").modelBadge().fixedSize()
            }
            Spacer(minLength: 0)
        }
    }

    private func compact(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return String(value)
    }
}

private extension View {
    func modelBadge() -> some View { padding(.horizontal, 7).padding(.vertical, 3).background(.quaternary, in: Capsule()).font(.caption2) }
    func modelFitBadge(_ fit: ModelFit) -> some View {
        foregroundStyle(fit == .comfortable ? Color.green : (fit == .tight ? Color.orange : Color.red))
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background((fit == .comfortable ? Color.green : (fit == .tight ? Color.orange : Color.red)).opacity(0.12), in: Capsule())
    }
}

private struct ChatTailPositionKey: PreferenceKey {
    static let defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct ScrollWheelObserver: NSViewRepresentable {
    let onScroll: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onScroll: onScroll) }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.observe(view)
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.onScroll = onScroll }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.stop() }

    @MainActor final class Coordinator {
        var onScroll: () -> Void
        private var monitor: Any?
        init(onScroll: @escaping () -> Void) { self.onScroll = onScroll }
        func observe(_ view: NSView) {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self, weak view] event in
                guard let self, let view, event.window === view.window,
                      view.bounds.contains(view.convert(event.locationInWindow, from: nil)),
                      abs(event.scrollingDeltaY) > 0.1 else { return event }
                self.onScroll()
                return event
            }
        }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    }
}

struct LogsView: View {
    @Environment(AppStore.self) private var store
    @State private var followsTail = true
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle().fill(store.serverLifecycle == .running ? Color.green : (store.failedProfileID != nil ? .red : .secondary)).frame(width: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Logs").font(.title2).fontWeight(.semibold)
                    Text(store.serverLifecycle.label).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(store.logs, forType: .string) } label: { Label("Copy", systemImage: "doc.on.doc") }.disabled(store.logs.isEmpty)
                Button { store.logs = "" } label: { Label("Clear", systemImage: "trash") }.disabled(store.logs.isEmpty)
                Button {
                    if FileManager.default.fileExists(atPath: store.logFileURL.path) {
                        NSWorkspace.shared.activateFileViewerSelecting([store.logFileURL])
                    } else {
                        store.errorMessage = "No log file yet — start a profile first."
                    }
                } label: { Label("Reveal log file", systemImage: "folder") }
                Button("Stop engine", role: .destructive) { store.stop() }.disabled(!store.isRunning)
            }.padding()
            Text("The full session log is also written to disk, independent of what's shown here or cleared above.")
                .font(.caption2).foregroundStyle(.secondary).padding(.horizontal).padding(.bottom, 8)
            Divider()
            if store.logs.isEmpty {
                ContentUnavailableView("No engine logs", systemImage: "doc.text.magnifyingglass", description: Text("Output from the active inference engine will appear here."))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(store.logs).font(.system(.body, design: .monospaced)).foregroundStyle(.primary).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading).padding(16)
                        Color.clear.frame(height: 1).id("logs-tail")
                    }
                    .simultaneousGesture(DragGesture(minimumDistance: 3).onChanged { value in
                        if abs(value.translation.height) > 3 { followsTail = false }
                    })
                    .background(ScrollWheelObserver { followsTail = false })
                    .onChange(of: store.logs.count) { _, _ in if followsTail { proxy.scrollTo("logs-tail", anchor: .bottom) } }
                    .overlay(alignment: .bottomTrailing) {
                        if !followsTail { Button("Resume tail") { followsTail = true; proxy.scrollTo("logs-tail", anchor: .bottom) }.buttonStyle(.borderedProminent).padding(18) }
                    }
                }.background(store.appTheme.surface).clipShape(RoundedRectangle(cornerRadius: 10)).padding()
            }
        }.background(store.appTheme.background).navigationTitle("Logs")
    }
}

struct PromptView: View {
    @Environment(AppStore.self) private var store
    @State private var showsSidebar = true
    @State private var chatSearch = ""
    @State private var editText = ""
    @State private var editingChatID: UUID?
    @State private var editingProjectID: UUID?
    @State private var showsNewProject = false
    @State private var composerHeight: CGFloat = 44
    @State private var composerDragStart: CGFloat?
    @State private var composerUsesManualHeight = false
    @State private var followsChatTail = true
    @State private var isChatDropTargeted = false
    @State private var editingMessageID: UUID?
    @State private var messageEditDraft = ""

    var body: some View {
        @Bindable var store = store
        HSplitView {
            if showsSidebar { chatSidebar.frame(minWidth: 190, idealWidth: 220, maxWidth: 260) }
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button { withAnimation { showsSidebar.toggle() } } label: { Image(systemName: "sidebar.left") }.buttonStyle(.plain).help("Toggle conversation rail")
                        .accessibilityLabel("Toggle conversation rail")
                    Button { store.clearConversation() } label: { Image(systemName: "square.and.pencil") }.buttonStyle(.plain).help("New chat")
                    .accessibilityLabel("New chat")
                    Spacer()
                    contextUsageBadge
                    if let running = runningProfile {
                        HStack(spacing: 6) { Circle().fill(.green).frame(width: 8, height: 8); Text(running.chatDisplayName).lineLimit(1) }.font(.caption).foregroundStyle(.secondary)
                    } else { Text("No model running").font(.caption).foregroundStyle(.secondary) }
                }.padding(.horizontal, 18).padding(.vertical, 13)
                Divider()
                if store.runtimeHealth.contextUsageLevel == .critical {
                    Label("Context window is nearly full — the model may start losing earlier parts of this conversation. Consider starting a new chat.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .background(Color.red.opacity(0.08))
                }

                GeometryReader { viewport in
                ScrollViewReader { proxy in
                    ScrollView {
                        if store.messages.isEmpty { emptyChat }
                        else {
                            VStack(spacing: 22) {
                                ForEach(store.messages) { message in chatMessage(message, isStreaming: store.isSending && message.id == store.messages.last?.id && message.role == "assistant", isLast: message.id == store.messages.last?.id) }
                                if store.isSending { HStack { ProgressView().controlSize(.small); Text("\(store.engineActivity.label.isEmpty ? "Working" : store.engineActivity.label)…").foregroundStyle(.secondary); Spacer() } }
                                Color.clear.frame(height: 1).id("chat-bottom")
                                    .background(GeometryReader { tail in
                                        Color.clear.preference(key: ChatTailPositionKey.self, value: tail.frame(in: .named("prompt-chat-scroll")).maxY)
                                    })
                            }.frame(maxWidth: 760).padding(.horizontal, 28).padding(.vertical, 32).frame(maxWidth: .infinity)
                        }
                    }.coordinateSpace(name: "prompt-chat-scroll")
                    .simultaneousGesture(DragGesture(minimumDistance: 3).onChanged { value in
                        followsChatTail = ChatTailPolicy.shouldFollow(currentlyFollowing: followsChatTail, bottomIsVisible: false, userScrolledUp: abs(value.translation.height) > 3)
                    })
                    .background(ScrollWheelObserver { followsChatTail = false })
                    .onPreferenceChange(ChatTailPositionKey.self) { tailY in
                        let visible = tailY > 0 && tailY <= viewport.size.height + 8
                        followsChatTail = ChatTailPolicy.shouldFollow(currentlyFollowing: followsChatTail, bottomIsVisible: visible, userScrolledUp: false)
                    }
                    .onChange(of: latestMessageContent) { _, _ in scrollChatToBottom(proxy) }
                    .onChange(of: store.messages.count) { _, _ in scrollChatToBottom(proxy, force: true) }
                    .onChange(of: store.isSending) { _, sending in if sending { scrollChatToBottom(proxy, force: true) } }
                    .onChange(of: store.activeChatID) { _, _ in followsChatTail = true; scrollChatToBottom(proxy, force: true) }
                    .overlay(alignment: .bottomTrailing) {
                        if !followsChatTail {
                            Button { followsChatTail = true; proxy.scrollTo("chat-bottom", anchor: .bottom) } label: { Image(systemName: "arrow.down") }
                                .help("Scroll to latest").accessibilityLabel("Scroll to latest")
                                .buttonStyle(.borderedProminent).help("Resume following new output").padding(12)
                        }
                    }
                }
                }

                chatComposer
                    .frame(maxWidth: showsSidebar ? 760 : 900)
                    .padding(.horizontal, 28).padding(.bottom, 18)
            }.frame(minWidth: 480).background(store.appTheme.background)
        }.background(store.appTheme.background).navigationTitle("Chat")
    }

    private var runningProfile: ServerProfile? { store.profiles.first { $0.id == store.runningProfileID } }

    // Reflects RuntimeHealth.contextTokens/.contextLimit — parsed live
    // from the running server's own logs (see RuntimeTelemetryParser) —
    // so it grows in view as this conversation's full history gets
    // resent on every turn, with no separate tracking of its own to keep
    // in sync. Hidden until a limit is actually known (no profile
    // running yet, or its runtime doesn't log a parseable context size).
    @ViewBuilder private var contextUsageBadge: some View {
        let health = store.runtimeHealth
        if health.contextLimit > 0 {
            HStack(spacing: 5) {
                Image(systemName: health.contextUsageLevel == .critical ? "exclamationmark.triangle.fill" : "chart.bar.fill")
                Text(health.contextFraction.formatted(.percent.precision(.fractionLength(0))))
            }
            .font(.caption).foregroundStyle(contextUsageTint(health.contextUsageLevel))
            .help("Context window: \(health.contextTokens.formatted()) / \(health.contextLimit.formatted()) tokens used")
        }
    }
    private var latestMessageContent: String { store.messages.last?.content ?? "" }

    private var chatSidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Search chats", text: $chatSearch).textFieldStyle(.roundedBorder)
            HStack {
                Button { store.newChat() } label: { Label("New chat", systemImage: "square.and.pencil") }.buttonStyle(.plain)
                Spacer()
                Button { editText = ""; showsNewProject = true } label: { Image(systemName: "folder.badge.plus") }.buttonStyle(.plain).help("New project")
                    .accessibilityLabel("New project")
            }.padding(.vertical, 5)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    ForEach(store.chatProjects) { project in
                        DisclosureGroup {
                            ForEach(filteredChats.filter { $0.projectID == project.id }) { chat in chatRow(chat) }
                        } label: { Text(project.name).font(.headline).lineLimit(1) }
                        .contextMenu {
                            Button("Rename") { editingProjectID = project.id; editText = project.name }
                            Button("New chat") { store.newChat(projectID: project.id) }
                            Button("Delete project", role: .destructive) { store.deleteChatProject(project.id) }
                        }
                    }
                    if !store.chatProjects.isEmpty { Divider().padding(.vertical, 3) }
                    Text("Chats").font(.caption).foregroundStyle(.secondary)
                    ForEach(filteredChats.filter { $0.projectID == nil }) { chat in chatRow(chat) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer()
            if let profile = runningProfile {
                VStack(alignment: .leading, spacing: 4) {
                    Text("LOCAL MODEL").font(.caption2).foregroundStyle(.secondary)
                    Text(profile.name).font(.caption).lineLimit(2)
                    Text(profile.runtime.title).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }.padding(14).background(store.appTheme.surface)
        .alert("New project", isPresented: $showsNewProject) {
            TextField("Project name", text: $editText)
            Button("Create") { store.createChatProject(named: editText) }
            Button("Cancel", role: .cancel) { }
        }
        .alert("Rename chat", isPresented: Binding(get: { editingChatID != nil }, set: { if !$0 { editingChatID = nil } })) {
            TextField("Chat name", text: $editText)
            Button("Save") { if let id = editingChatID { store.renameChat(id, to: editText) }; editingChatID = nil }
            Button("Cancel", role: .cancel) { editingChatID = nil }
        }
        .alert("Rename project", isPresented: Binding(get: { editingProjectID != nil }, set: { if !$0 { editingProjectID = nil } })) {
            TextField("Project name", text: $editText)
            Button("Save") { if let id = editingProjectID { store.renameChatProject(id, to: editText) }; editingProjectID = nil }
            Button("Cancel", role: .cancel) { editingProjectID = nil }
        }
    }

    private var filteredChats: [SavedChat] {
        let sorted = store.chats.sorted { $0.updatedAt > $1.updatedAt }
        guard !chatSearch.trimmingCharacters(in: .whitespaces).isEmpty else { return sorted }
        return sorted.filter { $0.title.localizedCaseInsensitiveContains(chatSearch) || $0.messages.contains(where: { $0.content.localizedCaseInsensitiveContains(chatSearch) }) }
    }

    private func chatRow(_ chat: SavedChat) -> some View {
        Button { store.selectChat(chat.id) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.title).lineLimit(1)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(chatDuration(store.chatElapsedSeconds(chat, at: context.date))).font(.caption2).foregroundStyle(.secondary)
                }
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
        .background(store.activeChatID == chat.id ? Color.accentColor.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            Button("Rename") { editingChatID = chat.id; editText = chat.title }
            Menu("Move to project") {
                Button("No project") { store.moveChat(chat.id, to: nil) }
                ForEach(store.chatProjects) { project in Button(project.name) { store.moveChat(chat.id, to: project.id) } }
            }
            Button("Export as Markdown…") { exportChat(chat) }
            Button("Delete", role: .destructive) { store.deleteChat(chat.id) }
        }
    }

    private func exportChat(_ chat: SavedChat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = chat.suggestedExportFilename
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try chat.markdownExport.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            store.errorMessage = "Could not export chat: \(error.localizedDescription)"
        }
    }

    private func chatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total >= 3600 { return String(format: "%d hr, %d min", total / 3600, (total % 3600) / 60) }
        if total >= 60 { return String(format: "%d min, %d sec", total / 60, total % 60) }
        return "\(total) sec"
    }

    private var emptyChat: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 90)
            Image(systemName: "sparkles").font(.system(size: 34)).foregroundStyle(.blue)
            Text("Ask your local model").font(.largeTitle).fontWeight(.semibold)
            Text(store.isRunning ? "Responses stay on this Mac." : "Start a favorite profile from the menu bar to begin.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer(minLength: 90)
        }.frame(maxWidth: .infinity, minHeight: 420)
    }

    @ViewBuilder private func chatMessage(_ message: ChatMessage, isStreaming: Bool, isLast: Bool) -> some View {
        if message.role == "user" {
            if editingMessageID == message.id {
                editingUserMessage(message)
            } else {
                VStack(alignment: .trailing, spacing: 4) {
                    if !message.imageAttachments.isEmpty {
                        HStack { Spacer(minLength: 90); ChatImageThumbnailRow(attachments: message.imageAttachments) }
                    }
                    if !message.content.isEmpty {
                        HStack { Spacer(minLength: 90); Text(message.content).textSelection(.enabled).padding(.horizontal, 15).padding(.vertical, 11).background(Color.primary.opacity(0.10), in: RoundedRectangle(cornerRadius: 20)) }
                    }
                    Button { editingMessageID = message.id; messageEditDraft = message.content } label: { Image(systemName: "pencil") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).font(.caption)
                        .help("Edit and resend").accessibilityLabel("Edit and resend")
                        .disabled(store.isSending)
                }
            }
        } else {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkles").foregroundStyle(.blue).padding(.top, 3)
                VStack(alignment: .leading, spacing: 12) {
                    AssistantMessageContent(content: message.content, isStreaming: isStreaming)
                    HStack(spacing: 16) {
                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.content, forType: .string) } label: { Image(systemName: "doc.on.doc") }
                            .help("Copy message").accessibilityLabel("Copy message")
                        Button { } label: { Image(systemName: "hand.thumbsup") }.disabled(true).accessibilityLabel("Good response")
                        Button { } label: { Image(systemName: "hand.thumbsdown") }.disabled(true).accessibilityLabel("Bad response")
                        if isLast && !isStreaming {
                            Button { store.regenerateLastResponse() } label: { Image(systemName: "arrow.counterclockwise") }
                                .help("Regenerate response").accessibilityLabel("Regenerate response")
                                .disabled(store.isSending || !store.isRunning)
                        }
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func editingUserMessage(_ message: ChatMessage) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextField("Edit message", text: $messageEditDraft, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(1...10)
                .padding(.horizontal, 15).padding(.vertical, 11)
                .background(Color.primary.opacity(0.10), in: RoundedRectangle(cornerRadius: 20))
            HStack(spacing: 12) {
                Button("Cancel") { editingMessageID = nil }.buttonStyle(.plain).foregroundStyle(.secondary)
                Button("Save & Resend") {
                    store.editAndResend(messageID: message.id, newText: messageEditDraft)
                    editingMessageID = nil
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(messageEditDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var chatComposer: some View {
        VStack(spacing: 9) {
            ChatAttachmentStrip()
            Capsule().fill(Color.secondary.opacity(0.45)).frame(width: 44, height: 4)
                .contentShape(Rectangle().inset(by: -8))
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if composerDragStart == nil { composerDragStart = composerHeight }
                        composerUsesManualHeight = true
                        composerHeight = min(max((composerDragStart ?? composerHeight) - value.translation.height, 44), 260)
                    }
                    .onEnded { _ in composerDragStart = nil })
                .onTapGesture(count: 2) {
                    composerUsesManualHeight = false
                    composerHeight = ChatComposerSizing.height(for: store.prompt)
                }
                .help("Drag to resize; double-click for automatic height")
            TextField("Ask your local model", text: Bindable(store).prompt, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(2...14)
                .frame(height: composerHeight, alignment: .top)
                .onSubmit { submitPrompt() }
            HStack(spacing: 12) {
                Button { chooseChatFiles() } label: { Image(systemName: "plus") }.buttonStyle(.plain).help("Attach files")
                    .accessibilityLabel("Attach files")
                if store.webSearchEnabled { webSearchToggleButton }
                Spacer()
                if let profile = runningProfile { Text(profile.chatDisplayName).font(.caption).lineLimit(1).padding(.horizontal, 10).padding(.vertical, 5).background(.quaternary, in: Capsule()) }
                if store.isSending {
                    Button { store.cancelPrompt() } label: { Image(systemName: "stop.circle.fill").font(.title2) }
                        .help("Stop generating").accessibilityLabel("Stop generating")
                        .buttonStyle(.plain).help("Stop generating")
                }
                Button { submitPrompt() } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .help("Send message").accessibilityLabel("Send message")
                    .buttonStyle(.plain).disabled((store.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && store.pendingChatAttachments.isEmpty && store.pendingChatImageAttachments.isEmpty) || store.isSending || !store.isRunning)
            }
        }.padding(.horizontal, 16).padding(.vertical, 10).background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(isChatDropTargeted ? Color.accentColor : .clear, lineWidth: 2))
            .dropDestination(for: URL.self) { urls, _ in
                store.attachChatFiles(urls)
                return !urls.isEmpty
            } isTargeted: { isChatDropTargeted = $0 }
            .onPasteCommand(of: [.image]) { providers in pasteImages(providers) }
            .onChange(of: store.prompt) { _, value in
                if !composerUsesManualHeight { composerHeight = ChatComposerSizing.height(for: value) }
            }
    }

    private var webSearchToggleButton: some View {
        Button { store.webSearchEnabledThisChat.toggle() } label: { Image(systemName: store.webSearchEnabledThisChat ? "network" : "network.slash") }
            .buttonStyle(.plain)
            .foregroundStyle(store.webSearchEnabledThisChat ? Color.accentColor : .secondary)
            .help(store.webSearchEnabledThisChat ? "Web search is on for this chat — click to turn off" : "Web search is off for this chat — click to turn back on")
            .accessibilityLabel(store.webSearchEnabledThisChat ? "Turn off web search for this chat" : "Turn on web search for this chat")
    }

    private func submitPrompt() {
        guard !store.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.pendingChatAttachments.isEmpty || !store.pendingChatImageAttachments.isEmpty, store.isRunning, !store.isSending else { return }
        followsChatTail = true
        store.beginSendingPrompt()
    }

    private func scrollChatToBottom(_ proxy: ScrollViewProxy, force: Bool = false) {
        guard force || followsChatTail else { return }
        if force { followsChatTail = true }
        DispatchQueue.main.async { proxy.scrollTo("chat-bottom", anchor: .bottom) }
    }

}

// Renders one user message's attached images, largest first-seen order,
// loaded lazily from AppStore's on-disk chat-images cache (see
// AppStore.loadedChatImage) rather than kept inline in ChatMessage.
private struct ChatImageThumbnailRow: View {
    @Environment(AppStore.self) private var store
    let attachments: [ChatImageAttachment]
    var size: CGFloat = 160

    var body: some View {
        HStack(spacing: 6) {
            ForEach(attachments) { attachment in
                Group {
                    if let image = store.loadedChatImage(attachment) {
                        Image(nsImage: image).resizable().scaledToFit()
                    } else {
                        Image(systemName: "photo").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: size, maxHeight: size)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}

private struct ChatAttachmentStrip: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        if !store.pendingChatAttachments.isEmpty || !store.pendingChatImageAttachments.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(store.pendingChatImageAttachments) { attachment in
                            VStack(spacing: 0) {
                                Image(nsImage: attachment.thumbnail).resizable().scaledToFill()
                                    .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .overlay(alignment: .topTrailing) {
                                Button { store.pendingChatImageAttachments.removeAll { $0.id == attachment.id } } label: {
                                    Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.6))
                                }
                                .buttonStyle(.plain).offset(x: 5, y: -5)
                                .help("Remove attachment").accessibilityLabel("Remove attachment")
                            }
                            .help(attachment.name)
                        }
                        ForEach(store.pendingChatAttachments) { attachment in
                            HStack(spacing: 5) {
                                Image(systemName: "doc")
                                Text(attachment.name).lineLimit(1)
                                Button { store.pendingChatAttachments.removeAll { $0.id == attachment.id } } label: { Image(systemName: "xmark.circle.fill") }
                                    .help("Remove attachment").accessibilityLabel("Remove attachment")
                                    .buttonStyle(.plain)
                            }.font(.caption).padding(.horizontal, 9).padding(.vertical, 6).background(.quaternary, in: Capsule())
                        }
                    }
                }
                if !store.pendingChatImageAttachments.isEmpty && store.runningProfileLacksVisionProjector {
                    Label("The running profile has no vision projector — it likely won't see this image.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
        }
    }
}

@MainActor private func chooseChatFiles() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowedContentTypes = [.plainText, .sourceCode, .json, .xml, .commaSeparatedText, .yaml, .propertyList, .image]
    guard panel.runModal() == .OK else { return }
    AppStore.shared.attachChatFiles(panel.urls)
}

// Handles ⌘V of a screenshot or copied image straight into the
// composer — the common way to "hand the model a screenshot" in
// practice, alongside dropping or picking a saved file.
private func pasteImages(_ providers: [NSItemProvider]) {
    for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
        provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
            guard let data else { return }
            Task { @MainActor in AppStore.shared.attachChatImage(pasteboardData: data, suggestedName: "Pasted image") }
        }
    }
}

private struct AssistantMessageContent: View {
    let content: String
    var isStreaming = false

    var body: some View {
        Group {
            if isStreaming {
                Text(ChatProseLayout.attributed(ChatMarkdownParser.visibleAnswer(from: content)))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(ChatMarkdownParser.segments(content).enumerated()), id: \.offset) { _, segment in
                        switch segment {
                        case .prose(let text): ChatMarkdownProse(content: text)
                        case .code(let language, let source): ChatCodeBlock(language: language, source: source)
                        case .table(let headers, let rows): ChatMarkdownTable(headers: headers, rows: rows)
                        }
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

}

private struct ChatMarkdownProse: View {
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(content.components(separatedBy: "\n").enumerated()), id: \.offset) { _, rawLine in
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                let indentation = rawLine.prefix(while: { $0 == " " || $0 == "\t" }).reduce(CGFloat.zero) { value, character in value + (character == "\t" ? 24 : 4) }
                if line.isEmpty { Spacer().frame(height: 4) }
                else if line == "---" || line == "***" || line == "___" { Divider().padding(.vertical, 4) }
                else if line.hasPrefix("### ") { markdownLine(String(line.dropFirst(4))).font(.headline) }
                else if line.hasPrefix("## ") { markdownLine(String(line.dropFirst(3))).font(.title3.weight(.semibold)) }
                else if line.hasPrefix("# ") { markdownLine(String(line.dropFirst(2))).font(.title2.weight(.semibold)) }
                else if line.hasPrefix("###### ") { markdownLine(String(line.dropFirst(7))).font(.caption.weight(.semibold)) }
                else if line.hasPrefix("##### ") { markdownLine(String(line.dropFirst(6))).font(.subheadline.weight(.semibold)) }
                else if line.hasPrefix("#### ") { markdownLine(String(line.dropFirst(5))).font(.body.weight(.semibold)) }
                else if line.hasPrefix("> ") {
                    markdownLine(String(line.dropFirst(2))).foregroundStyle(.secondary).padding(.leading, 10)
                        .overlay(alignment: .leading) { Rectangle().fill(Color.accentColor.opacity(0.55)).frame(width: 3) }
                } else if line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") {
                    HStack(alignment: .firstTextBaseline, spacing: 8) { Image(systemName: "checkmark.square.fill").foregroundStyle(.green); markdownLine(String(line.dropFirst(6))) }.padding(.leading, indentation)
                } else if line.hasPrefix("- [ ] ") {
                    HStack(alignment: .firstTextBaseline, spacing: 8) { Image(systemName: "square").foregroundStyle(.secondary); markdownLine(String(line.dropFirst(6))) }.padding(.leading, indentation)
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                    HStack(alignment: .firstTextBaseline, spacing: 8) { Text("•"); markdownLine(String(line.dropFirst(2))) }.padding(.leading, indentation)
                } else if let match = line.range(of: #"^\d+[.)]\s"#, options: .regularExpression) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) { Text(String(line[match])); markdownLine(String(line[match.upperBound...])) }.padding(.leading, indentation)
                } else { markdownLine(rawLine) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func markdownLine(_ line: String) -> some View {
        Text(ChatProseLayout.attributed(line)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ChatMarkdownTable: View {
    let headers: [String]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                tableRow(headers, isHeader: true)
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(rows.indices, id: \.self) { index in
                    tableRow(rows[index], isHeader: false)
                    if index < rows.count - 1 { Divider().gridCellUnsizedAxes(.horizontal) }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.12)))
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func tableRow(_ cells: [String], isHeader: Bool) -> some View {
        GridRow {
            ForEach(0..<headers.count, id: \.self) { column in
                Text(ChatProseLayout.attributed(column < cells.count ? cells[column] : ""))
                    .fontWeight(isHeader ? .semibold : .regular)
                    .textSelection(.enabled)
                    .frame(minWidth: 110, maxWidth: 280, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(isHeader ? Color.primary.opacity(0.07) : Color.clear)
                    .overlay(alignment: .trailing) {
                        if column < headers.count - 1 { Rectangle().fill(Color.primary.opacity(0.10)).frame(width: 1) }
                    }
            }
        }
    }
}

private struct ChatCodeBlock: View {
    let language: String
    let source: String
    @State private var copied = false

    private var lines: [String] {
        let value = source.components(separatedBy: "\n")
        return value.isEmpty ? [""] : value
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(language.isEmpty ? "Code" : language.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(source, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") }
                    .buttonStyle(.plain).font(.caption)
            }.padding(.horizontal, 12).padding(.vertical, 8).background(Color.primary.opacity(0.07))
            Divider()
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .trailing, spacing: 0) {
                        ForEach(lines.indices, id: \.self) { index in
                            Text(String(index + 1)).frame(height: 19)
                        }
                    }.foregroundStyle(.tertiary).textSelection(.disabled)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(lines.indices, id: \.self) { index in
                            Text(highlight(lines[index])).frame(height: 19, alignment: .leading).textSelection(.enabled)
                        }
                    }
                }.font(.system(.body, design: .monospaced)).padding(12)
            }
        }
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func highlight(_ line: String) -> AttributedString {
        let result = NSMutableAttributedString(string: line, attributes: [.foregroundColor: NSColor.labelColor])
        let full = NSRange(location: 0, length: result.length)
        let keywordPattern = #"\b(if|then|else|elif|fi|for|while|do|done|case|esac|function|func|let|var|class|struct|enum|return|import|from|def|async|await|try|catch|throw|true|false|nil|null|SELECT|FROM|WHERE|JOIN|INSERT|UPDATE|DELETE|CREATE)\b"#
        for (pattern, color) in [(keywordPattern, NSColor.systemPurple), (#"(['\"]).*?\2"#, NSColor.systemGreen), (#"\b\d+(?:\.\d+)?\b"#, NSColor.systemOrange), (#"(?:#|//).*$"#, NSColor.systemGray)] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            for match in regex.matches(in: line, range: full) { result.addAttribute(.foregroundColor, value: color, range: match.range) }
        }
        return AttributedString(result)
    }
}

struct AssistantPopoverView: View {
    @Environment(AppStore.self) private var store
    let openSection: (AppSection) -> Void
    let showAbout: () -> Void
    @State private var composerHeight: CGFloat = 44
    @State private var composerDragStart: CGFloat?
    @State private var composerUsesManualHeight = false
    @State private var followsChatTail = true
    @State private var isChatDropTargeted = false
    @State private var editingMessageID: UUID?
    @State private var messageEditDraft = ""

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").foregroundStyle(.blue).font(.title2)
                VStack(alignment: .leading, spacing: 1) {
                    Text("InferenceBar").font(.headline)
                    if let running = store.profiles.first(where: { $0.id == store.runningProfileID }) {
                        Label(running.chatDisplayName, systemImage: "circle.fill").font(.caption).foregroundStyle(store.serverLifecycle == .running ? .green : .orange)
                    } else { Text("No model running").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                contextUsageBadge
                Menu {
                    Menu("Start LLM") {
                        if store.serverLifecycle == .stopping {
                            Text("Stopping current model…")
                        } else
                        if store.favoriteProfiles.isEmpty {
                            Text("No favorite profiles")
                        } else {
                            ForEach(store.favoriteProfiles) { profile in
                                Button(profile.name) { store.selectedProfileID = profile.id; store.start() }
                                    .disabled(!store.canStartProfile)
                            }
                        }
                    }
                    if store.serverLifecycle == .running { Button("Stop LLM", role: .destructive) { store.stop() } }
                    Divider()
                    Button("Models & Profiles…") { openSection(.models) }
                    Button("Settings…") { openSection(.settings) }
                    Button("About InferenceBar") { showAbout() }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel("More options")
                Button { store.clearConversation() } label: { Image(systemName: "square.and.pencil") }.buttonStyle(.plain).help("New chat")
                    .accessibilityLabel("New chat")
            }.padding(16)
            Divider()
            if store.runtimeHealth.contextUsageLevel == .critical {
                Label("Context window nearly full — consider starting a new chat.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    .background(Color.red.opacity(0.08))
            }

            if store.messages.isEmpty {
                VStack(spacing: 14) {
                    Spacer()
                    ZStack { Circle().fill(.blue.opacity(0.14)); Image(systemName: "sparkles").font(.system(size: 30)).foregroundStyle(.blue) }.frame(width: 68, height: 68)
                    Text("How can I help?").font(.title).fontWeight(.semibold)
                    Text(store.isRunning ? "Ask the local model anything." : "Start a favorite profile from the right-click menu first.").foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Spacer()
                }.padding(30)
            } else {
                GeometryReader { viewport in
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 18) {
                            ForEach(store.messages) { message in
                                let isLast = message.id == store.messages.last?.id
                                let isStreaming = store.isSending && isLast && message.role == "assistant"
                                if message.role == "user" {
                                    if editingMessageID == message.id {
                                        popoverEditingUserMessage(message)
                                    } else {
                                        VStack(alignment: .trailing, spacing: 3) {
                                            if !message.imageAttachments.isEmpty {
                                                HStack { Spacer(minLength: 80); ChatImageThumbnailRow(attachments: message.imageAttachments, size: 96) }
                                            }
                                            if !message.content.isEmpty {
                                                HStack { Spacer(minLength: 80); Text(message.content).textSelection(.enabled).padding(.horizontal, 14).padding(.vertical, 10).background(.quaternary, in: RoundedRectangle(cornerRadius: 18)) }
                                            }
                                            Button { editingMessageID = message.id; messageEditDraft = message.content } label: { Image(systemName: "pencil") }
                                                .buttonStyle(.plain).foregroundStyle(.secondary).font(.caption2)
                                                .help("Edit and resend").accessibilityLabel("Edit and resend")
                                                .disabled(store.isSending)
                                        }
                                    }
                                } else {
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: "sparkles").foregroundStyle(.blue).padding(.top, 3)
                                        VStack(alignment: .leading, spacing: 6) {
                                            AssistantMessageContent(content: message.content, isStreaming: isStreaming)
                                            if isLast && !isStreaming {
                                                Button { store.regenerateLastResponse() } label: { Image(systemName: "arrow.counterclockwise") }
                                                    .buttonStyle(.plain).foregroundStyle(.secondary).font(.caption2)
                                                    .help("Regenerate response").accessibilityLabel("Regenerate response")
                                                    .disabled(store.isSending || !store.isRunning)
                                            }
                                        }
                                    }
                                }
                            }
                            if store.isSending { HStack { ProgressView().controlSize(.small); Text("\(store.engineActivity.label.isEmpty ? "Working" : store.engineActivity.label)…").foregroundStyle(.secondary); Spacer() } }
                            Color.clear.frame(height: 1).id("bottom")
                                .background(GeometryReader { tail in
                                    Color.clear.preference(key: ChatTailPositionKey.self, value: tail.frame(in: .named("popover-chat-scroll")).maxY)
                                })
                        }.padding(18)
                    }.coordinateSpace(name: "popover-chat-scroll")
                    .simultaneousGesture(DragGesture(minimumDistance: 3).onChanged { value in
                        followsChatTail = ChatTailPolicy.shouldFollow(currentlyFollowing: followsChatTail, bottomIsVisible: false, userScrolledUp: abs(value.translation.height) > 3)
                    })
                    .background(ScrollWheelObserver { followsChatTail = false })
                    .onPreferenceChange(ChatTailPositionKey.self) { tailY in
                        let visible = tailY > 0 && tailY <= viewport.size.height + 8
                        followsChatTail = ChatTailPolicy.shouldFollow(currentlyFollowing: followsChatTail, bottomIsVisible: visible, userScrolledUp: false)
                    }
                    .onChange(of: store.messages.last?.content ?? "") { _, _ in scrollPopoverToBottom(proxy) }
                    .onChange(of: store.messages.count) { _, _ in scrollPopoverToBottom(proxy, force: true) }
                    .onChange(of: store.isSending) { _, sending in if sending { scrollPopoverToBottom(proxy, force: true) } }
                    .onChange(of: store.activeChatID) { _, _ in followsChatTail = true; scrollPopoverToBottom(proxy, force: true) }
                    .overlay(alignment: .bottomTrailing) {
                        if !followsChatTail {
                            Button { followsChatTail = true; proxy.scrollTo("bottom", anchor: .bottom) } label: { Image(systemName: "arrow.down") }
                                .help("Scroll to latest").accessibilityLabel("Scroll to latest")
                                .buttonStyle(.borderedProminent).help("Resume following new output").padding(10)
                        }
                    }
                }
                }
            }

            VStack(spacing: 8) {
                ChatAttachmentStrip()
                Capsule().fill(Color.secondary.opacity(0.45)).frame(width: 38, height: 4)
                    .contentShape(Rectangle().inset(by: -7))
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if composerDragStart == nil { composerDragStart = composerHeight }
                            composerUsesManualHeight = true
                            composerHeight = min(max((composerDragStart ?? composerHeight) - value.translation.height, 44), 150)
                        }
                        .onEnded { _ in composerDragStart = nil })
                    .onTapGesture(count: 2) {
                        composerUsesManualHeight = false
                        composerHeight = ChatComposerSizing.height(for: store.prompt, approximateCharactersPerLine: 48, maximum: 150)
                    }
                    .help("Drag to resize; double-click for automatic height")
                HStack(alignment: .bottom, spacing: 10) {
                    Button { chooseChatFiles() } label: { Image(systemName: "plus") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Attach files")
                        .accessibilityLabel("Attach files")
                    if store.webSearchEnabled { popoverWebSearchToggleButton }
                    TextField("Ask your local model", text: $store.prompt, axis: .vertical)
                        .textFieldStyle(.plain).lineLimit(2...8).frame(height: composerHeight, alignment: .top)
                        .onSubmit { submitPopoverPrompt() }
                    if store.isSending {
                        Button { store.cancelPrompt() } label: { Image(systemName: "stop.circle.fill").font(.title2) }
                        .help("Stop generating").accessibilityLabel("Stop generating")
                            .buttonStyle(.plain).help("Stop generating")
                    }
                    Button { submitPopoverPrompt() } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .help("Send message").accessibilityLabel("Send message")
                        .buttonStyle(.plain).disabled((store.prompt.isEmpty && store.pendingChatAttachments.isEmpty && store.pendingChatImageAttachments.isEmpty) || store.isSending || !store.isRunning)
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(isChatDropTargeted ? Color.accentColor : .clear, lineWidth: 2))
                .dropDestination(for: URL.self) { urls, _ in
                    store.attachChatFiles(urls)
                    return !urls.isEmpty
                } isTargeted: { isChatDropTargeted = $0 }
                .onPasteCommand(of: [.image]) { providers in pasteImages(providers) }
                Text("Responses are generated locally by \(store.profiles.first(where: { $0.id == store.runningProfileID })?.chatDisplayName ?? "llama-server").")
                    .font(.caption2).foregroundStyle(.tertiary)
            }.padding(14)
                .onChange(of: store.prompt) { _, value in
                    if !composerUsesManualHeight { composerHeight = ChatComposerSizing.height(for: value, approximateCharactersPerLine: 48, maximum: 150) }
                }
        }
        .frame(width: 560, height: 660)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func markdown(_ content: String) -> AttributedString {
        (try? AttributedString(markdown: content, options: .init(interpretedSyntax: .full))) ?? AttributedString(content)
    }

    private var popoverWebSearchToggleButton: some View {
        Button { store.webSearchEnabledThisChat.toggle() } label: { Image(systemName: store.webSearchEnabledThisChat ? "network" : "network.slash") }
            .buttonStyle(.plain)
            .foregroundStyle(store.webSearchEnabledThisChat ? Color.accentColor : .secondary)
            .help(store.webSearchEnabledThisChat ? "Web search is on for this chat — click to turn off" : "Web search is off for this chat — click to turn back on")
            .accessibilityLabel(store.webSearchEnabledThisChat ? "Turn off web search for this chat" : "Turn on web search for this chat")
    }

    // See PromptView.contextUsageBadge — same data, same thresholds,
    // just laid out for the popover's tighter header row.
    @ViewBuilder private var contextUsageBadge: some View {
        let health = store.runtimeHealth
        if health.contextLimit > 0 {
            HStack(spacing: 5) {
                Image(systemName: health.contextUsageLevel == .critical ? "exclamationmark.triangle.fill" : "chart.bar.fill")
                Text(health.contextFraction.formatted(.percent.precision(.fractionLength(0))))
            }
            .font(.caption).foregroundStyle(contextUsageTint(health.contextUsageLevel))
            .help("Context window: \(health.contextTokens.formatted()) / \(health.contextLimit.formatted()) tokens used")
        }
    }

    private func popoverEditingUserMessage(_ message: ChatMessage) -> some View {
        VStack(alignment: .trailing, spacing: 5) {
            TextField("Edit message", text: $messageEditDraft, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(1...8)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 18))
            HStack(spacing: 10) {
                Button("Cancel") { editingMessageID = nil }.buttonStyle(.plain).foregroundStyle(.secondary).font(.caption)
                Button("Resend") {
                    store.editAndResend(messageID: message.id, newText: messageEditDraft)
                    editingMessageID = nil
                }
                .buttonStyle(.borderedProminent).controlSize(.mini)
                .disabled(messageEditDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func submitPopoverPrompt() {
        guard (!store.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.pendingChatAttachments.isEmpty || !store.pendingChatImageAttachments.isEmpty), store.isRunning, !store.isSending else { return }
        followsChatTail = true
        store.beginSendingPrompt()
    }

    private func scrollPopoverToBottom(_ proxy: ScrollViewProxy, force: Bool = false) {
        guard force || followsChatTail else { return }
        if force { followsChatTail = true }
        DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
    }
}
