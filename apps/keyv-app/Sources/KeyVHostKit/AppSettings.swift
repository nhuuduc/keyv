import Foundation
import Carbon.HIToolbox
import KeyVCore

public enum RemoteDesktopMode: Int, CaseIterable, Sendable {
    case smartAuto = 0
    case phoneKeyboardOnly = 1
    case alwaysKeyV = 2

    public var shortTitle: String {
        switch self {
        case .smartAuto:
            return "Tự động thông minh (Khuyên dùng)"
        case .phoneKeyboardOnly:
            return "Nhường bàn phím điện thoại"
        case .alwaysKeyV:
            return "Luôn dùng KeyV"
        }
    }

    public var menuTitle: String {
        switch self {
        case .smartAuto:
            return "Tự động thông minh — nhận diện bàn phím ĐT & Telex"
        case .phoneKeyboardOnly:
            return "Nhường hoàn toàn bàn phím điện thoại"
        case .alwaysKeyV:
            return "Luôn dùng bộ gõ KeyV (bàn phím ĐT tiếng Anh)"
        }
    }

    public var detailSubtitle: String {
        switch self {
        case .smartAuto:
            return "Tự nhận diện khi bàn phím điện thoại đã gõ sẵn tiếng Việt hoặc gợi ý từ để tránh lỗi chồng dấu, đồng thời vẫn gõ Telex mượt khi điện thoại để bàn phím tiếng Anh. Bàn phím vật lý trên máy Mac luôn hoạt động bình thường."
        case .phoneKeyboardOnly:
            return "Chuyển thẳng 100% phím từ RustDesk / điều khiển từ xa để dùng bàn phím tiếng Việt trên iOS/Android. Bàn phím vật lý trên máy Mac vẫn giữ nguyên chế độ gõ Tiếng Việt mà không cần bấm chuyển V/E."
        case .alwaysKeyV:
            return "Luôn dùng bộ gõ KeyV cho các phím ký tự đơn gửi từ xa (phù hợp khi điện thoại cố định ở bàn phím tiếng Anh), đồng thời vẫn giữ nguyên chuỗi nhiều ký tự khi dán văn bản hoặc chèn emoji."
        }
    }
}

/// Global engine settings persisted to UserDefaults, with change callbacks.
public final class AppSettings: NSObject {
    public static let shared = AppSettings()
    public static let currentSchemaVersion = 3

    private let defaults = UserDefaults.standard
    private let changedNotification = Notification.Name("KeyVSettingsChanged")

    override init() {
        defaults.register(defaults: [
            "method": ViInputMethod.telex.rawValue,
            "orthography": ViOrthography.traditional.rawValue,
            "macroEnabled": false,
            "allowWAsConsonant": true,
            "repeatedRestore": true,
            "spellCheck": true,
            "compatFix": true,
            "autoCapitalize": false,
            "beepOnModeSwitch": true,
            "ctrlShiftSwitch": true,
            "toggleHotKeyCode": 6,
            "toggleHotKeyModifiers": UInt(optionKey),
            "autoCheckUpdates": true,
            "lastVietnameseMethod": ViInputMethod.telex.rawValue,
            "overlayHotKeyCode": 49,
            "overlayHotKeyModifiers": UInt(optionKey),
            "clipboardRetentionLimit": 200,
            "remoteDesktopMode": RemoteDesktopMode.smartAuto.rawValue,
        ])
        super.init()
    }

    public func migrateLegacyDefaultsIfNeeded(in targetDefaults: UserDefaults? = nil) {
        let store = targetDefaults ?? defaults
        let previousSchema = store.integer(forKey: "settingsSchemaVersion")
        guard previousSchema < Self.currentSchemaVersion else { return }
        if previousSchema < 2 {
            store.set(true, forKey: "allowWAsConsonant")
            store.set(true, forKey: "repeatedRestore")
            store.set(true, forKey: "spellCheck")
            store.set(true, forKey: "compatFix")
        }
        if store.object(forKey: "remoteDesktopMode") == nil {
            store.set(RemoteDesktopMode.smartAuto.rawValue, forKey: "remoteDesktopMode")
        }
        store.set(Self.currentSchemaVersion, forKey: "settingsSchemaVersion")
        if targetDefaults == nil {
            notifyChanged()
        }
    }

