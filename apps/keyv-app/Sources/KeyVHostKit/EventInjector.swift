import AppKit
import KeyVCore
import ApplicationServices

/// Realizes engine actions on screen via serialized session events.
final class EventInjector {
    static let syntheticMarker: Int64 = 0x4B65_7956_4556

    /// Synthetic events carry our own private source and marker so the tap can
    /// pass them through deterministically without feedback loops.
    private let syntheticSource = CGEventSource(stateID: .privateState)

    private let selectionCache = SelectionCacheService.shared
    private let backspaceKeyCode: CGKeyCode = 51
    private let maxUnicodeChunkUTF16 = 16

    private static let compatBundleIDs: Set<String> = [
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
        "app.notion.Notion",
        "figma.desktop",
        "com.microsoft.Excel",
    ]

    private static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "com.github.wez.wezterm",
        "co.zeit.hyper",
    ]

    func realize(_ action: ViEngineAction, pid: pid_t, bundleID: String?) {
        switch action {
        case .pass:
            break
        case .replace(let backspaces, let chars):
            guard backspaces > 0 else {
                if !chars.isEmpty {
                    postUnicode(chars)
                }
                return
            }

            var deleteCount = backspaces
            let bundle = bundleID ?? ""
            let isTerminal = Self.terminalBundleIDs.contains(bundle)
            let isCompat = !isTerminal
                && AppSettings.shared.compatFix
                && Self.compatBundleIDs.contains(bundle)

            if isCompat {
                let knownSelection = selectionCache.cachedSelectionCount(bundleID: bundleID)
                if let sel = knownSelection {
                    if sel > 0 {
                        deleteCount += 1
                    }
                } else {
                    postUnicode("\u{200C}")
                    deleteCount += 1
                }
            } else if !isTerminal, let sel = selectionCache.cachedSelectionCount(bundleID: bundleID), sel > 0 {
                deleteCount += 1
            }

            postBackspaces(deleteCount)
            if !chars.isEmpty {
                postUnicode(chars)
            }
        }
    }

    // MARK: - Event posting

    private func postBackspaces(_ count: Int) {
        guard count > 0 else { return }
        for _ in 0..<count {
            guard let keyDown = CGEvent(keyboardEventSource: syntheticSource, virtualKey: backspaceKeyCode, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: syntheticSource, virtualKey: backspaceKeyCode, keyDown: false)
            else { continue }
            stamp(keyDown)
            stamp(keyUp)
            keyDown.post(tap: .cgSessionEventTap)
            keyUp.post(tap: .cgSessionEventTap)
        }
    }

    private func postUnicode(_ string: String) {
        guard !string.isEmpty else { return }
        var chunk: [UniChar] = []
        chunk.reserveCapacity(maxUnicodeChunkUTF16)

        for ch in string {
            let units = Array(String(ch).utf16)
            if !chunk.isEmpty && chunk.count + units.count > maxUnicodeChunkUTF16 {
                postUnicodeChunk(chunk)
                chunk.removeAll(keepingCapacity: true)
            }
            chunk.append(contentsOf: units)
        }
        if !chunk.isEmpty {
            postUnicodeChunk(chunk)
        }
    }

    private func postUnicodeChunk(_ utf16Units: [UniChar]) {
        guard !utf16Units.isEmpty,
              let keyDown = CGEvent(keyboardEventSource: syntheticSource, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: syntheticSource, virtualKey: 0, keyDown: false)
        else { return }
        stamp(keyDown)
        stamp(keyUp)
        keyDown.keyboardSetUnicodeString(stringLength: CFIndex(utf16Units.count), unicodeString: utf16Units)
        keyUp.keyboardSetUnicodeString(stringLength: CFIndex(utf16Units.count), unicodeString: utf16Units)
        keyDown.post(tap: .cgSessionEventTap)
        keyUp.post(tap: .cgSessionEventTap)
    }

    private func stamp(_ event: CGEvent) {
        event.flags = .maskNonCoalesced
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
    }
}
