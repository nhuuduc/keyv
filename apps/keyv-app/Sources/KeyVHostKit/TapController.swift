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
    private var remoteAutoReplaceUntilNs: UInt64 = 0
    private var lastRemoteBackspaceNs: UInt64 = 0
    private var remoteBackspaceBurstCount: Int = 0

    private static let postReplaceSerializeWindowNs: UInt64 = 80_000_000
    private static let remoteBackspaceBurstWindowNs: UInt64 = 15_000_000
    private static let remoteAutoReplaceWindowNs: UInt64 = 25_000_000
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
        self.isSecureInputActive = IsSecureEventInputEnabled()
        if let front = NSWorkspace.shared.frontmostApplication {
            self.activeBundleID = front.bundleIdentifier
            self.activePID = front.processIdentifier
        }
        super.init()
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
        isSecureInputActive = IsSecureEventInputEnabled()
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
        if event.getIntegerValueField(.eventSourceUserData) == EventInjector.syntheticMarker {
            return Unmanaged.passUnretained(event)
        }
        let sourceID = CGEventSourceStateID(
            rawValue: Int32(truncatingIfNeeded: event.getIntegerValueField(.eventSourceStateID)))
        if sourceID == .privateState {
            return Unmanaged.passUnretained(event)
        }

        let nowNs = DispatchTime.now().uptimeNanoseconds
        let sourcePID = pid_t(truncatingIfNeeded: event.getIntegerValueField(.eventSourceUnixProcessID))
        let remoteSource = remoteDetector.sourceKind(for: sourcePID, nowNs: nowNs)
        let isRemote = remoteSource.isRemote
        if isRemote {
            lastRemoteSource = remoteSource
        }

        if isRemote && remoteDesktopMode == .phoneKeyboardOnly {
            engine.reset()
            lastReplaceUptimeNs = 0
            lastEventWasRemote = true
            return Unmanaged.passUnretained(event)
        }

        if type == .keyUp {
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            if isRemote && keyCode == 0 && remoteZeroKeyConsumedCount > 0 {
                remoteZeroKeyConsumedCount -= 1
                return nil
            }
            return takeConsumedKey(keyCode) ? nil : Unmanaged.passUnretained(event)
        }

        if type == .flagsChanged {
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

        var targetPID = activePID
        var targetBundleID = activeBundleID
        if proxy != nil {
            let resolved = SelectionCacheService.shared.resolveFocusedOverlayApp(
                currentPID: activePID,
                currentBundleID: activeBundleID
            )
            targetPID = resolved.pid
            targetBundleID = resolved.bundleID
        }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if !(isRemote && keyCode == 0) {
            _ = takeConsumedKey(keyCode)
        }

        let remoteZeroKeyString: String? = (isRemote && keyCode == 0) ? event.keyboardString() : nil
        let hasBlockingModifier: Bool
        if isRemote && keyCode == 0 {
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
            remoteAutoReplaceUntilNs = 0
            lastReplaceUptimeNs = 0
            return Unmanaged.passUnretained(event)
        }

        if isSecureInputActive {
            engine.reset()
            resetRemoteInputState()
            lastReplaceUptimeNs = 0
            return Unmanaged.passUnretained(event)
        }

        let eventTimeNs = event.timestamp != 0 ? event.timestamp : nowNs
        let withinWallWindow = lastReplaceUptimeNs != 0
            && (nowNs &- lastReplaceUptimeNs) <= Self.postReplaceSerializeWindowNs
        let withinEventTsWindow = event.timestamp == 0
            || lastReplaceEventTs == 0
            || (event.timestamp >= lastReplaceEventTs
                && (event.timestamp &- lastReplaceEventTs) <= Self.postReplaceSerializeWindowNs)
        let withinPostReplaceWindow = withinWallWindow && withinEventTsWindow

        let isBackspace = (keyCode == 51)
            || (remoteZeroKeyString == "\u{0008}" || remoteZeroKeyString == "\u{007F}")

        if isBackspace {
            if isRemote && remoteDesktopMode == .smartAuto {
                if lastRemoteBackspaceNs != 0
                    && eventTimeNs >= lastRemoteBackspaceNs
                    && (eventTimeNs &- lastRemoteBackspaceNs) <= Self.remoteBackspaceBurstWindowNs {
                    remoteBackspaceBurstCount += 1
                } else {
                    remoteBackspaceBurstCount = 1
                }
                lastRemoteBackspaceNs = eventTimeNs

                if remoteMobileWordActive {
                    engine.reset()
                    lastReplaceUptimeNs = 0
                    return Unmanaged.passUnretained(event)
                }
                if remoteBackspaceBurstCount >= 2 {
                    engine.reset()
                    lastReplaceUptimeNs = 0
                    remoteAutoReplaceUntilNs = eventTimeNs &+ Self.remoteAutoReplaceWindowNs
                    return Unmanaged.passUnretained(event)
                }
            }
            engine.processBackspace()
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

        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            engine.reset()
            lastReplaceUptimeNs = 0
            return Unmanaged.passUnretained(event)
        }

        // Navigation kills word composition: reset the session.
        if Self.navigationKeyCodes.contains(keyCode) || remoteZeroKeyString == "\u{001B}" {
            SelectionCacheService.shared.invalidate()
            engine.reset()
            remoteMobileWordActive = false
            remoteAutoReplaceUntilNs = 0
            lastRemoteBackspaceNs = 0
            remoteBackspaceBurstCount = 0
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
            remoteAutoReplaceUntilNs = 0
            lastRemoteBackspaceNs = 0
            remoteBackspaceBurstCount = 0
            let action = engine.process(boundaryChar)
            switch action {
            case .pass:
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
            case .replace(let backspaces, let chars):
                var wordChars = chars
                if wordChars.last == boundaryChar {
                    wordChars.removeLast()
                }
                consumeKey(keyCode, isRemote: isRemote)
                lastReplaceUptimeNs = nowNs
                lastReplaceEventTs = event.timestamp
                injector.realize(
                    .replace(backspaces: backspaces, chars: wordChars),
                    pid: targetPID,
                    bundleID: targetBundleID,
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

        let inAutoReplaceBurst = isRemote
            && remoteDesktopMode == .smartAuto
            && remoteAutoReplaceUntilNs != 0
            && eventTimeNs <= remoteAutoReplaceUntilNs
        lastRemoteBackspaceNs = 0
        remoteBackspaceBurstCount = 0

        let characters = remoteZeroKeyString ?? event.keyboardString()
        if characters.isEmpty {
            engine.reset()
            lastReplaceUptimeNs = 0
            return Unmanaged.passUnretained(event)
        }

        if characters.utf16.count > 1 || characters.unicodeScalars.count > 1 {
            engine.reset()
            lastReplaceUptimeNs = 0
            if isRemote && remoteDesktopMode == .smartAuto {
                remoteMobileWordActive = !Self.endsWithWordBoundary(characters)
            }
            return Unmanaged.passUnretained(event)
        }

        guard let scalar = characters.unicodeScalars.first, let ch = characters.first else {
            engine.reset()
            lastReplaceUptimeNs = 0
            return Unmanaged.passUnretained(event)
        }

        if scalar.value < 0x20 || scalar.value == 0x7F {
            engine.reset()
            remoteMobileWordActive = false
            lastReplaceUptimeNs = 0
            return Unmanaged.passUnretained(event)
        }

        if scalar.value > 0x7F {
            engine.reset()
            lastReplaceUptimeNs = 0
            if isRemote && remoteDesktopMode == .smartAuto {
                remoteMobileWordActive = Self.isMobileComposedScalar(scalar)
            }
            return Unmanaged.passUnretained(event)
        }

        if isRemote && remoteDesktopMode == .smartAuto {
            if inAutoReplaceBurst {
                engine.reset()
                lastReplaceUptimeNs = 0
                remoteMobileWordActive = Self.isWordContinuationASCII(scalar)
                return Unmanaged.passUnretained(event)
            }
            if remoteMobileWordActive {
                engine.reset()
                lastReplaceUptimeNs = 0
                if !Self.isWordContinuationASCII(scalar) {
                    remoteMobileWordActive = false
                }
                return Unmanaged.passUnretained(event)
            }
        }

        let action = engine.process(ch)
        switch action {
        case .pass:
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
        case .replace(let backspaces, let chars):
            consumeKey(keyCode, isRemote: isRemote)
            lastReplaceUptimeNs = nowNs
            lastReplaceEventTs = event.timestamp
            injector.realize(
                .replace(backspaces: backspaces, chars: chars),
                pid: targetPID,
                bundleID: targetBundleID,
                triggerTimestamp: event.timestamp,
                proxy: proxy,
                isRemote: isRemote
            )
            return nil
        }
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
        remoteAutoReplaceUntilNs = 0
        lastRemoteBackspaceNs = 0
        remoteBackspaceBurstCount = 0
        remoteZeroKeyConsumedCount = 0
        lastReplaceEventTs = 0
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
