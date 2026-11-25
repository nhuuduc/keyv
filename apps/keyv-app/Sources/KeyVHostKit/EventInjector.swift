import AppKit
import KeyVCore
import ApplicationServices
import Darwin

/// Realizes engine actions on screen via serialized session events.
public final class EventInjector {
    public static let syntheticMarker: Int64 = 0x4B65_7956_4556
    public static let autocompleteSpacerScalar: UnicodeScalar = "\u{202F}"

    public enum EmittedEvent: Equatable {
        case virtualKey(keyCode: CGKeyCode, keyDown: Bool, flags: UInt64, timestamp: UInt64)
        case unicode(units: [UniChar], keyDown: Bool, flags: UInt64, timestamp: UInt64)
    }

    public struct ClonedKeyRecord: Equatable {
        public let keyCode: CGKeyCode
        public let keyDown: Bool
        public let flags: UInt64
        public let timestamp: UInt64
    }

    /// Synthetic events carry our own private source and marker so the tap can
    /// pass them through deterministically without feedback loops.
    private let syntheticSource = CGEventSource(stateID: .privateState)

    private let backspaceKeyCode: CGKeyCode = 51
    private let returnKeyCode: CGKeyCode = 36
    private let keypadEnterKeyCode: CGKeyCode = 76
    private let tabKeyCode: CGKeyCode = 48
    private var lastTimestamp: CGEventTimestamp = 0

    public var compatFixEnabled: Bool = true
    public var eventSink: ((EmittedEvent) -> Void)?
    public var compatSpacerOverrideForTesting: ((pid_t, String?) -> Bool)?
    public private(set) var recordedClonedKeys: [ClonedKeyRecord] = []

    public static let compatBundleIDs: Set<String> = [
        "com.google.Chrome",
        "company.thebrowser.Browser",   // Arc
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "com.kagi.kagimacOS",
        "app.zen-browser.zen",
        "com.apple.Safari",
        "org.mozilla.firefox",
        "com.microsoft.Excel",
        "com.apple.Spotlight",
        "com.raycast.macos",
        "com.runningwithcrayons.Alfred",
    ]

