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
    public var activeBundleID: String?
    public var activePID: pid_t = 0
    public var onModeToggleShortcut: (() -> Void)?
    public var ctrlShiftSwitchEnabled: Bool
    public var isSecureInputActive: Bool = false

    private var ctrlShiftArmed = false
    private var ctrlShiftDisqualified = false
    private var consumedKeyLo: UInt64 = 0
    private var consumedKeyHi: UInt64 = 0
    private var lastReplaceUptimeNs: UInt64 = 0
    private var needsFrontmostRefresh = false

    private static let postReplaceSerializeWindowNs: UInt64 = 80_000_000
    private static let blockingModifiers: CGEventFlags = [
        .maskCommand,
        .maskControl,
        .maskAlternate,
        .maskSecondaryFn,
        .maskHelp,
    ]

    public init(engine: ViEngine, injector: EventInjector) {
        self.engine = engine
        self.injector = injector
        self.ctrlShiftSwitchEnabled = AppSettings.shared.ctrlShiftSwitch
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

        if type == .keyUp {
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
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
            lastReplaceUptimeNs = 0
            needsFrontmostRefresh = true
            SelectionCacheService.shared.invalidate()
            refreshSecureInputState()
            return Unmanaged.passUnretained(event)
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
        _ = takeConsumedKey(keyCode)

        if !event.flags.intersection(Self.blockingModifiers).isEmpty
            || (keyCode != 76 && event.flags.contains(.maskNumericPad)) {
            SelectionCacheService.shared.invalidate()
            engine.reset()
            lastReplaceUptimeNs = 0
            return Unmanaged.passUnretained(event)
        }

        if isSecureInputActive {
            engine.reset()
            lastReplaceUptimeNs = 0
            return Unmanaged.passUnretained(event)
        }

        let nowNs = DispatchTime.now().uptimeNanoseconds
        let withinPostReplaceWindow = lastReplaceUptimeNs != 0
            && (nowNs &- lastReplaceUptimeNs) <= Self.postReplaceSerializeWindowNs

        if keyCode == 51 {
            engine.processBackspace()
            if withinPostReplaceWindow {
                markKeyConsumed(keyCode)
                injector.postClonedEvent(event, triggerTimestamp: event.timestamp, proxy: proxy)
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
        if Self.navigationKeyCodes.contains(keyCode) {
            SelectionCacheService.shared.invalidate()
            engine.reset()
            lastReplaceUptimeNs = 0
            return Unmanaged.passUnretained(event)
        }

        if keyCode == 36 || keyCode == 76 || keyCode == 48 {
            SelectionCacheService.shared.invalidate()
            let boundaryChar: Character = (keyCode == 48) ? "\t" : "\r"
            let action = engine.process(boundaryChar)
            switch action {
            case .pass:
                if withinPostReplaceWindow {
                    markKeyConsumed(keyCode)
                    injector.postClonedEvent(event, triggerTimestamp: event.timestamp, proxy: proxy)
                    return nil
                }
                return Unmanaged.passUnretained(event)
            case .replace(let backspaces, let chars):
                var wordChars = chars
                if wordChars.last == boundaryChar {
                    wordChars.removeLast()
                }
                markKeyConsumed(keyCode)
                lastReplaceUptimeNs = nowNs
                injector.realize(
                    .replace(backspaces: backspaces, chars: wordChars),
                    pid: targetPID,
                    bundleID: targetBundleID,
                    triggerTimestamp: event.timestamp,
                    proxy: proxy
                )
                injector.postClonedEvent(event, triggerTimestamp: event.timestamp, proxy: proxy)
                return nil
            }
        }

        let characters = event.keyboardString()
        guard characters.count == 1, let ch = characters.first else {
            engine.reset()
            lastReplaceUptimeNs = 0
            return Unmanaged.passUnretained(event)
        }

        let action = engine.process(ch)
        switch action {
        case .pass:
            if withinPostReplaceWindow {
                markKeyConsumed(keyCode)
                injector.postClonedEvent(event, triggerTimestamp: event.timestamp, proxy: proxy)
                return nil
            }
            return Unmanaged.passUnretained(event)
        case .replace(let backspaces, let chars):
            markKeyConsumed(keyCode)
            lastReplaceUptimeNs = nowNs
            injector.realize(
                .replace(backspaces: backspaces, chars: chars),
                pid: targetPID,
                bundleID: targetBundleID,
                triggerTimestamp: event.timestamp,
                proxy: proxy
            )
            return nil
        }
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
