import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import Carbon.HIToolbox
import KeyVCore

/// Settings window: OpenKey-style control panel.
/// Top = live controls (Điều khiển); below = tabs (Bộ gõ / Gõ tắt /
/// Hệ thống / Thông tin).
public struct SettingsRootView: View {
    @ObservedObject private var model = SettingsModel.shared

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "keyboard").font(.title2).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text("KeyV").font(.title2.bold())
                    Text("Bộ gõ tiếng Việt và lịch sử clipboard").foregroundStyle(.secondary)
                }
                Spacer()
            }.padding([.horizontal, .top], 20)
            ControlPanelSection(model: model)
                .padding(.bottom, 8)

            TabView {
                SettingsEngineTab(model: model)
                    .tabItem { Text("Bộ gõ") }

                SettingsAppsTab(model: model)
                    .tabItem { Text("Ứng dụng") }

                SettingsMacroTab(model: model)
                    .tabItem { Text("Gõ tắt") }

                SettingsSystemTab(model: model)
                    .tabItem { Text("Hệ thống") }

                SettingsAboutTab()
                    .tabItem { Text("Thông tin") }
            }
        }
        .frame(width: 680, height: 620)
    }
}

// MARK: - ĐIỀU KHIỂN (top section, always visible)

private struct ControlPanelSection: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(spacing: 12) {
            GroupBox {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Ngôn ngữ đang gõ", systemImage: "keyboard")
                            .font(.headline)
                        Picker("Ngôn ngữ", selection: $model.isEnglishMode) {
                            Text("Tiếng Việt").tag(false)
                            Text("English").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Text("Có thể đổi trong menu V/E trên thanh menu macOS.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Kiểu gõ", selection: $model.method) {
                            Text("Telex").tag(ViInputMethod.telex)
                            Text("Simple Telex").tag(ViInputMethod.simpleTelex)
                            Text("VNI").tag(ViInputMethod.vni)
                            Text("Tắt (English)").tag(ViInputMethod.off)
                        }
                        Toggle("Bíp khi đổi Việt / Anh từ menu", isOn: $model.beepOnModeSwitch)
                            .toggleStyle(.checkbox)
                        Text("Bảng mã: Unicode")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(10)
            }

            GroupBox {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Label("Mở lịch sử clipboard", systemImage: "doc.on.clipboard")
                            .font(.headline)
                        Text("Xem lại nội dung đã sao chép.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 5) {
                        HotkeyRecorder(keyCode: $model.overlayHotKeyCode,
                                       modifiers: $model.overlayHotKeyModifierMask)
                            .frame(width: 230, height: 32)
                            .help("Bấm để đổi phím tắt. Nhấn Esc để hủy.")
                        Text("Bấm vào phím tắt để thay đổi")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(10)
            }
        }
        .padding([.horizontal, .top], 20)
    }
}

// MARK: - Tab BỘ GÕ (checkbox list like OpenKey)

private struct SettingsEngineTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        ScrollView {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                GridRow {
                    Toggle("Đặt dấu òa, úy (thay vì oà, uý)", isOn: $model.useStatefulOrthography)
                        .toggleStyle(.checkbox)
                    Toggle("Kiểm tra chính tả", isOn: .constant(false))
                        .toggleStyle(.checkbox)
                        .disabled(true)
                        .foregroundColor(.secondary)
                }
                GridRow {
                    Toggle("Sửa lỗi gợi ý (trình duyệt, Excel,…)", isOn: $model.compatFix)
                        .toggleStyle(.checkbox)
                    Toggle("Tự khôi phục phím đã gõ sai", isOn: $model.repeatedRestore)
                        .toggleStyle(.checkbox)
                }
                GridRow {
                    Toggle("Viết hoa chữ cái đầu câu", isOn: $model.autoCapitalize)
                        .toggleStyle(.checkbox)
                    Toggle("Giữ w đầu từ làm phụ âm", isOn: $model.allowWAsConsonant)
                        .toggleStyle(.checkbox)
                }
                GridRow {
                    Toggle("Chuyển chế độ thông minh", isOn: .constant(false))
                        .toggleStyle(.checkbox)
                        .disabled(true)
                        .foregroundColor(.secondary)
                        .help("Đang phát triển: tự nhận biết từ tiếng Anh.")
                    Toggle("Tự ghi nhớ bảng mã theo ứng dụng", isOn: .constant(false))
                        .toggleStyle(.checkbox)
                        .disabled(true)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }
}