    public static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "com.github.wez.wezterm",
        "co.zeit.hyper",
    ]

    private static let strippedModifiers: CGEventFlags = [
        .maskShift,
        .maskControl,
        .maskAlternate,
        .maskCommand,
        .maskAlphaShift,
        .maskSecondaryFn,
        .maskNumericPad,
        .maskHelp,
    ]

    public init(compatFixEnabled: Bool = AppSettings.shared.compatFix) {
        self.compatFixEnabled = compatFixEnabled
    }

    public func clearRecordedClonedKeys() {
        recordedClonedKeys.removeAll()
    }

    public func realize(
        _ action: ViEngineAction,
        pid: pid_t,
        bundleID: String?,
        triggerTimestamp: CGEventTimestamp = 0,
        proxy: CGEventTapProxy? = nil
    ) {
        switch action {
        case .pass:
            break
        case .replace(let backspaces, let chars):
            guard backspaces > 0 else {
                if !chars.isEmpty {
                    postUnicode(chars, minimumTimestamp: triggerTimestamp, proxy: proxy)
                }
                return
            }

            var deleteCount = backspaces
            let bundle = bundleID ?? ""
            let isTerminal = Self.terminalBundleIDs.contains(bundle)
            let isCompat: Bool
            if !compatFixEnabled || isTerminal {
                isCompat = false
            } else if let override = compatSpacerOverrideForTesting {
                isCompat = override(pid, bundleID)
            } else if eventSink != nil {
                isCompat = Self.compatBundleIDs.contains(bundle)
            } else if let axDecision = SelectionCacheService.shared.shouldUseAutocompleteSpacer(
                pid: pid,
                bundleID: bundleID
            ) {
                isCompat = axDecision
            } else {
                isCompat = Self.compatBundleIDs.contains(bundle)
            }

            if isCompat {
                postUnicode(String(Self.autocompleteSpacerScalar), minimumTimestamp: triggerTimestamp, proxy: proxy)
                deleteCount += 1
            }

            postBackspaces(deleteCount, minimumTimestamp: triggerTimestamp, proxy: proxy)
            if !chars.isEmpty {
                postUnicode(chars, minimumTimestamp: triggerTimestamp, proxy: proxy)
            }
        }
    }

    public func postClonedEvent(
        _ original: CGEvent,
        triggerTimestamp: CGEventTimestamp = 0,
        proxy: CGEventTapProxy? = nil
    ) {
        guard let downClone = original.copy() else { return }
        let kc = CGKeyCode(truncatingIfNeeded: original.getIntegerValueField(.keyboardEventKeycode))
        guard let upEvent = CGEvent(keyboardEventSource: syntheticSource, virtualKey: kc, keyDown: false) else {
            return
        }
        upEvent.flags = original.flags
        let str = original.keyboardString()
        let units = Array(str.utf16)
        if !units.isEmpty {
            upEvent.keyboardSetUnicodeString(stringLength: CFIndex(units.count), unicodeString: units)
        }

        let downTS = nextTimestamp(minimum: triggerTimestamp)
        let upTS = nextTimestamp(minimum: downTS)
        downClone.timestamp = downTS
        downClone.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
        upEvent.timestamp = upTS
        upEvent.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)

        if let eventSink {
            recordedClonedKeys.append(
                ClonedKeyRecord(keyCode: kc, keyDown: true, flags: downClone.flags.rawValue, timestamp: downTS)
            )
            recordedClonedKeys.append(
                ClonedKeyRecord(keyCode: kc, keyDown: false, flags: upEvent.flags.rawValue, timestamp: upTS)
            )
            if kc == returnKeyCode || kc == keypadEnterKeyCode || kc == tabKeyCode || kc == backspaceKeyCode || units.isEmpty {
                eventSink(.virtualKey(keyCode: kc, keyDown: true, flags: downClone.flags.rawValue, timestamp: downTS))
                eventSink(.virtualKey(keyCode: kc, keyDown: false, flags: upEvent.flags.rawValue, timestamp: upTS))
            } else {
                eventSink(.unicode(units: units, keyDown: true, flags: downClone.flags.rawValue, timestamp: downTS))
                eventSink(.unicode(units: units, keyDown: false, flags: upEvent.flags.rawValue, timestamp: upTS))
            }
            return
        }

        post(downClone, proxy: proxy)
        post(upEvent, proxy: proxy)
    }

    public func postPassthroughCharacter(
        _ ch: Character,
        triggerTimestamp: CGEventTimestamp = 0,
        proxy: CGEventTapProxy? = nil
    ) {
        postUnicode(String(ch), minimumTimestamp: triggerTimestamp, proxy: proxy)
    }

    // MARK: - Event posting

    private func postBackspaces(_ count: Int, minimumTimestamp: CGEventTimestamp, proxy: CGEventTapProxy?) {
        guard count > 0 else { return }
        for _ in 0..<count {
            postVirtualKey(backspaceKeyCode, minimumTimestamp: minimumTimestamp, proxy: proxy)
        }
    }

    private func postVirtualKey(_ keyCode: CGKeyCode, minimumTimestamp: CGEventTimestamp, proxy: CGEventTapProxy?) {
        guard let keyDown = CGEvent(keyboardEventSource: syntheticSource, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: syntheticSource, virtualKey: keyCode, keyDown: false)
        else { return }
        let downTS = nextTimestamp(minimum: minimumTimestamp)
        let upTS = nextTimestamp(minimum: downTS)
        stamp(keyDown, timestamp: downTS)
        stamp(keyUp, timestamp: upTS)
        if let eventSink {
            eventSink(.virtualKey(keyCode: keyCode, keyDown: true, flags: keyDown.flags.rawValue, timestamp: downTS))
            eventSink(.virtualKey(keyCode: keyCode, keyDown: false, flags: keyUp.flags.rawValue, timestamp: upTS))
            return
        }
        post(keyDown, proxy: proxy)
        post(keyUp, proxy: proxy)
    }

    private func postUnicode(_ string: String, minimumTimestamp: CGEventTimestamp, proxy: CGEventTapProxy?) {
        guard !string.isEmpty else { return }
        for ch in string {
            if ch == "\n" || ch == "\r" {
                postVirtualKey(returnKeyCode, minimumTimestamp: minimumTimestamp, proxy: proxy)
                continue
            }
            if ch == "\t" {
                postVirtualKey(tabKeyCode, minimumTimestamp: minimumTimestamp, proxy: proxy)
                continue
            }
            let units = Array(String(ch).utf16)
            postSingleCharacter(units, minimumTimestamp: minimumTimestamp, proxy: proxy)
        }
    }

    private func postSingleCharacter(_ utf16Units: [UniChar], minimumTimestamp: CGEventTimestamp, proxy: CGEventTapProxy?) {
        guard !utf16Units.isEmpty,
              let keyDown = CGEvent(keyboardEventSource: syntheticSource, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: syntheticSource, virtualKey: 0, keyDown: false)
        else { return }
        let downTS = nextTimestamp(minimum: minimumTimestamp)
        let upTS = nextTimestamp(minimum: downTS)
        stamp(keyDown, timestamp: downTS)
        stamp(keyUp, timestamp: upTS)
        keyDown.keyboardSetUnicodeString(stringLength: CFIndex(utf16Units.count), unicodeString: utf16Units)
        keyUp.keyboardSetUnicodeString(stringLength: CFIndex(utf16Units.count), unicodeString: utf16Units)
        if let eventSink {
            eventSink(.unicode(units: utf16Units, keyDown: true, flags: keyDown.flags.rawValue, timestamp: downTS))
            eventSink(.unicode(units: utf16Units, keyDown: false, flags: keyUp.flags.rawValue, timestamp: upTS))
            return
        }
        post(keyDown, proxy: proxy)
        post(keyUp, proxy: proxy)
    }

    private func post(_ event: CGEvent, proxy: CGEventTapProxy?) {
        if let proxy {
            event.tapPostEvent(proxy)
        } else {
            event.post(tap: .cgSessionEventTap)
        }
    }

    private func nextTimestamp(minimum: CGEventTimestamp) -> CGEventTimestamp {
        let now = mach_absolute_time()
        let base = max(now, minimum)
        let candidate = base > lastTimestamp ? base : (lastTimestamp &+ 1_000)
        lastTimestamp = candidate
        return candidate
    }

    private func stamp(_ event: CGEvent, timestamp: CGEventTimestamp) {
        event.flags.subtract(Self.strippedModifiers)
        event.timestamp = timestamp
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
    }
}