    public func resetEngineDefaults() {
        defaults.set(ViInputMethod.telex.rawValue, forKey: "method")
        defaults.set(ViInputMethod.telex.rawValue, forKey: "lastVietnameseMethod")
        defaults.set(ViOrthography.traditional.rawValue, forKey: "orthography")
        defaults.set(true, forKey: "allowWAsConsonant")
        storeBoolAndNotify()
    }

    private func storeBoolAndNotify() {
        defaults.set(true, forKey: "repeatedRestore")
        defaults.set(true, forKey: "spellCheck")
        defaults.set(true, forKey: "compatFix")
        defaults.set(false, forKey: "autoCapitalize")
        defaults.set(Self.currentSchemaVersion, forKey: "settingsSchemaVersion")
        notifyChanged()
    }

    public var method: ViInputMethod {
        get { defaults.object(forKey: "method") == nil ? .telex : (ViInputMethod(rawValue: defaults.integer(forKey: "method")) ?? .telex) }
        set { defaults.set(newValue.rawValue, forKey: "method"); notifyChanged() }
    }

    public var orthography: ViOrthography {
        get { ViOrthography(rawValue: defaults.integer(forKey: "orthography")) ?? .traditional }
        set { defaults.set(newValue.rawValue, forKey: "orthography"); notifyChanged() }
    }

    public var macroEnabled: Bool {
        get { defaults.bool(forKey: "macroEnabled") }
        set { defaults.set(newValue, forKey: "macroEnabled"); notifyChanged() }
    }

    public var allowWAsConsonant: Bool {
        get { defaults.object(forKey: "allowWAsConsonant") == nil ? true : defaults.bool(forKey: "allowWAsConsonant") }
        set { defaults.set(newValue, forKey: "allowWAsConsonant"); notifyChanged() }
    }

    /// Unikey repeated-key restore ("bar" → "bả" → "bar" bằng phím r lần 2).
    public var repeatedRestore: Bool {
        get { defaults.object(forKey: "repeatedRestore") == nil ? true : defaults.bool(forKey: "repeatedRestore") }
        set { defaults.set(newValue, forKey: "repeatedRestore"); notifyChanged() }
    }

    /// Kiểm tra chính tả tiếng Việt & tự khôi phục từ tiếng Anh.
    public var spellCheck: Bool {
        get { defaults.object(forKey: "spellCheck") == nil ? true : defaults.bool(forKey: "spellCheck") }
        set { defaults.set(newValue, forKey: "spellCheck"); notifyChanged() }
    }

    /// "Sửa lỗi gợi ý (trình duyệt, Excel,...)" — chèn U+202F force-deselect
    /// cho các app compatibility có inline autocomplete.
    public var compatFix: Bool {
        get { defaults.object(forKey: "compatFix") == nil ? true : defaults.bool(forKey: "compatFix") }
        set { defaults.set(newValue, forKey: "compatFix"); notifyChanged() }
    }

    /// Viết hoa chữ cái đầu câu (sau . ! ?).
    public var autoCapitalize: Bool {
        get { defaults.bool(forKey: "autoCapitalize") }
        set { defaults.set(newValue, forKey: "autoCapitalize"); notifyChanged() }
    }

    /// Kêu beep khi chuyển chế độ gõ (Tiếng Việt ↔ English).
    public var beepOnModeSwitch: Bool {
        get { defaults.object(forKey: "beepOnModeSwitch") == nil ? true : defaults.bool(forKey: "beepOnModeSwitch") }
        set { defaults.set(newValue, forKey: "beepOnModeSwitch"); notifyChanged() }
    }

