import AppKit
import SwiftUI
import ApplicationServices
import KeyVCore
import Carbon.HIToolbox

/// App entry: accessory (menu-bar-only) app bundling the engine, tap,
/// CaptureService, overlay picker, settings window, global hotkey, updater.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    static let overlayPanelIdentifier = "KeyVOverlayPanel"

    private var engine: ViEngine!
    private var tap: TapController!
    private var capture: ClipboardCaptureService!

    private var statusItem: NSStatusItem!
    private var typingMenuItem: NSMenuItem?
    private var updateMenuItem: NSMenuItem?
    private var mainUpdateMenuItem: NSMenuItem?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var accessibilityPoller: Timer?
    private let overlayPanel = OverlayPickerPanel()
    private var overlayHotKeyRef: EventHotKeyRef?
    private var toggleHotKeyRef: EventHotKeyRef?
    private var hotKeyEventHandler: EventHandlerRef?
    private var hotKeyInstalledEventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                                         eventKind: UInt32(kEventHotKeyPressed))

    public func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = AppSettings.shared
        let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let effective = settings.effectiveFor(bundleID: frontBundle)
        engine = ViEngine(method: effective.method,
                          orthography: effective.orthography,
                          macroEnabled: settings.macroEnabled,
                          allowWAsConsonant: settings.allowWAsConsonant)
        engine.setOptions(autoCapitalize: settings.autoCapitalize,
                          repeatedRestore: settings.repeatedRestore,
                          spellCheck: settings.spellCheck)

        capture = ClipboardCaptureService()
        capture.start()

        setupStatusItem()
        installGlobalHotKeys()

        settings.onChange(target: self, selector: #selector(engineSettingsChanged(_:)))
        NotificationCenter.default.addObserver(
            self, selector: #selector(macroFileReloaded),
            name: Notification.Name("KeyVSavedMacroFile"), object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(updateStateChanged),
            name: Notification.Name("KeyVUpdateStateChanged"), object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)

        loadMacroFile()
        UpdateService.shared.startAutomaticChecks()

        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollAccessibility() }
        }
        RunLoop.main.add(timer, forMode: .common)
        accessibilityPoller = timer
        pollAccessibility()
        if tap == nil { showOnboarding() }
    }

    /// Finder/`open` re-launching the already-running app: make something
    /// visible immediately instead of a silent no-op.
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if tap == nil {
            showOnboarding()
        } else {
            showSettings()
        }
        return true
    }

    public func applicationWillTerminate(_ notification: Notification) {
        accessibilityPoller?.invalidate()
        UpdateService.shared.stopAutomaticChecks()
        tap?.uninstall()
        capture?.stop()
    }

    // MARK: - Accessibility gate + onboarding

    private static let trustedCheckOptions: [String: Bool] =
        [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]

    static func isAccessibilityGranted() -> Bool {
        AXIsProcessTrustedWithOptions(Self.trustedCheckOptions as CFDictionary)
    }

    private func installTypingPipeline() {
        guard tap == nil else { return }
        let candidate = TapController(engine: engine, injector: EventInjector())
        candidate.onModeToggleShortcut = { [weak self] in
            Task { @MainActor in
                self?.toggleTyping()
            }
        }
        guard candidate.install() else {
            PermissionModel.shared.status = .hookUnavailable
            return
        }
        tap = candidate
        PermissionModel.shared.status = .ready
        onboardingWindow?.close()
        onboardingWindow = nil
        NSApp.setActivationPolicy(.accessory)
        NSLog("[KeyV] typing pipeline installed")
    }

    private func showOnboarding() {
        NSApp.setActivationPolicy(.regular)

        if onboardingWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 540),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false)
            window.title = "KeyV"
            window.contentView = NSHostingView(rootView: OnboardingView(checkAgain: { [weak self] in self?.pollAccessibility() }))
            window.center()
            window.isReleasedWhenClosed = false
            onboardingWindow = window
        }
        onboardingWindow?.makeKeyAndOrderFront(nil)
        onboardingWindow?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func pollAccessibility() {
        guard engine != nil else { return }
        guard Self.isAccessibilityGranted() else {
            tap?.uninstall()
            tap = nil
            PermissionModel.shared.status = .permissionRequired
            refreshMenuBar()
            return
        }
        installTypingPipeline()
        refreshMenuBar()
    }

    public func applicationDidBecomeActive(_ notification: Notification) {
        pollAccessibility()
    }

    // MARK: - Status item menu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let button = statusItem.button
        button?.font = .systemFont(ofSize: 14, weight: .bold)
        button?.title = menuBarLetter()

        let menu = NSMenu()
        menu.delegate = self

        let typingItem = NSMenuItem(
            title: typingStatusTitle(),
            action: #selector(toggleTyping), keyEquivalent: "")
        typingItem.target = self
        typingMenuItem = typingItem
        menu.addItem(typingItem)
        menu.addItem(.separator())

        let overlay = NSMenuItem(title: "Lịch sử clipboard…", action: #selector(showOverlay), keyEquivalent: "")
        overlay.target = self
        menu.addItem(overlay)

        let settings = NSMenuItem(title: "Cài đặt…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let checkUpdates = NSMenuItem(title: updateMenuTitle(), action: #selector(checkForUpdates), keyEquivalent: "")
        checkUpdates.target = self
        updateMenuItem = checkUpdates
        menu.addItem(checkUpdates)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Thoát KeyV", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu

        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "KeyV")
        let preferences = NSMenuItem(title: "Cài đặt…", action: #selector(showSettings), keyEquivalent: ",")
        preferences.target = self
        appMenu.addItem(preferences)
        let mainCheckUpdates = NSMenuItem(title: updateMenuTitle(), action: #selector(checkForUpdates), keyEquivalent: "")
        mainCheckUpdates.target = self
        mainUpdateMenuItem = mainCheckUpdates
        appMenu.addItem(mainCheckUpdates)
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "Thoát KeyV", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        appMenu.addItem(quit)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        NSApp.mainMenu = mainMenu
    }

    private func updateMenuTitle() -> String {
        if let avail = UpdateService.shared.availableUpdate {
            return "Có bản cập nhật mới (v\(avail.version.description))…"
        }
        return "Kiểm tra cập nhật…"
    }

    private func typingStatusTitle() -> String {
        let current = AppSettings.shared.effectiveFor(bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        guard tap != nil else { return "Bộ gõ chưa sẵn sàng — mở lại KeyV để kiểm tra" }
        return current.method == .off ? "Chế độ: English" : "Chế độ: Tiếng Việt"
    }

    private func menuBarLetter() -> String {
        let current = AppSettings.shared.effectiveFor(bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        guard tap != nil else { return "!" }
        return current.method == .off ? "E" : "V"
    }

    private func refreshMenuBar() {
        statusItem?.button?.title = menuBarLetter()
        typingMenuItem?.title = typingStatusTitle()
        updateMenuItem?.title = updateMenuTitle()
        mainUpdateMenuItem?.title = updateMenuTitle()
    }

    @objc private func updateStateChanged() {
        refreshMenuBar()
    }

    @objc fileprivate func toggleTyping() {
        guard tap != nil else { showOnboarding(); return }
        let settings = AppSettings.shared
        let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let frontBundle, var override = settings.appOverridesJSON[frontBundle], override.useMode != nil {
            let nextMode: ViInputMethod = override.useMode == .off ? settings.lastVietnameseMethod : .off
            override.useModeRaw = nextMode.rawValue
            var all = settings.appOverridesJSON
            all[frontBundle] = override
            settings.appOverridesJSON = all
        } else if settings.method == .off {
            settings.method = settings.lastVietnameseMethod
        } else {
            settings.lastVietnameseMethod = settings.method
            settings.method = .off
        }
        if settings.beepOnModeSwitch {
            NSSound.beep()
        }
    }

    @objc private func showOverlay() {
        overlayPanel.toggleNearFrontmost()
    }

    @objc private func checkForUpdates() {
        UpdateService.shared.showUpdateWindowAndCheck()
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 680, height: 640),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false)
            window.title = "Cài đặt KeyV"
            window.isReleasedWhenClosed = false
            window.center()
            window.contentView = NSHostingView(rootView: SettingsRootView())
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Settings / profiles

    @objc private func engineSettingsChanged(_ note: Notification) {
        let settings = AppSettings.shared
        let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let effective = settings.effectiveFor(bundleID: frontBundle)
        engine = ViEngine(method: effective.method, orthography: effective.orthography,
                          macroEnabled: settings.macroEnabled, allowWAsConsonant: settings.allowWAsConsonant)
        engine.setOptions(autoCapitalize: settings.autoCapitalize,
                          repeatedRestore: settings.repeatedRestore,
                          spellCheck: settings.spellCheck)
        loadMacroFile()
        tap?.engine = engine
        refreshMenuBar()
        reRegisterGlobalHotKeys()
    }

    @objc private func appActivated(_ note: Notification) {
        SelectionCacheService.shared.invalidate()

        let front = NSWorkspace.shared.frontmostApplication
        tap?.activeBundleID = front?.bundleIdentifier
        tap?.activePID = front?.processIdentifier ?? 0

        if let front, front.bundleIdentifier != Bundle.main.bundleIdentifier {
            let name = front.localizedName ?? front.bundleIdentifier ?? "?"
            AppSettings.shared.noteSeenApp(bundleID: front.bundleIdentifier ?? "?", name: name)
        }

        let bundleID = front?.bundleIdentifier
        let effective = AppSettings.shared.effectiveFor(bundleID: bundleID)
        engine.setMethod(effective.method)
        engine.setOrthography(effective.orthography)
        refreshMenuBar()
    }

    // MARK: - Macros (gõ tắt)

    @objc private func macroFileReloaded() {
        engineSettingsChanged(Notification(name: Notification.Name("KeyVSavedMacroFile")))
    }

    private func loadMacroFile() {
        let url = ClipboardStore.dataDir().appendingPathComponent("macros.tsv")
        guard AppSettings.shared.macroEnabled else { return }
        let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? "hvbt\tNhé bạn\n"
        for line in raw.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            engine.setMacro(String(parts[0]), value: String(parts[1]))
        }
    }

    // MARK: - Global hotkeys (Carbon)

    private func installGlobalHotKeys() {
        guard
            InstallEventHandler(
                GetApplicationEventTarget(),
                hotKeyEventReducer,
                1,
                &hotKeyInstalledEventType,
                Unmanaged.passRetained(self).toOpaque(),
                &hotKeyEventHandler) == noErr
        else {
            NSLog("[KeyV] InstallEventHandler failed for hotkey")
            return
        }
        reRegisterGlobalHotKeys()
    }

    private func reRegisterGlobalHotKeys() {
        if let ref = overlayHotKeyRef {
            UnregisterEventHotKey(ref)
            overlayHotKeyRef = nil
        }
        if let ref = toggleHotKeyRef {
            UnregisterEventHotKey(ref)
            toggleHotKeyRef = nil
        }
        let settings = AppSettings.shared
        let overlayID = EventHotKeyID(signature: OSType(0x4B655944), id: 1)
        _ = RegisterEventHotKey(UInt32(settings.overlayHotKeyCode),
                                UInt32(settings.overlayHotKeyModifiers),
                                overlayID,
                                GetApplicationEventTarget(),
                                0,
                                &overlayHotKeyRef)

        let toggleID = EventHotKeyID(signature: OSType(0x4B655944), id: 2)
        _ = RegisterEventHotKey(UInt32(settings.toggleHotKeyCode),
                                UInt32(settings.toggleHotKeyModifiers),
                                toggleID,
                                GetApplicationEventTarget(),
                                0,
                                &toggleHotKeyRef)
    }

    fileprivate func toggleOverlay() {
        overlayPanel.toggleNearFrontmost()
    }
}

extension AppDelegate: NSMenuDelegate {
    public func menuNeedsUpdate(_ menu: NSMenu) {
        refreshMenuBar()
    }
}

private func hotKeyEventReducer(_ call: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return noErr }
    let appDelegate = Unmanaged<AppDelegate>.fromOpaque(userData!).takeUnretainedValue()
    var hotKeyPointerId = EventHotKeyID()
    guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                            nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyPointerId) == noErr else {
        return noErr
    }
    let id = hotKeyPointerId.id
    DispatchQueue.main.async {
        if id == 1 {
            appDelegate.toggleOverlay()
        } else if id == 2 {
            appDelegate.toggleTyping()
        }
    }
    return noErr
}