// MARK: - Tab ỨNG DỤNG (per-app overrides)

public struct AppOverrideRow: Identifiable, Equatable {
    public let id: String             // bundle id
    public let name: String
    public var methodRaw: Int?        // ViInputMethod? nil = global
    public var orthoRaw: Int?         // ViOrthography? nil = global

    public var methodName: String {
        guard let raw = methodRaw, let m = ViInputMethod(rawValue: raw) else { return "Theo mặc định" }
        switch m {
        case .off: return "Off (Anh)"
        case .telex: return "Telex"
        case .simpleTelex: return "Simple Telex"
        case .vni: return "VNI"
        }
    }

    public init(id: String, name: String, methodRaw: Int?, orthoRaw: Int?) {
        self.id = id
        self.name = name
        self.methodRaw = methodRaw
        self.orthoRaw = orthoRaw
    }
}

public struct SettingsAppsTab: View {
    @ObservedObject var model: SettingsModel

    public init(model: SettingsModel) {
        _model = ObservedObject(wrappedValue: model)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Cài đặt riêng theo ứng dụng")
                    .font(.headline)
                Spacer()
                Button("Thêm app…") { model.addAppFromPanel() }
                Button("Xóa", role: .destructive) {
                    if model.selectedRowID != nil { model.removeSelected() }
                }
            }

            Table(model.rows, selection: $model.selectedRowID) {
                TableColumn("App") { row in
                    HStack {
                        Text(row.name).lineLimit(1)
                        Spacer()
                        Text(row.id).font(.caption).foregroundColor(.secondary)
                    }
                }
                TableColumn("Cách gõ") { row in
                    Picker("", selection: bindingForMethod(row)) {
                        Text("Theo mặc định").tag(Optional<Int>.none)
                        Text("Off (Anh)").tag(Optional<Int>.some(0))
                        Text("Telex").tag(Optional<Int>.some(1))
                        Text("Simple Telex").tag(Optional<Int>.some(2))
                        Text("VNI").tag(Optional<Int>.some(3))
                    }
                    .labelsHidden()
                }
                .width(140)
                TableColumn("Kiểu dấu") { row in
                    Picker("", selection: bindingForOrtho(row)) {
                        Text("—").tag(Optional<Int>.none)
                        Text("Cũ").tag(Optional<Int>.some(0))
                        Text("Mới").tag(Optional<Int>.some(1))
                    }
                    .labelsHidden()
                }
                .width(90)
            }

            Text("Apps bạn gõ sau khi bật KeyV sẽ tự xuất hiện ở đây (auto-tracking), hoặc bấm 'Thêm app…' để chọn.\nThay đổi có hiệu lực ngay khi app đó nhận focus.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .padding()
    }

    private func bindingForMethod(_ row: AppOverrideRow) -> Binding<Int?> {
        Binding(
            get: { model.rows.first { $0.id == row.id }?.methodRaw },
            set: { model.updateRow(id: row.id, methodRaw: $0, orthoRaw: row.orthoRaw) })
    }

    private func bindingForOrtho(_ row: AppOverrideRow) -> Binding<Int?> {
        Binding(
            get: { model.rows.first { $0.id == row.id }?.orthoRaw },
            set: { model.updateRow(id: row.id, methodRaw: row.methodRaw, orthoRaw: $0) })
    }
}

// MARK: - Tab GÕ TẮT (macro editor)

private struct SettingsMacroTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Bật gõ tắt (macro)", isOn: $model.macroEnabled)
                .toggleStyle(.checkbox)

            Text("Định dạng: \"phím\\tthay thế\", mỗi dòng một luật. Được nạp ngay khi lưu:")
                .font(.footnote)
                .foregroundColor(.secondary)

            HStack(alignment: .top, spacing: 8) {
                TextEditor(text: $model.macroText)
                    .font(.system(.body, design: .monospaced))
                    .border(Color.secondary.opacity(0.4))
                    .frame(maxHeight: 180)

                VStack(spacing: 8) {
                    Button("Lưu") { model.saveMacroFile() }
                    Button("Nạp lại") {
                        model.loadMacroFile()
                    }
                    Text("Ví dụ:\nhvbt\tNhé bạn")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Text(model.macroStatus ?? "Mỗi quy tắc gồm phím tắt, một ký tự Tab và nội dung thay thế.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .padding()
        .onAppear { model.loadMacroFile() }
    }
}

// MARK: - Tab HỆ THỐNG

private struct SettingsSystemTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Toggle("Khởi động cùng hệ thống", isOn: $model.launchAtStartup)
                        .toggleStyle(.checkbox)
                    Spacer()
                }

                Divider()

                Stepper(value: $model.retentionLimit, in: 50...1000, step: 50) {
                    Text("Giữ tối đa \(model.retentionLimit) mục clipboard")
                }

                Button("Xóa toàn bộ clipboard vault", role: .destructive) {
                    ClipboardStore.shared.wipe()
                }
            }
            .padding()
        }
    }
}

