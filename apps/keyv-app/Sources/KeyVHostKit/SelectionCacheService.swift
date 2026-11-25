import Foundation
import AppKit
import ApplicationServices

/// Async AX selected-text cache (Gotcha 1).
///
/// HARD RULE: no AX attribute copy inside the CGEventTap callback — AX is
/// IPC and macOS can kill slow taps (`kCGEventTapDisabledByTimeout`).
/// The tap callback only does an O(1) memory read from this cache; AX calls
/// run coalesced on a utility queue, throttled while typing.
final class SelectionCacheService {
    static let shared = SelectionCacheService()

    private struct Snapshot {
        let characterCount: Int
        let isSecureField: Bool
        let bundleID: String
        let timestamp: Date
    }

    private let lock = NSLock()
    private var snapshot: Snapshot = Snapshot(
        characterCount: 0,
        isSecureField: false,
        bundleID: "",
        timestamp: .distantPast
    )
    private var inFlight = false
    private var generation = 0
    private var lastRequest = Date.distantPast
    /// Là apps có inline auto-complete (browser omnibox…) — ưu tiên refresh.
    private static let proneBundleIDs: Set<String> = [
        "com.google.Chrome",
        "company.thebrowser.Browser",
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

    /// Freshness window: cache answers are trusted within this window.
    private let freshWindow: TimeInterval = 0.6
    /// Coalescing window for AX reads.
    private let throttle: TimeInterval = 0.08

    /// O(1) read for the tap callback. Returns the cached selection count
    /// when it belongs to the same app and is fresh; nil otherwise.
    func cachedSelectionCount(bundleID: String?) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard snapshot.bundleID == (bundleID ?? "") else { return nil }
        guard Date().timeIntervalSince(snapshot.timestamp) <= freshWindow else { return nil }
        return snapshot.characterCount
    }

    func isFocusedElementSecure(bundleID: String?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard snapshot.bundleID == (bundleID ?? "") else { return false }
        guard Date().timeIntervalSince(snapshot.timestamp) <= 2.0 else { return false }
        return snapshot.isSecureField
    }

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        generation += 1
        snapshot = Snapshot(characterCount: 0, isSecureField: false, bundleID: "", timestamp: .distantPast)
    }

    /// Schedule an async refresh (call from key handling paths, never from
    /// synchronous tap-critical code paths that need the value *now*).
    func scheduleRefresh(bundleID: String?) {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        guard !inFlight, now.timeIntervalSince(lastRequest) >= throttle else { return }
        lastRequest = now
        inFlight = true
        let capturedBundle = bundleID ?? ""
        let capturedGeneration = generation
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let (count, isSecure) = Self.readFocusedState()
            guard let self else { return }
            self.lock.lock()
            defer {
                self.inFlight = false
                self.lock.unlock()
            }
            guard capturedGeneration == self.generation else { return }
            self.snapshot = Snapshot(
                characterCount: count,
                isSecureField: isSecure,
                bundleID: capturedBundle,
                timestamp: Date()
            )
        }
    }

    // MARK: - AX read (worker thread only)

    private static func readFocusedState() -> (Int, Bool) {
        let systemWide = AXUIElementCreateSystemWide()

        var focused: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focused)
        guard focusedResult == .success, let element = focused as! AXUIElement? else {
            return (0, false)
        }

        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String,
           role == "AXSecureTextField" {
            return (0, true)
        }

        var subroleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef) == .success,
           let subrole = subroleRef as? String,
           subrole == "AXSecureTextField" {
            return (0, true)
        }

        var selected: CFTypeRef?
        let selectedResult = AXUIElementCopyAttributeValue(
            element, kAXSelectedTextAttribute as CFString, &selected)
        guard selectedResult == .success else { return (0, false) }

        if let text = selected as? String {
            return ((text as NSString).length, false)
        }
        return (0, false)
    }

    func isAutocompleteProneApp(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return Self.proneBundleIDs.contains(bundleID)
    }
}
