import Foundation
import KeyVCore
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics

/// CGEventTap controller with auto re-arm on
/// `kCGEventTapDisabledByTimeout` / `ByUserInput` (Gotcha 1 listener).
///
/// Threading: the tap is installed on the main run loop, so key handling and
/// engine state live on the main thread.
public final class TapController: NSObject {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    public var engine: ViEngine
    public let injector: EventInjector
    public let remoteDetector: RemoteInputDetector
    public var activeBundleID: String?
    public var activePID: pid_t = 0
    public var onModeToggleShortcut: (() -> Void)?
    public var ctrlShiftSwitchEnabled: Bool
    public var remoteDesktopMode: RemoteDesktopMode
    public var isSecureInputActive: Bool = false
    public var secureInputProvider: (() -> Bool)?
    public private(set) var lastRemoteSource: RemoteSourceKind = .local

    private var ctrlShiftArmed = false
    private var ctrlShiftDisqualified = false
    private var consumedKeyLo: UInt64 = 0
    private var consumedKeyHi: UInt64 = 0
    private var remoteZeroKeyConsumedCount: Int = 0
    private var lastReplaceUptimeNs: UInt64 = 0
    private var lastReplaceEventTs: CGEventTimestamp = 0
    private var needsFrontmostRefresh = false
    private var lastEventWasRemote = false
    private var remoteMobileWordActive = false
    private var lastRemoteVkBackNs: UInt64 = 0
    private var pendingRustDeskSentinelOneNs: UInt64 = 0
    private var pendingRustDeskSentinelAfterBack = false

    private static let postReplaceSerializeWindowNs: UInt64 = 80_000_000
    private static let rustDeskSentinelAfterBackWindowNs: UInt64 = 60_000_000
    private static let rustDeskSentinelFollowupWindowNs: UInt64 = 25_000_000
    private static let blockingModifiers: CGEventFlags = [
        .maskCommand,
        .maskControl,
        .maskAlternate,
        .maskSecondaryFn,
        .maskHelp,
    ]
    private static let remoteCoreBlockingModifiers: CGEventFlags = [
        .maskCommand,
        .maskControl,
        .maskAlternate,
        .maskHelp,
    ]

    public init(
        engine: ViEngine,
        injector: EventInjector,
        remoteDetector: RemoteInputDetector = .shared
    ) {
        self.engine = engine
        self.injector = injector
        self.remoteDetector = remoteDetector
        let settings = AppSettings.shared
        self.ctrlShiftSwitchEnabled = settings.ctrlShiftSwitch
        self.remoteDesktopMode = settings.remoteDesktopMode
        if let front = NSWorkspace.shared.frontmostApplication {
            self.activeBundleID = front.bundleIdentifier
            self.activePID = front.processIdentifier
        }
        super.init()
        refreshSecureInputState()
    }

    @discardableResult
    public func install() -> Bool {
        if tap != nil { return true }
        let mask = [
            CGEventType.keyDown,
            .keyUp,
            .flagsChanged,
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
        ].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }

        let callback: CGEventTapCallBack = { proxy, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<TapController>.fromOpaque(userInfo).takeUnretainedValue()
            return controller.handleEvent(proxy: proxy, type: type, event: event)
        }