// MARK: - Tab THÔNG TIN

private struct SettingsAboutTab: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                KeyVIcon.swiftImage(size: 48)?
                    .resizable().frame(width: 48, height: 48)
                ?? Image(systemName: "keyboard").resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading) {
                    Text("KeyV 0.3").font(.title3).bold()
                    Text("Bộ gõ tiếng Việt + Lịch sử clipboard cho macOS")
                        .foregroundColor(.secondary)
                }
            }

            Text("Engine clean-room Rust qua FFI nhúng, độ trễ gõ \u{2264}1 ms — MIT OR Apache-2.0")
                .foregroundColor(.secondary)
            Text("Không dùng mã từ OpenKey / Unikey / EVKey")
                .font(.footnote)
                .foregroundColor(.secondary)

            Spacer()
        }
        .padding()
    }
}

// MARK: - SettingsModel (one source of truth for the panel)

@MainActor
public final class SettingsModel: NSObject, ObservableObject {
    public static let shared = SettingsModel()

    @Published public var method: ViInputMethod { didSet { guard !syncing else { return }; AppSettings.shared.method = method } }
    @Published public var orthography: ViOrthography { didSet { guard !syncing else { return }; AppSettings.shared.orthography = orthography } }
    @Published public var allowWAsConsonant: Bool { didSet { guard !syncing else { return }; AppSettings.shared.allowWAsConsonant = allowWAsConsonant } }
    @Published public var macroEnabled: Bool { didSet { guard !syncing else { return }; AppSettings.shared.macroEnabled = macroEnabled } }
    @Published public var retentionLimit: Int { didSet { guard !syncing else { return }; AppSettings.shared.clipboardRetentionLimit = retentionLimit } }

    @Published public var overlayHotKeyCode: Int { didSet { guard !syncing else { return }; AppSettings.shared.overlayHotKeyCode = overlayHotKeyCode } }
    @Published public var overlayHotKeyModifierMask: UInt { didSet { guard !syncing else { return }; AppSettings.shared.overlayHotKeyModifiers = overlayHotKeyModifierMask } }

    @Published public var repeatedRestore: Bool { didSet { guard !syncing else { return }; AppSettings.shared.repeatedRestore = repeatedRestore } }
    @Published public var autoCapitalize: Bool { didSet { guard !syncing else { return }; AppSettings.shared.autoCapitalize = autoCapitalize } }
    @Published public var beepOnModeSwitch: Bool { didSet { guard !syncing else { return }; AppSettings.shared.beepOnModeSwitch = beepOnModeSwitch } }
    @Published public var compatFix: Bool { didSet { guard !syncing else { return }; AppSettings.shared.compatFix = compatFix } }

    /// "Đặt dấu òa, úy (thay vì oà, uý)" — Traditional khi bật, Modern khi tắt.
    @Published public var useStatefulOrthography: Bool {
        didSet { guard !syncing else { return }; AppSettings.shared.orthography = useStatefulOrthography ? .traditional : .modern }
    }

    /// Chế độ radio Tiếng Việt / English.
    @Published public var isEnglishMode: Bool {
        didSet {
            guard !syncing else { return }
            let settings = AppSettings.shared
            if isEnglishMode {
                if settings.method != .off {
                    settings.lastVietnameseMethod = settings.method
                    settings.method = .off
                }
            } else if settings.method == .off {
                settings.method = settings.lastVietnameseMethod
            }
        }
    }

    @Published public var rows: [AppOverrideRow] = []
    @Published public var selectedRowID: String?
    @Published public var macroText: String = ""
    @Published public var macroStatus: String?

    public var launchAtStartup: Bool {
        get { SMAppServiceHelper.isEnabled() }
        set { SMAppServiceHelper.setEnabled(newValue) }
    }

    private var syncing = false
    private var seenAppsObserver: NSObjectProtocol?