    /// Đổi nhanh Việt / Anh bằng tổ hợp Ctrl + Shift (kiểu UniKey Windows).
    public var ctrlShiftSwitch: Bool {
        get { defaults.object(forKey: "ctrlShiftSwitch") == nil ? true : defaults.bool(forKey: "ctrlShiftSwitch") }
        set { defaults.set(newValue, forKey: "ctrlShiftSwitch"); notifyChanged() }
    }

    public var toggleHotKeyCode: Int {
        get { defaults.object(forKey: "toggleHotKeyCode") == nil ? 6 : defaults.integer(forKey: "toggleHotKeyCode") }
        set { defaults.set(newValue, forKey: "toggleHotKeyCode"); notifyChanged() }
    }

    public var toggleHotKeyModifiers: UInt {
        get {
            guard let stored = defaults.object(forKey: "toggleHotKeyModifiers") as? UInt else {
                return UInt(optionKey)
            }
            return stored
        }
        set { defaults.set(newValue, forKey: "toggleHotKeyModifiers"); notifyChanged() }
    }

    public var autoCheckUpdates: Bool {
        get { defaults.object(forKey: "autoCheckUpdates") == nil ? true : defaults.bool(forKey: "autoCheckUpdates") }
        set { defaults.set(newValue, forKey: "autoCheckUpdates"); notifyChanged() }
    }

    public var lastUpdateCheckTimestamp: Double {
        get { defaults.double(forKey: "lastUpdateCheckTimestamp") }
        set { defaults.set(newValue, forKey: "lastUpdateCheckTimestamp") }
    }

    /// Chế độ gõ đang "hiển thị" ở menu bar: English (off) hay Vietnamese.
    public var isEnglishMode: Bool { method == .off }

    /// Nhớ phương thức VN cuối cùng để quay lại khi bật Tiếng Việt từ English.
    public var lastVietnameseMethod: ViInputMethod {
        get {
            ViInputMethod(rawValue: defaults.integer(forKey: "lastVietnameseMethod")).flatMap { $0 == .off ? nil : $0 }
                ?? .telex
        }
        set {
            guard newValue != .off else { return }
            defaults.set(newValue.rawValue, forKey: "lastVietnameseMethod")
        }
    }

    public var overlayHotKeyCode: Int {
        get { defaults.object(forKey: "overlayHotKeyCode") == nil ? 49 : defaults.integer(forKey: "overlayHotKeyCode") }
        set { defaults.set(newValue, forKey: "overlayHotKeyCode"); notifyChanged() }
    }

    public var overlayHotKeyModifiers: UInt {
        get {
            guard let stored = defaults.object(forKey: "overlayHotKeyModifiers") as? UInt else {
                return UInt(optionKey)
            }
            return stored
        }
        set { defaults.set(newValue, forKey: "overlayHotKeyModifiers"); notifyChanged() }
    }

    public var clipboardRetentionLimit: Int {
        get { defaults.object(forKey: "clipboardRetentionLimit") == nil ? 200 : defaults.integer(forKey: "clipboardRetentionLimit") }
        set { defaults.set(newValue, forKey: "clipboardRetentionLimit"); notifyChanged() }
    }

    public var remoteDesktopMode: RemoteDesktopMode {
        get {
            guard defaults.object(forKey: "remoteDesktopMode") != nil else { return .smartAuto }
            return RemoteDesktopMode(rawValue: defaults.integer(forKey: "remoteDesktopMode")) ?? .smartAuto
        }
        set {
            defaults.set(newValue.rawValue, forKey: "remoteDesktopMode")
            notifyChanged()
        }
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
        if Thread.isMainThread {
            NotificationCenter.default.post(name: changedNotification, object: self)
        } else {
            DispatchQueue.main.async { [changedNotification] in
                NotificationCenter.default.post(name: changedNotification, object: self)
            }
        }
    }

    /// Observe changes to refresh the live engine.
    func onChange(target: AnyObject, selector: Selector) {
        NotificationCenter.default.addObserver(target, selector: selector, name: changedNotification, object: self)
    }
}