        // AppDelegate owns this controller until the tap is invalidated.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            NSLog("[KeyV] CGEventTapCreate failed — keyboard hook unavailable")
            return false
        }
        self.tap = tap
        CGEvent.tapEnable(tap: tap, enable: true)

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        refreshSecureInputState()
        return true
    }

    public func uninstall() {
        ctrlShiftArmed = false
        ctrlShiftDisqualified = false
        clearConsumedKeys()
        resetRemoteInputState()
        lastReplaceUptimeNs = 0
        needsFrontmostRefresh = false
        SelectionCacheService.shared.invalidate()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        tap = nil
    }

    public func handleApplicationActivated(bundleID: String?, pid: pid_t) {
        ctrlShiftArmed = false
        ctrlShiftDisqualified = false
        clearConsumedKeys()
        resetRemoteInputState()
        lastReplaceUptimeNs = 0
        needsFrontmostRefresh = false
        SelectionCacheService.shared.invalidate()
        activeBundleID = bundleID
        activePID = pid
        refreshSecureInputState()
        engine.reset()
    }

    public func refreshCachedSettings() {
        let settings = AppSettings.shared
        ctrlShiftSwitchEnabled = settings.ctrlShiftSwitch
        injector.compatFixEnabled = settings.compatFix
        if remoteDesktopMode != settings.remoteDesktopMode {
            remoteDesktopMode = settings.remoteDesktopMode
            resetRemoteInputState()
            engine.reset()
        }
    }

    public func refreshSecureInputState() {
        if let secureInputProvider {
            isSecureInputActive = secureInputProvider()
            return
        }
        guard IsSecureEventInputEnabled() else {
            isSecureInputActive = false
            return
        }
        isSecureInputActive = SelectionCacheService.shared.isFocusedElementSecureTextField(
            pid: activePID,
            bundleID: activeBundleID
        )
    }

    @discardableResult
    public func processEventForTesting(type: CGEventType, event: CGEvent) -> CGEvent? {
        handleEvent(proxy: nil, type: type, event: event)?.takeUnretainedValue()
    }

    // MARK: - Event handling

    fileprivate func handleEvent(proxy: CGEventTapProxy?, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Gotcha 1: re-arm when the system kills the tap.
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            NSLog("[KeyV] CGEventTap re-enabled after event \(type.rawValue)")
            engine.reset()
            clearConsumedKeys()
            resetRemoteInputState()
            lastReplaceUptimeNs = 0
            SelectionCacheService.shared.invalidate()
            return nil
        default:
            break
        }

        // Synthetic events must reach the target app without re-entering the engine.
        let eventUserData = event.getIntegerValueField(.eventSourceUserData)
        if eventUserData == EventInjector.syntheticMarker {
            return Unmanaged.passUnretained(event)
        }
        let sourceID = CGEventSourceStateID(
            rawValue: Int32(truncatingIfNeeded: event.getIntegerValueField(.eventSourceStateID)))
        if sourceID == .privateState {
            return Unmanaged.passUnretained(event)
        }

        let nowNs = DispatchTime.now().uptimeNanoseconds
        let sourcePID = pid_t(truncatingIfNeeded: event.getIntegerValueField(.eventSourceUnixProcessID))
        let remoteSource = remoteDetector.sourceKind(
            for: sourcePID,
            eventUserData: eventUserData,
            nowNs: nowNs
        )
        let isRemote = remoteSource.isRemote
        if isRemote {
            lastRemoteSource = remoteSource
        }

        let withinWallWindow = lastReplaceUptimeNs != 0
            && (nowNs &- lastReplaceUptimeNs) <= Self.postReplaceSerializeWindowNs
        if !withinWallWindow {
            remoteZeroKeyConsumedCount = 0
        }

        if type == .keyUp {
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            if isRemote && remoteDesktopMode == .phoneKeyboardOnly && !withinWallWindow {
                return Unmanaged.passUnretained(event)
            }
            if isRemote && keyCode == 0 && remoteZeroKeyConsumedCount > 0 {
                remoteZeroKeyConsumedCount -= 1
                return nil
            }
            return takeConsumedKey(keyCode) ? nil : Unmanaged.passUnretained(event)
        }

        if type == .flagsChanged {
            if isRemote && remoteDesktopMode == .phoneKeyboardOnly {
                return Unmanaged.passUnretained(event)
            }
            handleFlagsChanged(event.flags)
            return Unmanaged.passUnretained(event)
        }

        ctrlShiftArmed = false
        if !event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]).isEmpty {
            ctrlShiftDisqualified = true
        }

        if type != .keyDown {
            engine.reset()
            resetRemoteInputState()
            lastReplaceUptimeNs = 0
            needsFrontmostRefresh = true
            SelectionCacheService.shared.invalidate()
            refreshSecureInputState()
            return Unmanaged.passUnretained(event)
        }

        if lastEventWasRemote != isRemote {
            engine.reset()
            resetRemoteInputState()
            lastReplaceUptimeNs = 0
            lastEventWasRemote = isRemote
        }

        if proxy != nil && needsFrontmostRefresh {
            needsFrontmostRefresh = false
            if let front = NSWorkspace.shared.frontmostApplication {
                activeBundleID = front.bundleIdentifier
                activePID = front.processIdentifier
            }
        }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if !(isRemote && keyCode == 0) {
            _ = takeConsumedKey(keyCode)
        }

        let remoteZeroKeyString: String? = (isRemote && keyCode == 0) ? event.keyboardString() : nil
        let hasBlockingModifier: Bool
        if isRemote {
            let isAppleFunctionScalar = remoteZeroKeyString?.unicodeScalars.first.map {
                (0xF700...0xF8FF).contains($0.value)
            } ?? false
            hasBlockingModifier = !event.flags.intersection(Self.remoteCoreBlockingModifiers).isEmpty
                || isAppleFunctionScalar
        } else {
            hasBlockingModifier = !event.flags.intersection(Self.blockingModifiers).isEmpty
                || (keyCode != 76 && event.flags.contains(.maskNumericPad))
        }

        if hasBlockingModifier {
            SelectionCacheService.shared.invalidate()
            engine.reset()
            remoteMobileWordActive = false
            pendingRustDeskSentinelOneNs = 0
            pendingRustDeskSentinelAfterBack = false
            lastRemoteVkBackNs = 0
            lastReplaceUptimeNs = 0
            return Unmanaged.passUnretained(event)
        }

        if isSecureInputActive {
            refreshSecureInputState()
            if isSecureInputActive {
                engine.reset()
                resetRemoteInputState()
                lastReplaceUptimeNs = 0
                return Unmanaged.passUnretained(event)
            }
        }

        let eventTimeNs = event.timestamp != 0 ? event.timestamp : nowNs
        let withinEventTsWindow = event.timestamp == 0
            || lastReplaceEventTs == 0
            || (event.timestamp >= lastReplaceEventTs
                && (event.timestamp &- lastReplaceEventTs) <= Self.postReplaceSerializeWindowNs)
        let withinPostReplaceWindow = withinWallWindow && withinEventTsWindow

        let isBackspace = (keyCode == 51)
            || (remoteZeroKeyString == "\u{0008}" || remoteZeroKeyString == "\u{007F}")

        if isBackspace {
            pendingRustDeskSentinelOneNs = 0
            pendingRustDeskSentinelAfterBack = false
            if isRemote {
                lastRemoteVkBackNs = eventTimeNs
            }
            if isRemote && remoteDesktopMode == .phoneKeyboardOnly {
                engine.reset()
                return passOrSerialize(
                    event,
                    keyCode: keyCode,
                    isRemote: true,
                    withinPostReplaceWindow: withinPostReplaceWindow,
                    proxy: proxy
                )
            }
            if isRemote && remoteDesktopMode == .smartAuto && remoteMobileWordActive {
                engine.reset()
                return passOrSerialize(
                    event,
                    keyCode: keyCode,
                    isRemote: true,
                    withinPostReplaceWindow: withinPostReplaceWindow,
                    proxy: proxy
                )
            }
            engine.processBackspace()
            return passOrSerialize(
                event,
                keyCode: keyCode,
                isRemote: isRemote,
                withinPostReplaceWindow: withinPostReplaceWindow,
                proxy: proxy
            )
        }

        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            engine.reset()
            pendingRustDeskSentinelOneNs = 0
            pendingRustDeskSentinelAfterBack = false
            lastReplaceUptimeNs = 0
            return Unmanaged.passUnretained(event)
        }

        // Navigation kills word composition: reset the session.
        if Self.navigationKeyCodes.contains(keyCode) || remoteZeroKeyString == "\u{001B}" {
            SelectionCacheService.shared.invalidate()
            engine.reset()
            remoteMobileWordActive = false
            lastRemoteVkBackNs = 0
            pendingRustDeskSentinelOneNs = 0
            pendingRustDeskSentinelAfterBack = false
            lastReplaceUptimeNs = 0
            return Unmanaged.passUnretained(event)
        }

        let delimiterBoundaryChar: Character?
        if keyCode == 48 || remoteZeroKeyString == "\t" {
            delimiterBoundaryChar = "\t"
        } else if keyCode == 36 || keyCode == 76
            || remoteZeroKeyString == "\r"
            || remoteZeroKeyString == "\n"
            || remoteZeroKeyString == "\r\n" {
            delimiterBoundaryChar = "\r"
        } else {
            delimiterBoundaryChar = nil
        }

        if let boundaryChar = delimiterBoundaryChar {
            SelectionCacheService.shared.invalidate()
            remoteMobileWordActive = false
            lastRemoteVkBackNs = 0
            pendingRustDeskSentinelOneNs = 0
            pendingRustDeskSentinelAfterBack = false
            if isRemote && remoteDesktopMode == .phoneKeyboardOnly {
                engine.reset()
                return passOrSerialize(
                    event,
                    keyCode: keyCode,
                    isRemote: true,
                    withinPostReplaceWindow: withinPostReplaceWindow,
                    proxy: proxy
                )
            }
            let action = engine.process(boundaryChar)
            switch action {
            case .pass:
                return passOrSerialize(
                    event,
                    keyCode: keyCode,
                    isRemote: isRemote,
                    withinPostReplaceWindow: withinPostReplaceWindow,
                    proxy: proxy
                )
            case .replace(let backspaces, let chars):
                var wordChars = chars
                if wordChars.last == boundaryChar {
                    wordChars.removeLast()
                }
                let target = resolveTargetApp(proxy: proxy, isRemote: isRemote)
                consumeKey(keyCode, isRemote: isRemote)
                lastReplaceUptimeNs = nowNs
                lastReplaceEventTs = event.timestamp
                injector.realize(
                    .replace(backspaces: backspaces, chars: wordChars),
                    pid: target.pid,
                    bundleID: target.bundleID,
                    triggerTimestamp: event.timestamp,
                    proxy: proxy,
                    isRemote: isRemote
                )
                injector.postClonedEvent(
                    event,
                    triggerTimestamp: event.timestamp,
                    proxy: proxy,
                    sanitizeRemoteFlags: isRemote
                )
                return nil
            }
        }

        let characters = remoteZeroKeyString ?? event.keyboardString()
        if remoteSource == .rustDesk && keyCode == 0 && !characters.isEmpty {
            let recentVkBack = lastRemoteVkBackNs != 0
                && eventTimeNs >= lastRemoteVkBackNs
                && (eventTimeNs &- lastRemoteVkBackNs) <= Self.rustDeskSentinelAfterBackWindowNs

            if characters.count >= 2 && characters.first == "1" {
                let tail = String(characters.dropFirst())
                if let secondScalar = tail.unicodeScalars.first,
                   Self.isMobileComposedScalar(secondScalar)
                    || (recentVkBack && Self.isASCIIAlphabetic(secondScalar)) {
                    pendingRustDeskSentinelOneNs = 0
                    pendingRustDeskSentinelAfterBack = false
                    lastRemoteVkBackNs = 0
                    engine.reset()
                    consumeKey(0, isRemote: true)
                    lastReplaceUptimeNs = nowNs
                    lastReplaceEventTs = event.timestamp
                    if remoteDesktopMode == .smartAuto {
                        remoteMobileWordActive = !Self.endsWithWordBoundary(tail)
                    }
                    injector.realize(
                        .replace(backspaces: 0, chars: tail),
                        pid: activePID,
                        bundleID: activeBundleID,
                        triggerTimestamp: event.timestamp,
                        proxy: proxy,
                        isRemote: true
                    )
                    return nil
                }
            }

            if pendingRustDeskSentinelOneNs != 0 {
                let deltaNs = eventTimeNs >= pendingRustDeskSentinelOneNs
                    ? (eventTimeNs &- pendingRustDeskSentinelOneNs)
                    : UInt64.max
                let afterBack = pendingRustDeskSentinelAfterBack
                pendingRustDeskSentinelOneNs = 0
                pendingRustDeskSentinelAfterBack = false
                if deltaNs <= Self.rustDeskSentinelFollowupWindowNs,
                   let firstScalar = characters.unicodeScalars.first,
                   Self.isMobileComposedScalar(firstScalar)
                    || (afterBack && Self.isASCIIAlphabetic(firstScalar)) {
                    lastRemoteVkBackNs = 0
                    engine.reset()
                    consumeKey(0, isRemote: true)
                    lastReplaceUptimeNs = nowNs
                    lastReplaceEventTs = event.timestamp
                    if remoteDesktopMode == .smartAuto && Self.isMobileComposedScalar(firstScalar) {
                        remoteMobileWordActive = !Self.endsWithWordBoundary(characters)
                    } else if remoteDesktopMode != .phoneKeyboardOnly
                        && characters.unicodeScalars.count == 1
                        && Self.isASCIIAlphabetic(firstScalar),
                       let singleCh = characters.first {
                        _ = engine.process(singleCh)
                    }
                    injector.realize(
                        .replace(backspaces: 1, chars: characters),
                        pid: activePID,
                        bundleID: activeBundleID,
                        triggerTimestamp: event.timestamp,
                        proxy: proxy,
                        isRemote: true
                    )
                    return nil
                }
            }

            if characters == "1" {
                pendingRustDeskSentinelOneNs = eventTimeNs
                pendingRustDeskSentinelAfterBack = recentVkBack
            }
        } else {
            pendingRustDeskSentinelOneNs = 0
            pendingRustDeskSentinelAfterBack = false
        }
        lastRemoteVkBackNs = 0

        if isRemote && remoteDesktopMode == .phoneKeyboardOnly {
            engine.reset()
            return passOrSerialize(
                event,
                keyCode: keyCode,
                isRemote: true,
                withinPostReplaceWindow: withinPostReplaceWindow,
                proxy: proxy
            )
        }

        if characters.isEmpty {
            engine.reset()
            return passOrSerialize(
                event,
                keyCode: keyCode,
                isRemote: isRemote,
                withinPostReplaceWindow: withinPostReplaceWindow,
                proxy: proxy
            )
        }

        if characters.utf16.count > 1 || characters.unicodeScalars.count > 1 {
            engine.reset()
            if isRemote && remoteDesktopMode == .smartAuto {
                remoteMobileWordActive = !Self.endsWithWordBoundary(characters)
            }
            return passOrSerialize(
                event,
                keyCode: keyCode,
                isRemote: isRemote,
                withinPostReplaceWindow: withinPostReplaceWindow,
                proxy: proxy
            )
        }

        guard let scalar = characters.unicodeScalars.first, let ch = characters.first else {
            engine.reset()
            return passOrSerialize(
                event,
                keyCode: keyCode,
                isRemote: isRemote,
                withinPostReplaceWindow: withinPostReplaceWindow,
                proxy: proxy
            )
        }

        if scalar.value < 0x20 || scalar.value == 0x7F {
            engine.reset()
            remoteMobileWordActive = false
            return passOrSerialize(
                event,
                keyCode: keyCode,
                isRemote: isRemote,
                withinPostReplaceWindow: withinPostReplaceWindow,
                proxy: proxy
            )
        }

        if scalar.value > 0x7F {
            engine.reset()
            if isRemote && remoteDesktopMode == .smartAuto {
                remoteMobileWordActive = Self.isMobileComposedScalar(scalar)
            }
            return passOrSerialize(
                event,
                keyCode: keyCode,
                isRemote: isRemote,
                withinPostReplaceWindow: withinPostReplaceWindow,
                proxy: proxy
            )
        }

        if isRemote && remoteDesktopMode == .smartAuto && remoteMobileWordActive {
            engine.reset()
            if !Self.isWordContinuationASCII(scalar) {
                remoteMobileWordActive = false
            }
            return passOrSerialize(
                event,
                keyCode: keyCode,
                isRemote: true,
                withinPostReplaceWindow: withinPostReplaceWindow,
                proxy: proxy
            )
        }

        let action = engine.process(ch)
        switch action {
        case .pass:
            return passOrSerialize(
                event,
                keyCode: keyCode,
                isRemote: isRemote,
                withinPostReplaceWindow: withinPostReplaceWindow,
                proxy: proxy
            )
        case .replace(let backspaces, let chars):
            let target = resolveTargetApp(proxy: proxy, isRemote: isRemote)
            consumeKey(keyCode, isRemote: isRemote)
            lastReplaceUptimeNs = nowNs
            lastReplaceEventTs = event.timestamp
            injector.realize(
                .replace(backspaces: backspaces, chars: chars),
                pid: target.pid,
                bundleID: target.bundleID,
                triggerTimestamp: event.timestamp,
                proxy: proxy,
                isRemote: isRemote
            )
            return nil
        }
    }

    private func resolveTargetApp(proxy: CGEventTapProxy?, isRemote: Bool) -> (pid: pid_t, bundleID: String?) {
        guard proxy != nil && !isRemote else {
            return (activePID, activeBundleID)
        }
        return SelectionCacheService.shared.resolveFocusedOverlayApp(
            currentPID: activePID,
            currentBundleID: activeBundleID
        )
    }

    private func passOrSerialize(
        _ event: CGEvent,
        keyCode: Int,
        isRemote: Bool,
        withinPostReplaceWindow: Bool,
        proxy: CGEventTapProxy?
    ) -> Unmanaged<CGEvent>? {
        if withinPostReplaceWindow {
            consumeKey(keyCode, isRemote: isRemote)
            injector.postClonedEvent(
                event,
                triggerTimestamp: event.timestamp,
                proxy: proxy,
                sanitizeRemoteFlags: isRemote
            )
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    private func consumeKey(_ keyCode: Int, isRemote: Bool) {
        if isRemote && keyCode == 0 {
            remoteZeroKeyConsumedCount = min(remoteZeroKeyConsumedCount + 1, 32)
        } else {
            markKeyConsumed(keyCode)
        }
    }

    private func resetRemoteInputState() {
        lastEventWasRemote = false
        remoteMobileWordActive = false
        remoteZeroKeyConsumedCount = 0
        lastRemoteVkBackNs = 0
        pendingRustDeskSentinelOneNs = 0
        pendingRustDeskSentinelAfterBack = false
        lastReplaceEventTs = 0
    }

    private static func isASCIIAlphabetic(_ scalar: UnicodeScalar) -> Bool {
        let v = scalar.value
        return (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v)
    }

    private static func isMobileComposedScalar(_ scalar: UnicodeScalar) -> Bool {
        let v = scalar.value
        if (0x0300...0x036F).contains(v)
            || (0x1DC0...0x1DFF).contains(v)
            || (0x20D0...0x20FF).contains(v)
            || (0xFE20...0xFE2F).contains(v) {
            return true
        }
        if scalar.properties.isDiacritic {
            return true
        }
        let cat = scalar.properties.generalCategory
        if cat == .nonspacingMark || cat == .spacingMark || cat == .enclosingMark {
            return true
        }
        return v > 0x7F && scalar.properties.isAlphabetic
    }

    private static func isWordContinuationASCII(_ scalar: UnicodeScalar) -> Bool {
        let v = scalar.value
        return (0x41...0x5A).contains(v)
            || (0x61...0x7A).contains(v)
            || (0x30...0x39).contains(v)
            || v == 0x27
            || v == 0x5F
    }

    private static func endsWithWordBoundary(_ text: String) -> Bool {
        guard let last = text.unicodeScalars.last else { return true }
        if isMobileComposedScalar(last) {
            return false
        }
        if last.value <= 0x7F && isWordContinuationASCII(last) {
            return false
        }
        return true
    }

    private func markKeyConsumed(_ keyCode: Int) {
        guard keyCode >= 0 && keyCode < 128 else { return }
        if keyCode < 64 {
            consumedKeyLo |= (UInt64(1) << UInt64(keyCode))
        } else {
            consumedKeyHi |= (UInt64(1) << UInt64(keyCode - 64))
        }
    }

    private func takeConsumedKey(_ keyCode: Int) -> Bool {
        guard keyCode >= 0 && keyCode < 128 else { return false }
        if keyCode < 64 {
            let bit = UInt64(1) << UInt64(keyCode)
            let wasSet = (consumedKeyLo & bit) != 0
            consumedKeyLo &= ~bit
            return wasSet
        } else {
            let bit = UInt64(1) << UInt64(keyCode - 64)
            let wasSet = (consumedKeyHi & bit) != 0
            consumedKeyHi &= ~bit
            return wasSet
        }
    }

    private func clearConsumedKeys() {
        consumedKeyLo = 0
        consumedKeyHi = 0
    }

    private func handleFlagsChanged(_ flags: CGEventFlags) {
        if flags.contains(.maskSecondaryFn) {
            ctrlShiftArmed = false
            ctrlShiftDisqualified = true
            return
        }
        let relevant = flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        if relevant.isEmpty {
            let shouldToggle = ctrlShiftArmed && !ctrlShiftDisqualified
            ctrlShiftArmed = false
            ctrlShiftDisqualified = false
            if shouldToggle && ctrlShiftSwitchEnabled {
                engine.reset()
                lastReplaceUptimeNs = 0
                onModeToggleShortcut?()
            }
            return
        }
        if !relevant.intersection([.maskCommand, .maskAlternate]).isEmpty {
            ctrlShiftArmed = false
            ctrlShiftDisqualified = true
            SelectionCacheService.shared.invalidate()
            engine.reset()
            lastReplaceUptimeNs = 0
            return
        }
        if relevant == [.maskControl, .maskShift] {
            if !ctrlShiftDisqualified && ctrlShiftSwitchEnabled {
                ctrlShiftArmed = true
            }
            return
        }
        if relevant.contains(.maskControl) {
            SelectionCacheService.shared.invalidate()
            engine.reset()
            lastReplaceUptimeNs = 0
        }
    }

    private static let navigationKeyCodes: Set<Int> = [
        123, 124, 125, 126,       // arrows
        115, 119, 116, 121,       // home / end / page up / page down
        117, 53,                  // forward delete, escape
    ]
}

// MARK: - CGEvent helpers

public extension CGEvent {
    /// Unicode chars carried by a keyboard event.
    func keyboardString() -> String {
        var length: CFIndex = 0
        keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &length, unicodeString: nil)
        guard length > 0 else { return "" }
        var buffer = [UniChar](repeating: 0, count: length)
        var actual: CFIndex = 0
        keyboardGetUnicodeString(maxStringLength: length, actualStringLength: &actual, unicodeString: &buffer)
        guard actual > 0 else { return "" }
        return String(decoding: buffer.prefix(actual), as: UTF16.self)
    }

    func keyboardSetUnicodeString(stringLength: CFIndex, unicodeString: [UniChar]) {
        var buffer = unicodeString
        keyboardSetUnicodeString(stringLength: stringLength, unicodeString: &buffer)
    }
}
