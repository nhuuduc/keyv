import AppKit
import KeyVCore
import ApplicationServices

/// Realizes engine actions on screen, targeted at the frontmost app's pid
/// (`CGEventPostToPid`) — per-app events avoid disturbing other windows.
///
/// Race defense for inline autocomplete ("dđ" root cause):
/// - selection known (fresh cache) and non-empty → +1 backspace first (one
///   backspace clears the whole active selection), then engine's own;
/// - selection unknown/stale → insert U+200C first (force-deselects any
///   active inline suggestion), then +1 backspace to remove it;
/// - selection known 0 → engine count only.
final class EventInjector {
    /// Synthetic events carry our own private source so the tap can ignore /
    /// consume them deterministically (no feedback loops, no double-apply).
    private let syntheticSource = CGEventSource(stateID: .privateState)

    private let selectionCache = SelectionCacheService.shared
    private let backspaceKeyCode: CGKeyCode = 51

    private static let compatBundleIDs: Set<String> = [
        "com.google.Chrome",
        "company.thebrowser.Browser",   // Arc
        "com.apple.Safari",
        "org.mozilla.firefox",
        "app.notion.Notion",
        "figma.desktop",
    ]

    func realize(_ action: ViEngineAction, pid: pid_t, bundleID: String?) {
        switch action {
        case .pass:
            break
        case .replace(let backspaces, let chars):
            guard backspaces > 0 else {
                postUnicode(chars, pid: pid)
                return
            }
            var deleteCount = backspaces

            let isCompat = AppSettings.shared.compatFix
                && Self.compatBundleIDs.contains(bundleID ?? "")
            if isCompat {
                // Chromium-family inline autocomplete: always force-deselect
                // with the empty character (OpenKey workaround, but posted
                // per-pid and gated by the prone-app list).
                postUnicode("\u{200C}", pid: pid)
                deleteCount += 1
            } else if let sel = selectionCache.cachedSelectionCount(bundleID: bundleID) {
                if sel > 0 {
                    deleteCount += 1  // one backspace clears the whole selection
                }
            } else {
                // Cache stale even though engine wants a rewrite — play safe.
                postUnicode("\u{200C}", pid: pid)
                deleteCount += 1
            }

            postBackspaces(deleteCount, pid: pid)
            postUnicode(chars, pid: pid)
        }
    }

    // MARK: - Event posting

    private func postBackspaces(_ count: Int, pid: pid_t) {
        guard count > 0 else { return }
        guard let keyDown = CGEvent(keyboardEventSource: syntheticSource, virtualKey: backspaceKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: syntheticSource, virtualKey: backspaceKeyCode, keyDown: false)
        else { return }
        for _ in 0..<count {
            keyDown.postToPid(pid)
            keyUp.postToPid(pid)
        }
    }

    private func postUnicode(_ string: String, pid: pid_t) {
        guard !string.isEmpty,
              let keyDown = CGEvent(keyboardEventSource: syntheticSource, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: syntheticSource, virtualKey: 0, keyDown: false)
        else { return }
        keyDown.keyboardSetUnicodeString(stringLength: CFIndex(string.utf16.count), unicodeString: Array(string.utf16))
        keyUp.keyboardSetUnicodeString(stringLength: CFIndex(string.utf16.count), unicodeString: Array(string.utf16))
        keyDown.postToPid(pid)
        keyUp.postToPid(pid)
    }
}