    public override init() {
        let s = AppSettings.shared
        method = s.method
        orthography = s.orthography
        allowWAsConsonant = s.allowWAsConsonant
        macroEnabled = s.macroEnabled
        retentionLimit = s.clipboardRetentionLimit
        overlayHotKeyCode = s.overlayHotKeyCode
        overlayHotKeyModifierMask = s.overlayHotKeyModifiers
        repeatedRestore = s.repeatedRestore
        autoCapitalize = s.autoCapitalize
        beepOnModeSwitch = s.beepOnModeSwitch
        compatFix = s.compatFix
        useStatefulOrthography = (s.orthography == .traditional)
        isEnglishMode = (s.method == .off)
        super.init()
        rebuildRows()
        s.onChange(target: self, selector: #selector(syncSettings))
        seenAppsObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("KeyVSeenAppsChanged"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rebuildRows()
            }
        }
        loadMacroFile()
    }

    @objc private func syncSettings() {
        syncing = true
        defer { syncing = false }
        let s = AppSettings.shared
        method = s.method
        orthography = s.orthography
        isEnglishMode = s.isEnglishMode
        useStatefulOrthography = s.orthography == .traditional
        rebuildRows()
    }

    func reloadMacros() {
        // Delegate app pings us; the engine macro table rebuilds here.
        let settings = AppSettings.shared
        if settings.macroEnabled {
            NotificationCenter.default.post(name: Notification.Name("KeyVSavedMacroFile"), object: nil)
        }
    }

    // MARK: Per-app rows

    public func rebuildRows() {
        let overrides = AppSettings.shared.appOverridesJSON
        let seen = AppSettings.shared.seenAppsJSON
        var ids = Array(overrides.keys)
        for id in seen.keys where !ids.contains(id) { ids.append(id) }
        ids.sort { displayName(for: $0, seen: seen) < displayName(for: $1, seen: seen) }
        rows = ids.map { id in
            let o = overrides[id]
            return AppOverrideRow(id: id,
                                  name: displayName(for: id, seen: seen),
                                  methodRaw: o?.useModeRaw,
                                  orthoRaw: o?.orthographyRaw)
        }
    }

    private func displayName(for bundleID: String, seen: [String: String]) -> String {
        seen[bundleID]
            ?? (NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.deletingPathExtension().lastPathComponent)
            ?? bundleID
    }

    public func updateRow(id: String, methodRaw: Int?, orthoRaw: Int?) {
        var overrides = AppSettings.shared.appOverridesJSON
        let finalMethod = methodRaw
        let finalOrtho = orthoRaw
        if finalMethod == nil && finalOrtho == nil {
            overrides[id] = nil
        } else {
            overrides[id] = .init(
                useMode: finalMethod.flatMap(ViInputMethod.init(rawValue:)),
                orthography: finalOrtho.flatMap(ViOrthography.init(rawValue:)))
        }
        AppSettings.shared.appOverridesJSON = overrides
        rebuildRows()
    }

    public func removeSelected() {
        guard let id = selectedRowID else { return }
        var overrides = AppSettings.shared.appOverridesJSON
        overrides[id] = nil
        AppSettings.shared.appOverridesJSON = overrides
        var seen = AppSettings.shared.seenAppsJSON
        seen[id] = nil
        AppSettings.shared.seenAppsJSON = seen
        selectedRowID = nil
        rebuildRows()
    }

    public func addAppFromPanel() {
        let panel = NSOpenPanel()
        panel.message = "Chọn app muốn đặt kiểu gõ riêng"
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
        let name = url.deletingPathExtension().lastPathComponent
        AppSettings.shared.noteSeenApp(bundleID: id, name: name)
        selectedRowID = id
        rebuildRows()
    }

    // MARK: macro file

    func loadMacroFile() {
        macroText = LookupMacroURL().flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "hvbt\tNhé bạn\n"
        macroStatus = nil
    }

    func saveMacroFile() {
        guard let url = LookupMacroURL() else { return }
        do {
            try macroText.write(to: url, atomically: true, encoding: .utf8)
            reloadMacros()
            macroStatus = "Đã lưu bảng gõ tắt."
        } catch {
            macroStatus = "Không lưu được: \(error.localizedDescription)"
        }
    }

    private func LookupMacroURL() -> URL? {
        let dir = ClipboardStore.dataDir()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("macros.tsv")
    }

    private func updateLaunchAtStartup(_ on: Bool) {
        SMAppServiceHelper.setEnabled(on)
    }
}

/// Launch-at-login helper (SMAppService, macOS 13+).
enum SMAppServiceHelper {
    static func isEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("[KeyV] SMAppService error: \(error)")
        }
    }
}
