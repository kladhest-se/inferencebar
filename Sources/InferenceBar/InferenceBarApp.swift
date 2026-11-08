import AppKit
import SwiftUI

@main
struct InferenceBarApp: App {
    @NSApplicationDelegateAdaptor(InferenceBarDelegate.self) private var appDelegate
    // Every real window (Settings included) is opened and owned by
    // InferenceBarDelegate via makeWindow(...). The app runs as an
    // accessory (no Dock icon, no app menu bar) until a window is shown,
    // at which point show(_:) switches to .regular so the window behaves
    // like a normal app window — and that also makes the standard macOS
    // app menu bar appear, with its own default "About InferenceBar" and
    // "Settings…" items. Left alone those would open a generic About
    // panel and this scene's (empty) Settings window instead of the real
    // ones InferenceBarDelegate already owns, so both are redirected
    // below to call straight into the same openSettings()/showAbout()
    // the status bar menu uses, so every path to "About"/"Settings" ends
    // up at the same window. This Settings scene used to wrap a live
    // GlobalServerSettingsView bound to the same store — a second,
    // independent settings window that was never actually reachable
    // through the app's own UI but could still be created by anything
    // that ever asked AppKit to show it. App still requires a Scene, so
    // this stays as an inert placeholder; its own Settings… menu item is
    // redirected below rather than ever actually shown.
    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appInfo) {
                    Button("About InferenceBar") { appDelegate.showAbout() }
                }
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { appDelegate.openSettings() }
                        .keyboardShortcut(",", modifiers: .command)
                }
            }
    }
}

