import Foundation
import Carbon.HIToolbox
import KeyVCore

/// Global engine settings persisted to UserDefaults, with change callbacks.
final class AppSettings: NSObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard
    private let changedNotification = Notification.Name("KeyVSettingsChanged")

    var method: ViInputMethod {
        get { defaults.object(forKey: "method") == nil ? .telex : (ViInputMethod(rawValue: defaults.integer(forKey: "method")) ?? .telex) }
        set { defaults.set(newValue.rawValue, forKey: "method"); notifyChanged() }
    }

    var orthography: ViOrthography {
        get { ViOrthography(rawValue: defaults.integer(forKey: "orthography")) ?? .traditional }
        set { defaults.set(newValue.rawValue, forKey: "orthography"); notifyChanged() }
    }

    var macroEnabled: Bool {
        get { defaults.bool(forKey: "macroEnabled") }
        set { defaults.set(newValue, forKey: "macroEnabled"); notifyChanged() }
    }

    var allowWAsConsonant: Bool {
        get { defaults.object(forKey: "allowWAsConsonant") == nil ? true : defaults.bool(forKey: "allowWAsConsonant") }
        set { defaults.set(newValue, forKey: "allowWAsConsonant"); notifyChanged() }
    }

    /// Unikey repeated-key restore ("bar" → "bả" → "bar" bằng phím r lần 2).
    var repeatedRestore: Bool {
        get { defaults.object(forKey: "repeatedRestore") == nil ? true : defaults.bool(forKey: "repeatedRestore") }
        set { defaults.set(newValue, forKey: "repeatedRestore"); notifyChanged() }
    }

    /// "Sửa lỗi gõ ý (trình duyệt, Excel,...)" — chèn U+200C force-deselect
    /// cho các app compatibility là inline autocomplete.
    var compatFix: Bool {
        get { defaults.object(forKey: "compatFix") == nil ? true : defaults.bool(forKey: "compatFix") }
        set { defaults.set(newValue, forKey: "compatFix"); notifyChanged() }
    }

    /// Viết hoa chữ cái đầu câu (sau . ! ?).
    var autoCapitalize: Bool {
        get { defaults.bool(forKey: "autoCapitalize") }
        set { defaults.set(newValue, forKey: "autoCapitalize"); notifyChanged() }
    }

    /// Kêu beep khi chuyển chế độ gõ (Tiếng Việt ↔ English).
    var beepOnModeSwitch: Bool {
        get { defaults.object(forKey: "beepOnModeSwitch") == nil ? true : defaults.bool(forKey: "beepOnModeSwitch") }
        set { defaults.set(newValue, forKey: "beepOnModeSwitch"); notifyChanged() }
    }

    /// Chế độ gõ đang "hiển thị" ở menu bar: English (off) hay Vietnamese.
    var isEnglishMode: Bool { method == .off }

    /// Nhớ phương thức VN cuối cùng để quay lại khi bật Tiếng Việt từ English.
    var lastVietnameseMethod: ViInputMethod {
        get {
            ViInputMethod(rawValue: defaults.integer(forKey: "lastVietnameseMethod")).flatMap { $0 == .off ? nil : $0 }
                ?? .telex
        }
        set {
            guard newValue != .off else { return }
            defaults.set(newValue.rawValue, forKey: "lastVietnameseMethod")
        }
    }

    var overlayHotKeyCode: Int {
        get { defaults.object(forKey: "overlayHotKeyCode") == nil ? 49 : defaults.integer(forKey: "overlayHotKeyCode") } // Space
        set { defaults.set(newValue, forKey: "overlayHotKeyCode"); notifyChanged() }
    }

    var overlayHotKeyModifiers: UInt {
        get {
            guard let stored = defaults.object(forKey: "overlayHotKeyModifiers") as? UInt else {
                return UInt(optionKey)
            }
            return stored
        }
        set { defaults.set(newValue, forKey: "overlayHotKeyModifiers"); notifyChanged() }
    }

    var clipboardRetentionLimit: Int {
        get { defaults.object(forKey: "clipboardRetentionLimit") == nil ? 200 : defaults.integer(forKey: "clipboardRetentionLimit") }
        set { defaults.set(newValue, forKey: "clipboardRetentionLimit"); notifyChanged() }
    }

    // MARK: Seen apps (for the per-app editor's suggestions)

    /// bundleID → display name, recorded when apps are activated while KeyV runs.
    var seenAppsJSON: [String: String] {
        get {
            guard let data = defaults.data(forKey: "seenApps"),
                  let dict = try? JSONDecoder().decode([String: String].self, from: data)
            else { return [:] }
            return dict
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: "seenApps")
            }
        }
    }

    func noteSeenApp(bundleID: String, name: String) {
        var seen = seenAppsJSON
        guard seen[bundleID] != name else { return }
        seen[bundleID] = name
        seenAppsJSON = seen
        NotificationCenter.default.post(
            name: Notification.Name("KeyVSeenAppsChanged"), object: self)
    }

    // MARK: Per-app profiles (bundleID → enabled/EN mode)

    struct AppOverride: Codable {
        var useModeRaw: Int?      // ViInputMethod, nil = global
        var orthographyRaw: Int?  // ViOrthography, nil = global

        var useMode: ViInputMethod? { useModeRaw.flatMap(ViInputMethod.init(rawValue:)) }
        var orthography: ViOrthography? { orthographyRaw.flatMap(ViOrthography.init(rawValue:)) }

        init(useMode: ViInputMethod?, orthography: ViOrthography?) {
            self.useModeRaw = useMode?.rawValue
            self.orthographyRaw = orthography?.rawValue
        }
    }

    var appOverridesJSON: [String: AppOverride] {
        get {
            guard let data = defaults.data(forKey: "appOverrides"),
                  let dict = try? JSONDecoder().decode([String: AppOverride].self, from: data)
            else { return [:] }
            return dict
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: "appOverrides")
                notifyChanged()
            }
        }
    }

    /// Effective (inputMethod, orthography) for the app currently being typed into.
    func effectiveFor(bundleID: String?) -> (method: ViInputMethod, orthography: ViOrthography) {
        var method = self.method
        var orthography = self.orthography
        if let bundleID, let override = appOverridesJSON[bundleID] {
            if let m = override.useMode { method = m }
            if let o = override.orthography { orthography = o }
        }
        return (method, orthography)
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: changedNotification, object: self)
    }

    /// Observe changes to refresh the live engine.
    func onChange(target: AnyObject, selector: Selector) {
        NotificationCenter.default.addObserver(target, selector: selector, name: changedNotification, object: self)
    }
}
