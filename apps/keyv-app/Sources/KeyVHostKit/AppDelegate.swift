import AppKit
import SwiftUI
import ApplicationServices
import KeyVCore
import Carbon.HIToolbox

@MainActor
public final class WindowFocusCoordinator: NSObject {
    public static let shared = WindowFocusCoordinator()

    public var canRestoreAccessoryPolicy: () -> Bool = { true }
    private let trackedWindows = NSHashTable<NSWindow>.weakObjects()
    private var observedWindowIDs: Set<ObjectIdentifier> = []

    public func present(_ window: NSWindow) {
        registerIfNeeded(window)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    public func registerIfNeeded(_ window: NSWindow) {
        trackedWindows.add(window)
        let id = ObjectIdentifier(window)
        guard !observedWindowIDs.contains(id) else { return }
        observedWindowIDs.insert(id)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )
    }

    @objc private func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        reconcileActivationPolicy(excluding: closing)
    }

    public func reconcileActivationPolicy(excluding closingWindow: NSWindow? = nil) {
        let hasVisibleWindow = trackedWindows.allObjects.contains { candidate in
            candidate !== closingWindow && candidate.isVisible
        }
        if !hasVisibleWindow && canRestoreAccessoryPolicy() {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

/// App entry: accessory (menu-bar-only) app bundling the engine, tap,
/// CaptureService, overlay picker, settings window, global hotkey, updater.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    static let overlayPanelIdentifier = "KeyVOverlayPanel"

    private var engine: ViEngine!
    private var tap: TapController!
    private var capture: ClipboardCaptureService!
    private var activeBundleID: String?
    private var activePID: pid_t = 0
    private var macrosLoaded = false
    private var installedOverlayHotKeyCode: Int?
    private var installedOverlayHotKeyModifiers: UInt?
    private var installedToggleHotKeyCode: Int?
    private var installedToggleHotKeyModifiers: UInt?

    private var statusItem: NSStatusItem!
    private var typingMenuItem: NSMenuItem?
    private var remoteMenuItem: NSMenuItem?
    private var remoteModeItems: [RemoteDesktopMode: NSMenuItem] = [:]
    private var overlayMenuItem: NSMenuItem?
    private var settingsMenuItem: NSMenuItem?
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
        WindowFocusCoordinator.shared.canRestoreAccessoryPolicy = { [weak self] in
            self?.tap != nil
        }
        NSApp.setActivationPolicy(.accessory)
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.disableAutomaticTermination("KeyV EventTap")
        let settings = AppSettings.shared
        if Bundle.main.bundleIdentifier == "app.keyv.host" {
            settings.migrateLegacyDefaultsIfNeeded()
        }
        let front = NSWorkspace.shared.frontmostApplication
        activeBundleID = front?.bundleIdentifier
        activePID = front?.processIdentifier ?? 0
        let effective = settings.effectiveFor(bundleID: activeBundleID)
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
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(workspaceAppsChanged(_:)),
            name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(workspaceAppsChanged(_:)),
            name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        RemoteInputDetector.shared.refreshRunningServersAsync { [weak self] _ in
            self?.refreshMenuBar()
        }
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
        candidate.activeBundleID = activeBundleID
        candidate.activePID = activePID
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
        let closingOnboarding = onboardingWindow
        onboardingWindow?.close()
        onboardingWindow = nil
        WindowFocusCoordinator.shared.reconcileActivationPolicy(excluding: closingOnboarding)
        NSLog("[KeyV] typing pipeline installed")
    }

    private func showOnboarding() {
        if onboardingWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 540, height: 560),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false)
            window.title = "Thiết lập KeyV"
            window.contentView = NSHostingView(rootView: OnboardingView(checkAgain: { [weak self] in self?.pollAccessibility() }))
            window.center()
            window.isReleasedWhenClosed = false
            onboardingWindow = window
        }
        if let onboardingWindow {
            WindowFocusCoordinator.shared.present(onboardingWindow)
        }
    }

    @objc private func pollAccessibility() {
        guard engine != nil else { return }
        guard Self.isAccessibilityGranted() else {
            let hadTap = (tap != nil)
            tap?.uninstall()
            tap = nil
            if PermissionModel.shared.status != .permissionRequired || hadTap {
                PermissionModel.shared.status = .permissionRequired
                refreshMenuBar()
            }
            return
        }
        if tap == nil {
            installTypingPipeline()
            refreshMenuBar()
        } else {
            tap?.refreshSecureInputState()
        }
    }

    @objc private func workspaceAppsChanged(_ note: Notification) {
        RemoteInputDetector.shared.invalidateAll()
        RemoteInputDetector.shared.refreshRunningServersAsync { [weak self] _ in
            self?.refreshMenuBar()
        }
    }

    public func applicationDidBecomeActive(_ notification: Notification) {
        pollAccessibility()
    }

    // MARK: - Status item menu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.delegate = self

        let typingItem = NSMenuItem(
            title: typingStatusTitle(),
            action: #selector(toggleTyping),
            keyEquivalent: ""
        )
        typingItem.target = self
        typingMenuItem = typingItem
        menu.addItem(typingItem)

        let remoteItem = NSMenuItem(title: "Nhập liệu từ xa", action: nil, keyEquivalent: "")
        remoteItem.image = NSImage(
            systemSymbolName: "iphone.radiowaves.left.and.right",
            accessibilityDescription: "Nhập liệu từ xa"
        )
        let remoteSubmenu = NSMenu(title: "Nhập liệu từ xa")
        for mode in RemoteDesktopMode.allCases {
            let modeItem = NSMenuItem(
                title: mode.menuTitle,
                action: #selector(selectRemoteDesktopMode(_:)),
                keyEquivalent: ""
            )
            modeItem.target = self
            modeItem.tag = mode.rawValue
            remoteModeItems[mode] = modeItem
            remoteSubmenu.addItem(modeItem)
        }
        remoteSubmenu.addItem(.separator())
        let openRemoteSettingsItem = NSMenuItem(
            title: "Tùy chỉnh trong Cài đặt Hệ thống…",
            action: #selector(showSystemSettings),
            keyEquivalent: ""
        )
        openRemoteSettingsItem.target = self
        remoteSubmenu.addItem(openRemoteSettingsItem)
        remoteItem.submenu = remoteSubmenu
        remoteMenuItem = remoteItem
        menu.addItem(remoteItem)
        menu.addItem(.separator())

        let overlay = NSMenuItem(title: "Lịch sử clipboard…", action: #selector(showOverlay), keyEquivalent: "")
        overlay.target = self
        overlay.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Lịch sử clipboard")
        overlayMenuItem = overlay
        menu.addItem(overlay)

        let settings = NSMenuItem(title: "Cài đặt…", action: #selector(showSettings), keyEquivalent: ",")
        settings.keyEquivalentModifierMask = [.command]
        settings.target = self
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Cài đặt")
        settingsMenuItem = settings
        menu.addItem(settings)

        let checkUpdates = NSMenuItem(title: updateMenuTitle(), action: #selector(checkForUpdates), keyEquivalent: "")
        checkUpdates.target = self
        updateMenuItem = checkUpdates
        menu.addItem(checkUpdates)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Thoát KeyV", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: "Thoát KeyV")
        menu.addItem(quitItem)

        statusItem.menu = menu

        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "KeyV")
        let preferences = NSMenuItem(title: "Cài đặt…", action: #selector(showSettings), keyEquivalent: ",")
        preferences.keyEquivalentModifierMask = [.command]
        preferences.target = self
        preferences.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        appMenu.addItem(preferences)
        let mainCheckUpdates = NSMenuItem(title: updateMenuTitle(), action: #selector(checkForUpdates), keyEquivalent: "")
        mainCheckUpdates.target = self
        mainUpdateMenuItem = mainCheckUpdates
        appMenu.addItem(mainCheckUpdates)
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "Thoát KeyV", action: #selector(quitApp), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = [.command]
        quit.target = self
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        appMenu.addItem(quit)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        NSApp.mainMenu = mainMenu

        refreshMenuBar()
    }

    private func updateMenuTitle() -> String {
        if let avail = UpdateService.shared.availableUpdate {
            return "Có bản cập nhật mới (v\(avail.version.description))…"
        }
        return "Kiểm tra cập nhật…"
    }

    private func methodDisplayName(_ method: ViInputMethod) -> String {
        switch method {
        case .telex: return "Telex"
        case .simpleTelex: return "Simple Telex"
        case .vni: return "VNI"
        case .off: return "English"
        }
    }

    private func typingStatusTitle() -> String {
        let current = AppSettings.shared.effectiveFor(bundleID: activeBundleID)
        guard tap != nil else { return "Chế độ: Chưa cấp quyền Trợ năng…" }
        if current.method == .off {
            return "Chế độ: English"
        }
        return "Chế độ: Tiếng Việt · \(methodDisplayName(current.method))"
    }

    private func menuBarLetter() -> String {
        let current = AppSettings.shared.effectiveFor(bundleID: activeBundleID)
        guard tap != nil else { return "!" }
        return current.method == .off ? "E" : "V"
    }

    private func makeStatusBarBadge(letter: String, isVietnamese: Bool, isWarning: Bool, hasUpdate: Bool) -> NSImage {
        let width: CGFloat = hasUpdate ? 26 : 23
        let height: CGFloat = 18
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            let pillRect = NSRect(x: 1.5, y: 2.0, width: 20.0, height: 14.0)
            let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: 4.2, yRadius: 4.2)
            let useTemplateColors = !isWarning && !hasUpdate
            let baseColor: NSColor = isWarning
                ? .systemOrange
                : (useTemplateColors ? .black : .labelColor)

            let font = NSFont.systemFont(ofSize: 10.5, weight: .heavy)
            let style = NSMutableParagraphStyle()
            style.alignment = .center

            if isVietnamese && !isWarning {
                baseColor.setFill()
                pillPath.fill()
                if let ctx = NSGraphicsContext.current?.cgContext {
                    ctx.saveGState()
                    ctx.setBlendMode(.clear)
                    let attr = NSAttributedString(
                        string: letter,
                        attributes: [
                            .font: font,
                            .foregroundColor: NSColor.black,
                            .paragraphStyle: style,
                        ]
                    )
                    let textSize = attr.size()
                    let textRect = NSRect(
                        x: pillRect.midX - textSize.width / 2,
                        y: pillRect.midY - textSize.height / 2,
                        width: textSize.width,
                        height: textSize.height
                    )
                    attr.draw(in: textRect)
                    ctx.restoreGState()
                }
            } else {
                if isWarning {
                    baseColor.withAlphaComponent(0.16).setFill()
                    pillPath.fill()
                }
                pillPath.lineWidth = 1.35
                baseColor.withAlphaComponent(isWarning ? 0.95 : 0.85).setStroke()
                pillPath.stroke()

                let attr = NSAttributedString(
                    string: letter,
                    attributes: [
                        .font: font,
                        .foregroundColor: baseColor,
                        .paragraphStyle: style,
                    ]
                )
                let textSize = attr.size()
                let textRect = NSRect(
                    x: pillRect.midX - textSize.width / 2,
                    y: pillRect.midY - textSize.height / 2,
                    width: textSize.width,
                    height: textSize.height
                )
                attr.draw(in: textRect)
            }

            if hasUpdate {
                let dotCenter = NSPoint(x: width - 3.5, y: height - 4.0)
                let dotRect = NSRect(x: dotCenter.x - 2.6, y: dotCenter.y - 2.6, width: 5.2, height: 5.2)
                if let ctx = NSGraphicsContext.current?.cgContext {
                    ctx.saveGState()
                    ctx.setBlendMode(.clear)
                    let halo = NSBezierPath(ovalIn: dotRect.insetBy(dx: -1.1, dy: -1.1))
                    halo.fill()
                    ctx.restoreGState()
                }
                NSColor.controlAccentColor.setFill()
                NSBezierPath(ovalIn: dotRect).fill()
            }
            return true
        }
        image.isTemplate = !isWarning && !hasUpdate
        return image
    }

    private func applyShortcutHint(to item: NSMenuItem?, keyCode: Int, carbonModifiers: UInt) {
        guard let item else { return }
        if let equiv = HotkeyRecorderView.menuKeyEquivalent(for: keyCode) {
            item.keyEquivalent = equiv
            item.keyEquivalentModifierMask = HotkeyRecorderView.appKitModifiers(of: carbonModifiers)
        } else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
        }
    }

    private func refreshMenuBar() {
        let settings = AppSettings.shared
        let current = settings.effectiveFor(bundleID: activeBundleID)
        let isWarning = (tap == nil)
        let isVietnamese = !isWarning && current.method != .off
        let hasUpdate = (UpdateService.shared.availableUpdate != nil)
        let letter = menuBarLetter()

        if let button = statusItem?.button {
            button.title = ""
            button.image = makeStatusBarBadge(
                letter: letter,
                isVietnamese: isVietnamese,
                isWarning: isWarning,
                hasUpdate: hasUpdate
            )
            button.imagePosition = .imageOnly
            let toggleCompact = HotkeyRecorderView.compactDescribe(
                keyCode: settings.toggleHotKeyCode,
                carbonModifiers: settings.toggleHotKeyModifiers
            )
            if isWarning {
                button.toolTip = "KeyV — Cần cấp quyền Trợ năng để kích hoạt bộ gõ"
            } else {
                let modeText = isVietnamese ? "Tiếng Việt (\(methodDisplayName(current.method)))" : "English"
                let updateSuffix = hasUpdate ? " • Có bản cập nhật mới" : ""
                button.toolTip = "KeyV — \(modeText) • Chuyển nhanh: \(toggleCompact)\(updateSuffix)"
            }
        }

        let toggleCompact = HotkeyRecorderView.compactDescribe(
            keyCode: settings.toggleHotKeyCode,
            carbonModifiers: settings.toggleHotKeyModifiers
        )
        let overlayCompact = HotkeyRecorderView.compactDescribe(
            keyCode: settings.overlayHotKeyCode,
            carbonModifiers: settings.overlayHotKeyModifiers
        )

        if let typingMenuItem {
            typingMenuItem.title = typingStatusTitle()
            let symbol = isWarning
                ? "exclamationmark.shield.fill"
                : (isVietnamese ? "character.cursor.ibeam" : "globe")
            typingMenuItem.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            applyShortcutHint(
                to: typingMenuItem,
                keyCode: settings.toggleHotKeyCode,
                carbonModifiers: settings.toggleHotKeyModifiers
            )
            if #available(macOS 14.4, *) {
                if isWarning {
                    typingMenuItem.subtitle = "Nhấp để mở hướng dẫn cấp quyền Trợ năng"
                } else {
                    let ctrlShiftNote = settings.ctrlShiftSwitch ? " · hoặc Ctrl + Shift" : ""
                    typingMenuItem.subtitle = "Nhấp để chuyển Việt / Anh (\(toggleCompact)\(ctrlShiftNote))"
                }
            }
        }

        if let overlayMenuItem {
            applyShortcutHint(
                to: overlayMenuItem,
                keyCode: settings.overlayHotKeyCode,
                carbonModifiers: settings.overlayHotKeyModifiers
            )
            if #available(macOS 14.4, *) {
                overlayMenuItem.subtitle = "Mở nhanh bằng \(overlayCompact)"
            }
        }

        if let remoteMenuItem {
            let runningServers = RemoteInputDetector.shared.cachedRunningServers()
            let shouldShowRemote = !runningServers.isEmpty || settings.remoteDesktopMode != .smartAuto
            remoteMenuItem.isHidden = !shouldShowRemote
            if shouldShowRemote {
                let serverLabel = runningServers.first?.displayName ?? "Từ xa"
                let modeShort: String
                switch settings.remoteDesktopMode {
                case .smartAuto: modeShort = "Tự động thông minh"
                case .phoneKeyboardOnly: modeShort = "Nhường bàn phím ĐT"
                case .alwaysKeyV: modeShort = "Luôn dùng KeyV"
                }
                remoteMenuItem.title = "Từ xa (\(serverLabel)): \(modeShort)"
                for (mode, item) in remoteModeItems {
                    item.state = (mode == settings.remoteDesktopMode) ? .on : .off
                }
            }
        }

        let updateTitle = updateMenuTitle()
        let updateSymbol = hasUpdate ? "arrow.down.circle.fill" : "arrow.triangle.2.circlepath"
        updateMenuItem?.title = updateTitle
        updateMenuItem?.image = NSImage(systemSymbolName: updateSymbol, accessibilityDescription: nil)
        mainUpdateMenuItem?.title = updateTitle
        mainUpdateMenuItem?.image = NSImage(systemSymbolName: updateSymbol, accessibilityDescription: nil)
    }

    @objc private func updateStateChanged() {
        refreshMenuBar()
    }

    @objc fileprivate func toggleTyping() {
        guard tap != nil else { showOnboarding(); return }
        let settings = AppSettings.shared
        if let frontBundle = activeBundleID, var override = settings.appOverridesJSON[frontBundle], override.useMode != nil {
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

    @objc private func selectRemoteDesktopMode(_ sender: NSMenuItem) {
        guard let mode = RemoteDesktopMode(rawValue: sender.tag) else { return }
        AppSettings.shared.remoteDesktopMode = mode
    }

    @objc private func showSystemSettings() {
        SettingsModel.shared.selectedTab = .system
        showSettings()
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 650),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            window.title = "Cài đặt KeyV"
            window.minSize = NSSize(width: 700, height: 620)
            window.isReleasedWhenClosed = false
            window.center()
            window.contentView = NSHostingView(rootView: SettingsRootView())
            settingsWindow = window
        }
        if let settingsWindow {
            WindowFocusCoordinator.shared.present(settingsWindow)
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Settings / profiles

    @objc private func engineSettingsChanged(_ note: Notification) {
        let settings = AppSettings.shared
        let effective = settings.effectiveFor(bundleID: activeBundleID)
        engine.setMethod(effective.method)
        engine.setOrthography(effective.orthography)
        engine.setAllowWAsConsonant(settings.allowWAsConsonant)
        engine.setMacroEnabled(settings.macroEnabled)
        engine.setOptions(autoCapitalize: settings.autoCapitalize,
                          repeatedRestore: settings.repeatedRestore,
                          spellCheck: settings.spellCheck)
        if settings.macroEnabled && !macrosLoaded {
            loadMacroFile()
        }
        tap?.refreshCachedSettings()
        refreshMenuBar()
        reRegisterGlobalHotKeysIfNeeded()
    }

    @objc private func appActivated(_ note: Notification) {
        let front = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
            ?? NSWorkspace.shared.frontmostApplication
        activeBundleID = front?.bundleIdentifier
        activePID = front?.processIdentifier ?? 0
        tap?.handleApplicationActivated(bundleID: activeBundleID, pid: activePID)

        if let front, front.bundleIdentifier != Bundle.main.bundleIdentifier {
            let name = front.localizedName ?? front.bundleIdentifier ?? "?"
            AppSettings.shared.noteSeenApp(bundleID: front.bundleIdentifier ?? "?", name: name)
        }

        let effective = AppSettings.shared.effectiveFor(bundleID: activeBundleID)
        engine.setMethod(effective.method)
        engine.setOrthography(effective.orthography)
        refreshMenuBar()
    }

    // MARK: - Macros (gõ tắt)

    @objc private func macroFileReloaded() {
        let settings = AppSettings.shared
        let effective = settings.effectiveFor(bundleID: activeBundleID)
        engine = ViEngine(method: effective.method,
                          orthography: effective.orthography,
                          macroEnabled: settings.macroEnabled,
                          allowWAsConsonant: settings.allowWAsConsonant)
        engine.setOptions(autoCapitalize: settings.autoCapitalize,
                          repeatedRestore: settings.repeatedRestore,
                          spellCheck: settings.spellCheck)
        macrosLoaded = false
        loadMacroFile()
        tap?.engine = engine
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
        macrosLoaded = true
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

    private func reRegisterGlobalHotKeysIfNeeded() {
        let settings = AppSettings.shared
        guard installedOverlayHotKeyCode != settings.overlayHotKeyCode
            || installedOverlayHotKeyModifiers != settings.overlayHotKeyModifiers
            || installedToggleHotKeyCode != settings.toggleHotKeyCode
            || installedToggleHotKeyModifiers != settings.toggleHotKeyModifiers
        else { return }
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
        installedOverlayHotKeyCode = settings.overlayHotKeyCode
        installedOverlayHotKeyModifiers = settings.overlayHotKeyModifiers
        installedToggleHotKeyCode = settings.toggleHotKeyCode
        installedToggleHotKeyModifiers = settings.toggleHotKeyModifiers
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
        tap?.engine.reset()
        SelectionCacheService.shared.invalidate()
        overlayPanel.toggleNearFrontmost()
    }
}

extension AppDelegate: NSMenuDelegate {
    public func menuNeedsUpdate(_ menu: NSMenu) {
        RemoteInputDetector.shared.refreshRunningServersAsync { [weak self] _ in
            self?.refreshMenuBar()
        }
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
