import Foundation
import KeyVCore
import AppKit
import ApplicationServices
import CoreGraphics

/// CGEventTap controller with auto re-arm on
/// `kCGEventTapDisabledByTimeout` / `ByUserInput` (Gotcha 1 listener).
///
/// Threading: the tap is installed on the main run loop, so key handling and
/// engine state live on the main thread. The callback is fast: O(1) cache
/// reads only — no AX IPC from inside (see SelectionCacheService).
final class TapController: NSObject {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    var engine: ViEngine
    private let injector: EventInjector

    init(engine: ViEngine, injector: EventInjector) {
        self.engine = engine
        self.injector = injector
        super.init()
    }

    @discardableResult
    func install() -> Bool {
        if tap != nil { return true }
        let mask = [CGEventType.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            .reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<TapController>.fromOpaque(userInfo).takeUnretainedValue()
            return controller.handleEvent(type: type, event: event)
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
        return true
    }

    func uninstall() {
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

    // MARK: - Event handling

    fileprivate func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Gotcha 1: re-arm when the system kills the tap.
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return nil
        default:
            break
        }

        // Synthetic events must reach the target app without re-entering the engine.
        let sourceID = CGEventSourceStateID(
            rawValue: Int32(truncatingIfNeeded: event.getIntegerValueField(.eventSourceStateID)))
        if sourceID == .privateState {
            return Unmanaged.passUnretained(event)
        }
        if type != .keyDown || !event.flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty {
            engine.reset()
            SelectionCacheService.shared.invalidate()
            return Unmanaged.passUnretained(event)
        }

        // Navigation kills word composition: reset the session.
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if Self.navigationKeyCodes.contains(keyCode) {
            engine.reset()
            SelectionCacheService.shared.invalidate()
            return Unmanaged.passUnretained(event)
        }

        let characters = event.keyboardString()
        guard characters.count == 1, let ch = characters.first else {
            engine.reset()
            SelectionCacheService.shared.invalidate()
            return Unmanaged.passUnretained(event)
        }

        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.processIdentifier != 0
        else {
            return Unmanaged.passUnretained(event)
        }
        let bundleID = frontmost.bundleIdentifier

        // Prefetch selection state for the NEXT replace (async + throttled).
        SelectionCacheService.shared.scheduleRefresh(bundleID: bundleID)

        let action = engine.process(ch)
        switch action {
        case .pass:
            return Unmanaged.passUnretained(event)
        case .replace(let backspaces, let chars):
            injector.realize(.replace(backspaces: backspaces, chars: chars),
                             pid: frontmost.processIdentifier,
                             bundleID: bundleID)
            return nil
        }
    }

    private static let navigationKeyCodes: Set<Int> = [
        123, 124, 125, 126,   // arrows
        115, 119,             // home / end
        117, 51, 53, 48, 36, 76, // delete, escape, tab, return, keypad enter
    ]
}

// MARK: - CGEvent helpers

extension CGEvent {
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