@MainActor
final class InferenceBarDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let store = AppStore.shared
    private var statusItem: NSStatusItem!
    private var profilesWindow: NSWindow?
    private var modelStoreWindow: NSWindow?
    private var downloadsWindow: NSWindow?
    private var chatWindow: NSWindow?
    private var logsWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private var lifecycleObserver: NSObjectProtocol?
    private var windowCloseObserver: NSObjectProtocol?
    private var appearanceObserver: NSObjectProtocol?
    private var hotkeySettingObserver: NSObjectProtocol?
    private var globalHotkeyMonitor: Any?
    private var localHotkeyMonitor: Any?
    private var strayWindowObserver: NSObjectProtocol?

    override init() {
        // Every real window is owned by this delegate (see makeWindow), so
        // there is nothing for AppKit/SwiftUI to restore. Left on, newer
        // macOS releases bring back the placeholder Settings scene's empty
        // window at launch.
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
        super.init()
    }

    // The App's `Settings { EmptyView() }` scene exists only because App
    // needs a Scene; its window is blank and must never be on screen.
    // The real settings window is `settingsWindow` (titled "Settings").
    private func closePlaceholderSettingsWindows() {
        for window in NSApp.windows where window !== settingsWindow {
            let identifier = window.identifier?.rawValue ?? ""
            if identifier.contains("SwiftUI_Settings") || window.title.hasSuffix(" Settings") {
                window.close()
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        closePlaceholderSettingsWindows()
        DispatchQueue.main.async { [weak self] in self?.closePlaceholderSettingsWindows() }
        strayWindowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.closePlaceholderSettingsWindows() }
        }
        lifecycleObserver = NotificationCenter.default.addObserver(forName: .inferenceServerLifecycleChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateStatusIcon() }
        }
        appearanceObserver = NotificationCenter.default.addObserver(forName: .inferenceAppearanceChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateStatusIcon() }
        }
        windowCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { self?.hideDockIconIfNoWindowsAreOpen() }
        }
        DispatchQueue.main.async { [weak self] in self?.store.startDefaultProfileIfEnabled() }
        store.startUpdateMonitoring()
        AppNotifications.requestAuthorizationIfNeeded()
        hotkeySettingObserver = NotificationCenter.default.addObserver(forName: .inferenceHotkeySettingChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateHotkeyMonitor() }
        }
        updateHotkeyMonitor()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.shutdownServerForAppTermination()
        store.stopUpdateMonitoring()
        if let lifecycleObserver { NotificationCenter.default.removeObserver(lifecycleObserver) }
        if let windowCloseObserver { NotificationCenter.default.removeObserver(windowCloseObserver) }
        if let strayWindowObserver { NotificationCenter.default.removeObserver(strayWindowObserver) }
        if let appearanceObserver { NotificationCenter.default.removeObserver(appearanceObserver) }
        if let hotkeySettingObserver { NotificationCenter.default.removeObserver(hotkeySettingObserver) }
        removeHotkeyMonitors()
        store.closeLogFile()
    }

    // The combo defaults to Option+Command+Space and is customizable from
    // Settings (see GlobalHotkey). NSEvent.addGlobalMonitor only delivers
    // keyDown events while the app isn't frontmost if InferenceBar is
    // trusted for Accessibility (System Settings > Privacy & Security >
    // Accessibility) — without that, this silently does nothing while
    // some other app is focused, which is why the settings toggle spells
    // that out rather than promising it will just work.
    //
    // No self, no actor-isolated state — reads GlobalHotkey's current
    // value straight off UserDefaults each time, safe to call
    // synchronously from either monitor's closure, which AppKit may
    // invoke off the isolation this class otherwise assumes.
    nonisolated private static func isHotkeyEvent(_ event: NSEvent) -> Bool {
        GlobalHotkey.matches(eventKeyCode: event.keyCode, eventModifierFlags: event.modifierFlags, keyCode: GlobalHotkey.keyCode, modifierFlags: GlobalHotkey.modifierFlags)
    }

    private func updateHotkeyMonitor() {
        removeHotkeyMonitors()
        guard store.globalHotkeyEnabled else { return }
        globalHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard Self.isHotkeyEvent(event) else { return }
            Task { @MainActor in self?.toggleChatWindow() }
        }
        localHotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard Self.isHotkeyEvent(event) else { return event }
            Task { @MainActor in self?.toggleChatWindow() }
            return nil
        }
    }

    private func removeHotkeyMonitors() {
        if let globalHotkeyMonitor { NSEvent.removeMonitor(globalHotkeyMonitor) }
        if let localHotkeyMonitor { NSEvent.removeMonitor(localHotkeyMonitor) }
        globalHotkeyMonitor = nil; localHotkeyMonitor = nil
    }

    private func toggleChatWindow() {
        if let chatWindow, chatWindow.isVisible {
            chatWindow.orderOut(nil)
            hideDockIconIfNoWindowsAreOpen()
        } else {
            openChat()
        }
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard statusItem.button != nil else { return }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let color: NSColor
        let status: String
        if store.isSending {
            status = store.engineActivity.label.isEmpty ? "working" : store.engineActivity.label.lowercased()
            color = activityColor(store.engineActivity)
        }
        else if store.serverLifecycle == .running && store.runtimeHealth.activeRequests > 0 {
            // Not InferenceBar's own chat (that's isSending above) --
            // some other client (the CLI tool, opencode, anything else
            // talking to the OpenAI-compatible endpoint) is mid-request.
            status = "handling an external request"
            color = .systemIndigo
        }
        else {
            (color, status) = switch store.serverLifecycle {
            case .stopped: (.secondaryLabelColor, "stopped")
            case .stopping: (.systemOrange, "stopping")
            case .starting: (.systemOrange, "starting")
            case .downloading: (.systemBlue, "downloading model")
            case .running: (.systemGreen, "running")
            case .failed: (.systemRed, "failed")
            }
        }
        button.image = statusImage(dotColor: color, description: "InferenceBar \(status)")
        button.contentTintColor = nil
        button.toolTip = "InferenceBar — \(store.serverLifecycle.label)"
    }

    private func statusImage(dotColor: NSColor, description: String) -> NSImage {
        let image = NSImage(size: StatusIconGeometry.size, flipped: false) { _ in
            let markColor: NSColor = switch self.store.menuBarIconStyle {
            case .matchSystem: .labelColor
            case .colour: self.store.appTheme.nsAccent
            case .monochrome: .white
            }

            // Symbols are drawn aspect-fit: NSImage.draw(in:) stretches to
            // fill the rect, which squashed the bubble slightly.
            func draw(_ symbol: NSImage?, fitting rect: NSRect) {
                guard let symbol, symbol.size.width > 0, symbol.size.height > 0 else { return }
                let scale = min(rect.width / symbol.size.width, rect.height / symbol.size.height)
                let fitted = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
                symbol.draw(in: NSRect(x: rect.midX - fitted.width / 2, y: rect.midY - fitted.height / 2, width: fitted.width, height: fitted.height))
            }

            // A dot with a transparent ring cut out around it, so it stays
            // legible over the bubble on any menu-bar colour. (It used to be
            // ringed with controlBackgroundColor, which showed up as a dark
            // halo on a coloured menu bar.)
            func drawBadge(_ rect: NSRect, color: NSColor) {
                if let context = NSGraphicsContext.current {
                    context.saveGraphicsState()
                    context.compositingOperation = .clear
                    NSBezierPath(ovalIn: StatusIconGeometry.ring(around: rect)).fill()
                    context.restoreGraphicsState()
                }
                color.setFill()
                NSBezierPath(ovalIn: rect).fill()
            }

            let bubble = NSImage(systemSymbolName: "bubble.left.fill", accessibilityDescription: description)?
                .withSymbolConfiguration(.init(pointSize: 17, weight: .semibold).applying(.init(paletteColors: [markColor])))
            draw(bubble, fitting: StatusIconGeometry.bubble)
            let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: description)?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .bold).applying(.init(paletteColors: [self.store.menuBarIconStyle == .colour ? .white : NSColor.windowBackgroundColor])))
            draw(bolt, fitting: StatusIconGeometry.bolt)

            drawBadge(StatusIconGeometry.statusDot, color: dotColor)
            if self.store.availableUpdateTag != nil {
                drawBadge(StatusIconGeometry.updateDot, color: .systemOrange)
                let arrow = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: "InferenceBar update available")?
                    .withSymbolConfiguration(.init(pointSize: 5, weight: .heavy).applying(.init(paletteColors: [.white])))
                draw(arrow, fitting: StatusIconGeometry.updateDot.insetBy(dx: 1.5, dy: 1.5))
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = description
        return image
    }


    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if let tag = store.availableUpdateTag {
            let update = menuItem("Update available: \(tag)", action: #selector(openAvailableUpdate), systemImage: "arrow.down.circle.fill")
            update.representedObject = tag
            menu.addItem(update)
            menu.addItem(.separator())
        }
        // Only the currently selected profile in Profiles' own editor shows
        // this otherwise -- navigate to a different profile (or close the
        // window) and it's invisible until you click back. Reading it here
        // instead means it survives that, the same way the status-icon's
        // external-request indicator already doesn't depend on any one
        // window being open.
        if store.isDownloading || store.isResolvingDownload {
            let title = DownloadMenuBarPresentation.summary(
                modelName: store.downloadModelName,
                isResolving: store.isResolvingDownload,
                status: store.downloadStatus,
                progress: store.downloadProgress,
                totalBytes: store.downloadTotalBytes,
                bytesPerSecond: store.downloadBytesPerSecond
            )
            let downloading = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            downloading.image = menuImage("arrow.down.circle", description: "Downloading model")
            downloading.isEnabled = false
            menu.addItem(downloading)
            if store.queuedPresetDownloadCount > 0 {
                let queued = NSMenuItem(title: "\(store.queuedPresetDownloadCount) more queued", action: nil, keyEquivalent: "")
                queued.isEnabled = false
                menu.addItem(queued)
            }
            menu.addItem(.separator())
        }
        if MenuBarLifecyclePresentation.locksProfileSelection(store.serverLifecycle),
           let running = store.profiles.first(where: { $0.id == store.runningProfileID }) {
            let title = MenuBarLifecyclePresentation.profileTitle(name: running.name, lifecycle: store.serverLifecycle, activity: store.engineActivity, isSending: store.isSending)
            let profileName = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            profileName.image = menuImage(store.serverLifecycle == .stopping ? "hourglass" : "cpu", description: store.serverLifecycle.label)
            profileName.isEnabled = false
            menu.addItem(profileName)
            let engine = NSMenuItem(title: "Engine: \(running.runtime.title)", action: nil, keyEquivalent: "")
            engine.image = menuImage("gearshape.2", description: "Inference engine")
            engine.isEnabled = false
            menu.addItem(engine)
            if let externalLabel = MenuBarLifecyclePresentation.externalRequestLabel(lifecycle: store.serverLifecycle, isSending: store.isSending, activeRequests: store.runtimeHealth.activeRequests) {
                let external = NSMenuItem(title: externalLabel, action: nil, keyEquivalent: "")
                external.image = menuImage("network", description: "External request active")
                external.isEnabled = false
                menu.addItem(external)
            }
            menu.addItem(.separator())
            if store.serverLifecycle == .stopping {
                let stopping = NSMenuItem(title: "Stopping model…", action: nil, keyEquivalent: "")
                stopping.image = menuImage("hourglass", description: "Stopping model")
                stopping.isEnabled = false
                menu.addItem(stopping)
            } else if store.serverLifecycle == .running {
                menu.addItem(menuItem("Stop running model", action: #selector(stopServer), systemImage: "stop.circle"))
            } else {
                let progress = NSMenuItem(title: store.serverLifecycle.label, action: nil, keyEquivalent: "")
                progress.isEnabled = false
                menu.addItem(progress)
            }
        } else {
            let startItem = NSMenuItem(title: "Profiles", action: nil, keyEquivalent: "")
            startItem.image = menuImage("list.bullet.rectangle", description: "Profiles")
            let profileMenu = NSMenu()
            let favoriteItem = NSMenuItem(title: "Favorite Profiles", action: nil, keyEquivalent: "")
            favoriteItem.image = menuImage("star.fill", description: "Favorite profiles")
            let favorites = NSMenu()
            if store.favoriteProfiles.isEmpty {
                let empty = NSMenuItem(title: "No favorite profiles", action: nil, keyEquivalent: "")
                empty.image = menuImage("star.slash", description: "No favorite profiles")
                empty.isEnabled = false
                favorites.addItem(empty)
            } else {
                for profile in store.favoriteProfiles {
                    let profileItem = menuItem(profile.name, action: #selector(startFavorite(_:)), systemImage: "bolt.circle")
                    profileItem.representedObject = profile.id.uuidString
                    favorites.addItem(profileItem)
                }
            }
            favoriteItem.submenu = favorites
            profileMenu.addItem(favoriteItem)

            let downloadedItem = NSMenuItem(title: "All Profiles", action: nil, keyEquivalent: "")
            downloadedItem.image = menuImage("arrow.down.circle.fill", description: "Downloaded profiles")
            let downloaded = NSMenu()
            if store.downloadedProfiles.isEmpty {
                let empty = NSMenuItem(title: "No downloaded profile models", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                downloaded.addItem(empty)
            } else {
                for profile in store.downloadedProfiles {
                    let profileItem = menuItem(profile.name, action: #selector(startFavorite(_:)), systemImage: "play.circle")
                    profileItem.representedObject = profile.id.uuidString
                    downloaded.addItem(profileItem)
                }
            }
            downloadedItem.submenu = downloaded
            profileMenu.addItem(downloadedItem)
            startItem.submenu = profileMenu
            menu.addItem(startItem)
        }
        menu.addItem(.separator())
        menu.addItem(menuItem("Chat", action: #selector(openChat), systemImage: "bubble.left.and.bubble.right"))
        let manageItem = NSMenuItem(title: "Manage", action: nil, keyEquivalent: "")
        manageItem.image = menuImage("slider.horizontal.3", description: "Manage")
        let manageMenu = NSMenu()
        manageMenu.addItem(menuItem("Profiles", action: #selector(openProfiles), systemImage: "person.crop.rectangle.stack"))
        manageMenu.addItem(menuItem("Models", action: #selector(openModels), systemImage: "shippingbox"))
        let downloadsMenuItem = menuItem("Downloads", action: #selector(openDownloads), systemImage: "arrow.down.circle")
        if !store.downloadJobs.isEmpty { downloadsMenuItem.title = "Downloads (\(store.downloadJobs.count))" }
        manageMenu.addItem(downloadsMenuItem)
        manageItem.submenu = manageMenu
        menu.addItem(manageItem)
        menu.addItem(menuItem("Logs", action: #selector(openLogs), systemImage: "doc.text.magnifyingglass"))
        menu.addItem(menuItem("Settings", action: #selector(openSettings), systemImage: "gearshape"))
        menu.addItem(.separator())
        menu.addItem(menuItem("About", action: #selector(showAbout), systemImage: "info.circle"))
        menu.addItem(menuItem("Quit App", action: #selector(quitApp), key: "q", systemImage: "power"))
    }

    private func menuItem(_ title: String, action: Selector, key: String = "", systemImage: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.image = menuImage(systemImage, description: title)
        return item
    }

    private func menuImage(_ name: String, description: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: description)
    }

    private func activityColor(_ activity: EngineActivity) -> NSColor {
        switch activity {
        case .thinking: .systemIndigo
        case .reasoning: .systemPurple
        case .searching: .systemTeal
        case .browsing: .systemBlue
        case .executingCode: .systemOrange
        case .toolCalling: .systemPink
        case .functionCalling: .systemMint
        case .compacting: .systemBrown
        case .summarizing: .systemYellow
        case .generating: .systemCyan
        case .streaming: .systemGreen
        case .idle: .secondaryLabelColor
        }
    }

    private func makeWindow<Content: View>(root: Content, title: String, size: NSSize, minimum: NSSize) -> NSWindow {
        let themedRoot = ThemedRoot(content: root).environment(store)
        let hostingController = NSHostingController(rootView: themedRoot)
        // NSHostingController's default sizingOptions tracks the SwiftUI
        // content's own ideal size as the window's max (and min) size, and
        // will silently shrink or grow the window to match whenever that
        // ideal size changes later — e.g. the Profiles window collapsing
        // once the last profile is deleted and its detail pane becomes a
        // bare, non-expanding "Select a profile" placeholder instead of a
        // full profile editor Form. Every window's size is explicitly
        // managed below via contentMinSize/setContentSize instead, so
        // this auto-tracking is never wanted once the window is open.
        hostingController.sizingOptions = []
        let window = NSWindow(contentViewController: hostingController)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.contentMinSize = minimum
        window.setContentSize(NSSize(width: max(size.width, minimum.width), height: max(size.height, minimum.height)))
        window.minSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: minimum)).size
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    private func show(_ window: NSWindow?) {
        NSApp.setActivationPolicy(.regular)
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.hideDockIconIfNoWindowsAreOpen() }
    }

    private func hideDockIconIfNoWindowsAreOpen() {
        let visibleAppWindow = NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
        if !visibleAppWindow { NSApp.setActivationPolicy(.accessory) }
    }

    @objc private func openProfiles() {
        if profilesWindow == nil { profilesWindow = makeWindow(root: ProfilesView().environment(store), title: "Profile Management", size: NSSize(width: 1060, height: 760), minimum: NSSize(width: 760, height: 560)) }
        profilesWindow?.contentMinSize = NSSize(width: 760, height: 560)
        if let window = profilesWindow, window.contentLayoutRect.width < 760 || window.contentLayoutRect.height < 560 {
            window.setContentSize(NSSize(width: max(window.contentLayoutRect.width, 760), height: max(window.contentLayoutRect.height, 560)))
        }
        show(profilesWindow)
    }
    @objc private func openModels() {
        if modelStoreWindow == nil { modelStoreWindow = makeWindow(root: ModelStoreWindowView().environment(store), title: "Model Store", size: NSSize(width: 1240, height: 800), minimum: NSSize(width: 880, height: 600)) }
        show(modelStoreWindow)
    }
    @objc private func openDownloads() {
        // The list pane and detail pane inside DownloadsView's HSplitView
        // declare minWidths of 430 and 310 (see ContentView.swift) -- the
        // window's own minimum must be at least that combined width plus
        // the split divider, or SwiftUI can't satisfy both panes' minimums
        // at once and the layout visibly breaks down (overlapping/garbled
        // text) as the window is resized down toward it.
        if downloadsWindow == nil { downloadsWindow = makeWindow(root: DownloadsView().environment(store), title: "Downloads", size: NSSize(width: 900, height: 580), minimum: NSSize(width: 780, height: 460)) }
        show(downloadsWindow)
    }
    @objc private func openChat() {
        if chatWindow == nil { chatWindow = makeWindow(root: PromptView().environment(store), title: "Chat", size: NSSize(width: 780, height: 720), minimum: NSSize(width: 520, height: 460)) }
        show(chatWindow)
    }
    @objc private func openLogs() {
        if logsWindow == nil { logsWindow = makeWindow(root: LogsView().environment(store), title: "Logs", size: NSSize(width: 980, height: 680), minimum: NSSize(width: 620, height: 420)) }
        show(logsWindow)
    }
    @objc func openSettings() {
        if settingsWindow == nil { settingsWindow = makeWindow(root: GlobalServerSettingsView().environment(store), title: "Settings", size: NSSize(width: 900, height: 720), minimum: NSSize(width: 650, height: 520)) }
        show(settingsWindow)
    }
    @objc func showAbout() {
        if aboutWindow == nil { aboutWindow = makeWindow(root: AboutInferenceBarView(), title: "About InferenceBar", size: NSSize(width: 500, height: 430), minimum: NSSize(width: 460, height: 390)) }
        show(aboutWindow)
    }
    @objc private func openAvailableUpdate(_ sender: NSMenuItem) {
        // The release page (notes + downloadable build), not the source
        // tree at that tag — this is meant to help someone actually get
        // the update, not go read code.
        let tag = (sender.representedObject as? String) ?? ""
        let encoded = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tag
        NSWorkspace.shared.open(URL(string: "https://github.com/kladhest-se/inferencebar/releases/tag/\(encoded)")!)
    }
    @objc private func stopServer() { store.stop() }
    @objc private func quitApp() { NSApp.terminate(nil) }
    @objc private func startFavorite(_ sender: NSMenuItem) {
        guard store.canStartProfile, let value = sender.representedObject as? String, let id = UUID(uuidString: value) else { return }
        store.selectedProfileID = id
        store.start()
    }

}
