import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import Carbon.HIToolbox
import KeyVCore

public enum SettingsTab: Int, Hashable {
    case engine = 0
    case apps = 1
    case macros = 2
    case system = 3
    case about = 4
}

/// Settings window: OpenKey-style control panel.
/// Top = live controls (Điều khiển); below = tabs (Bộ gõ / Ứng dụng / Gõ tắt /
/// Hệ thống / Thông tin).
public struct SettingsRootView: View {
    @ObservedObject private var model = SettingsModel.shared
    @ObservedObject private var permission = PermissionModel.shared

    public init(initialTab: SettingsTab? = nil) {
        if let initialTab {
            SettingsModel.shared.selectedTab = initialTab
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 10)

            ControlPanelSection(model: model)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

            TabView(selection: $model.selectedTab) {
                SettingsEngineTab(model: model)
                    .tabItem { Label("Bộ gõ", systemImage: "character.cursor.ibeam") }
                    .tag(SettingsTab.engine)

                SettingsAppsTab(model: model)
                    .tabItem { Label("Ứng dụng", systemImage: "square.grid.2x2") }
                    .tag(SettingsTab.apps)

                SettingsMacroTab(model: model)
                    .tabItem { Label("Gõ tắt", systemImage: "text.badge.plus") }
                    .tag(SettingsTab.macros)

                SettingsSystemTab(model: model)
                    .tabItem { Label("Hệ thống", systemImage: "gearshape.2") }
                    .tag(SettingsTab.system)

                SettingsAboutTab()
                    .tabItem { Label("Thông tin", systemImage: "info.circle") }
                    .tag(SettingsTab.about)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .frame(minWidth: 700, idealWidth: 720, maxWidth: .infinity, minHeight: 620, idealHeight: 650, maxHeight: .infinity)
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            if let icon = KeyVIcon.swiftImage(size: 40) {
                icon
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 40, height: 40)
            } else {
                Image(systemName: "keyboard.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 40, height: 40)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("KeyV")
                    .font(.system(size: 20, weight: .bold))
                Text("Bộ gõ tiếng Việt & Lịch sử Clipboard bảo mật")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                accessibilityStatusPill
                inputModeStatusPill
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    @ViewBuilder
    private var accessibilityStatusPill: some View {
        if permission.status == .ready {
            Label("Đã cấp quyền Trợ năng", systemImage: "checkmark.shield.fill")
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(.green)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.green.opacity(0.13), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.green.opacity(0.32), lineWidth: 1))
                .fixedSize(horizontal: true, vertical: false)
        } else {
            Button {
                AccessibilityGate.openSettingsPane()
            } label: {
                Label("Cần quyền Trợ năng", systemImage: "exclamationmark.shield.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.orange.opacity(0.14), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.orange.opacity(0.4), lineWidth: 1))
                    .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(.plain)
            .help("Nhấn để mở Cài đặt Hệ thống → Quyền riêng tư & Bảo mật → Trợ năng")
        }
    }

    private var inputModeStatusPill: some View {
        let isEnglish = model.isEnglishMode
        let labelText = isEnglish
            ? "English"
            : "Tiếng Việt · \(Self.methodTitle(model.method))"
        let symbol = isEnglish ? "globe" : "character.cursor.ibeam"
        let tint: Color = isEnglish ? .secondary : .accentColor

        return Button {
            model.isEnglishMode.toggle()
        } label: {
            Label(labelText, systemImage: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(tint.opacity(0.14), in: Capsule())
                .overlay(Capsule().strokeBorder(tint.opacity(0.32), lineWidth: 1))
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
        .help("Nhấn để chuyển nhanh chế độ gõ Tiếng Việt / English")
    }

    fileprivate static func methodTitle(_ method: ViInputMethod) -> String {
        switch method {
        case .telex: return "Telex"
        case .simpleTelex: return "Simple Telex"
        case .vni: return "VNI"
        case .off: return "English"
        }
    }
}

// MARK: - ĐIỀU KHIỂN (top section, always visible)

private struct ControlPanelSection: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Ngôn ngữ & Phím chuyển", systemImage: "keyboard")
                        .font(.headline)

                    Picker("Ngôn ngữ", selection: $model.isEnglishMode) {
                        Text("Tiếng Việt").tag(false)
                        Text("English").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    HStack(spacing: 10) {
                        Text("Kiểu gõ")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(width: 78, alignment: .leading)
                        Picker("Kiểu gõ", selection: $model.method) {
                            Text("Telex").tag(ViInputMethod.telex)
                            Text("Simple Telex").tag(ViInputMethod.simpleTelex)
                            Text("VNI").tag(ViInputMethod.vni)
                            Text("Tắt (English)").tag(ViInputMethod.off)
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                    }

                    HStack(spacing: 10) {
                        Text("Phím chuyển")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(width: 78, alignment: .leading)
                        HotkeyRecorder(
                            keyCode: $model.toggleHotKeyCode,
                            modifiers: $model.toggleHotKeyModifierMask,
                            label: "Phím tắt chuyển ngôn ngữ"
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .help("Nhấp để đặt tổ hợp phím chuyển Tiếng Việt / English. Nhấn Esc để hủy.")
                    }

                    HStack(spacing: 16) {
                        Toggle("Ctrl + Shift đổi nhanh", isOn: $model.ctrlShiftSwitch)
                            .toggleStyle(.checkbox)
                            .font(.callout)
                        Toggle("Âm báo khi chuyển", isOn: $model.beepOnModeSwitch)
                            .toggleStyle(.checkbox)
                            .font(.callout)
                    }

                    Spacer(minLength: 0)
                }
                .padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Lịch sử Clipboard", systemImage: "doc.on.clipboard")
                        .font(.headline)

                    Text("Tra cứu và dán nhanh văn bản, hình ảnh, tệp đã sao chép từ cửa sổ nổi.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Phím tắt mở nhanh")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        HotkeyRecorder(
                            keyCode: $model.overlayHotKeyCode,
                            modifiers: $model.overlayHotKeyModifierMask,
                            label: "Phím mở lịch sử clipboard"
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .help("Nhấp để đổi tổ hợp phím mở Lịch sử Clipboard. Nhấn Esc để hủy.")
                    }

                    Spacer(minLength: 0)

                    HStack(spacing: 8) {
                        Label("Tối đa \(model.retentionLimit) mục", systemImage: "internaldrive")
                        Text("·")
                        Label("Unicode NFC", systemImage: "checkmark.circle")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Tab BỘ GÕ

private struct SettingsEngineTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 9) {
                        Label("Quy tắc bỏ dấu & Chính tả", systemImage: "textformat.abc")
                            .font(.headline)

                        Divider()

                        settingToggleRow(
                            title: "Đặt dấu kiểu truyền thống (òa, oẻ, úy)",
                            subtitle: "Bật để đặt dấu theo chuẩn cũ (òa, úy); tắt để đặt dấu theo kiểu mới (oà, uý).",
                            isOn: $model.useStatefulOrthography
                        )

                        settingToggleRow(
                            title: "Kiểm tra chính tả tiếng Việt",
                            subtitle: "Nhận diện cấu trúc âm tiết hợp lệ để không bỏ dấu nhầm khi gõ xen kẽ tiếng Anh.",
                            isOn: $model.spellCheck
                        )

                        settingToggleRow(
                            title: "Giữ phím W đầu từ làm phụ âm",
                            subtitle: "Cho phép gõ tự nhiên các từ bắt đầu bằng W (như Web, Windows, Swift) mà không đổi thành ư.",
                            isOn: $model.allowWAsConsonant
                        )
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 9) {
                        Label("Tiện ích gõ & Tương thích ứng dụng", systemImage: "wand.and.stars")
                            .font(.headline)

                        Divider()

                        settingToggleRow(
                            title: "Tự khôi phục phím khi gõ lặp",
                            subtitle: "Nhấn lặp lại phím dấu (s, f, r, x, j, w, d…) để hoàn tác dấu và trả về ký tự gốc kiểu UniKey.",
                            isOn: $model.repeatedRestore
                        )

                        settingToggleRow(
                            title: "Tự động viết hoa chữ cái đầu câu",
                            subtitle: "Tự viết hoa chữ cái đầu tiên sau dấu kết thúc câu (. ! ?) và khoảng trắng.",
                            isOn: $model.autoCapitalize
                        )

                        settingToggleRow(
                            title: "Tương thích gợi ý tự động (Trình duyệt, Excel, IDE…)",
                            subtitle: "Khắc phục hiện tượng nuốt chữ hoặc lặp ký tự trên thanh địa chỉ trình duyệt và ô nhập có autocomplete.",
                            isOn: $model.compatFix
                        )
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(10)
        }
    }

    private func settingToggleRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox)
    }
}

// MARK: - Tab ỨNG DỤNG (per-app overrides)

public struct AppOverrideRow: Identifiable, Equatable {
    public let id: String
    public let name: String
    public var methodRaw: Int?
    public var orthoRaw: Int?

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
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cấu hình riêng theo từng ứng dụng")
                        .font(.headline)
                    Text("Tự động chuyển kiểu gõ hoặc tắt tiếng Việt khi chuyển sang ứng dụng được chọn.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.addAppFromPanel()
                } label: {
                    Label("Thêm ứng dụng…", systemImage: "plus")
                }

                Button(role: .destructive) {
                    model.removeSelected()
                } label: {
                    Label("Xóa", systemImage: "trash")
                }
                .disabled(model.selectedRowID == nil)
            }

            if model.rows.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "macwindow.badge.plus")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("Chưa có ứng dụng nào trong danh sách")
                        .font(.headline)
                    Text("Các ứng dụng bạn sử dụng khi bật KeyV sẽ tự động xuất hiện tại đây, hoặc nhấn \"Thêm ứng dụng…\" để chọn trước từ thư mục Applications.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                    Button("Thêm ứng dụng…") {
                        model.addAppFromPanel()
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                )
            } else {
                Table(model.rows, selection: $model.selectedRowID) {
                    TableColumn("Ứng dụng") { row in
                        HStack(spacing: 9) {
                            appIconView(for: row.id)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.name)
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(1)
                                Text(row.id)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    TableColumn("Kiểu gõ") { row in
                        Picker("", selection: bindingForMethod(row)) {
                            Text("Theo mặc định").tag(Optional<Int>.none)
                            Text("English (Tắt)").tag(Optional<Int>.some(0))
                            Text("Telex").tag(Optional<Int>.some(1))
                            Text("Simple Telex").tag(Optional<Int>.some(2))
                            Text("VNI").tag(Optional<Int>.some(3))
                        }
                        .labelsHidden()
                    }
                    .width(155)
                    TableColumn("Kiểu dấu") { row in
                        Picker("", selection: bindingForOrtho(row)) {
                            Text("Mặc định").tag(Optional<Int>.none)
                            Text("Kiểu cũ (òa)").tag(Optional<Int>.some(0))
                            Text("Kiểu mới (oà)").tag(Optional<Int>.some(1))
                        }
                        .labelsHidden()
                    }
                    .width(120)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                )
            }

            Label("Thay đổi có hiệu lực tức thì ngay khi ứng dụng đó được đưa lên phía trước.", systemImage: "bolt.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    @ViewBuilder
    private func appIconView(for bundleID: String) -> some View {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 20, height: 20)
        } else {
            Image(nsImage: NSWorkspace.shared.icon(for: .applicationBundle))
                .resizable()
                .interpolation(.high)
                .frame(width: 20, height: 20)
        }
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

    private var canAddQuickRule: Bool {
        let key = model.quickMacroShortcut.trimmingCharacters(in: .whitespacesAndNewlines)
        let val = model.quickMacroExpansion.trimmingCharacters(in: .whitespacesAndNewlines)
        return !key.isEmpty && !val.isEmpty && !key.contains("\t") && !key.contains(" ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Toggle("Bật bảng gõ tắt (Macro)", isOn: $model.macroEnabled)
                    .toggleStyle(.checkbox)
                    .font(.headline)

                Text("\(model.macroRuleCount) quy tắc")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.13), in: Capsule())

                Spacer()

                if let status = model.macroStatus {
                    Label(
                        status,
                        systemImage: model.macroSaveSucceeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(model.macroSaveSucceeded ? .green : .orange)
                }
            }

            GroupBox {
                HStack(spacing: 8) {
                    TextField("Từ viết tắt (vd: kvn)", text: $model.quickMacroShortcut)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12.5, design: .monospaced))
                        .frame(width: 205)
                        .onSubmit(submitQuickRule)

                    Image(systemName: "arrow.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)

                    TextField("Nội dung mở rộng (vd: KeyV cho macOS)", text: $model.quickMacroExpansion)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)
                        .onSubmit(submitQuickRule)

                    Button {
                        submitQuickRule()
                    } label: {
                        Label("Thêm", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAddQuickRule)
                }
                .padding(4)
            }

            TextEditor(text: $model.macroText)
                .font(.system(size: 13, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                )

            HStack(spacing: 10) {
                Text("Định dạng TSV: mỗi dòng gồm <từ_viết_tắt>[Phím Tab]<nội_dung_mở_rộng>.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Nạp lại") {
                    model.loadMacroFile()
                }
                Button("Lưu bảng gõ tắt") {
                    model.saveMacroFile()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .onAppear { model.loadMacroFile() }
    }

    private func submitQuickRule() {
        guard canAddQuickRule else { return }
        model.appendMacroRule(shortcut: model.quickMacroShortcut, expansion: model.quickMacroExpansion)
        model.quickMacroShortcut = ""
        model.quickMacroExpansion = ""
    }
}

// MARK: - Tab HỆ THỐNG

private struct SettingsSystemTab: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var updater = UpdateService.shared
    @ObservedObject private var permission = PermissionModel.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("Cập nhật tự động", systemImage: "arrow.triangle.2.circlepath.circle")
                                .font(.headline)
                            Spacer()
                            Text("Phiên bản v\(updater.currentVersionString)")
                                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color(nsColor: .quaternaryLabelColor).opacity(0.35), in: Capsule())
                        }

                        Divider()

                        Toggle("Tự động kiểm tra bản cập nhật mới từ GitHub Releases", isOn: $model.autoCheckUpdates)
                            .toggleStyle(.checkbox)

                        HStack(spacing: 10) {
                            Button("Kiểm tra cập nhật…") {
                                updater.showUpdateWindowAndCheck()
                            }

                            if let avail = updater.availableUpdate {
                                Button("Cài đặt ngay v\(avail.version.description)") {
                                    updater.presentUpdateWindow()
                                    Task { await updater.downloadAndInstall(avail) }
                                }
                                .buttonStyle(.borderedProminent)
                            }

                            Spacer()

                            updateStatusLabel
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Hệ thống & Quyền Trợ năng", systemImage: "hand.raised.shield")
                            .font(.headline)

                        Divider()

                        Toggle("Khởi động KeyV cùng macOS khi đăng nhập", isOn: $model.launchAtStartup)
                            .toggleStyle(.checkbox)

                        HStack(spacing: 10) {
                            Image(systemName: permission.status == .ready ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                                .foregroundStyle(permission.status == .ready ? .green : .orange)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(permission.status == .ready
                                     ? "Quyền Trợ năng đã được cấp và đang hoạt động"
                                     : "KeyV chưa có quyền Trợ năng để lắng nghe bàn phím")
                                    .font(.callout.weight(.medium))
                                Text("Quản lý trong Cài đặt Hệ thống → Quyền riêng tư & Bảo mật → Trợ năng.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Mở Cài đặt Trợ năng…") {
                                AccessibilityGate.openSettingsPane()
                            }
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Lưu trữ Clipboard mã hóa", systemImage: "lock.doc")
                            .font(.headline)

                        Divider()

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Giới hạn lưu trữ: tối đa \(model.retentionLimit) mục gần nhất")
                                    .font(.callout.weight(.medium))
                                Text("Dữ liệu được mã hóa AES-256-GCM với khóa bảo vệ trong macOS Keychain.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Stepper("", value: $model.retentionLimit, in: 50...1000, step: 50)
                                .labelsHidden()
                        }

                        HStack(spacing: 12) {
                            Button("Xóa toàn bộ lịch sử clipboard…", role: .destructive) {
                                model.showWipeConfirmation = true
                            }

                            if model.didWipeClipboardBanner {
                                Label("Đã xóa toàn bộ lịch sử clipboard.", systemImage: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }
                            Spacer()
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(10)
        }
        .alert("Xóa toàn bộ lịch sử clipboard?", isPresented: $model.showWipeConfirmation) {
            Button("Hủy", role: .cancel) {}
            Button("Xóa vĩnh viễn", role: .destructive) {
                ClipboardStore.shared.wipe()
                model.didWipeClipboardBanner = true
            }
        } message: {
            Text("Tất cả văn bản, hình ảnh và đường dẫn tệp đã lưu trong cơ sở dữ liệu clipboard của KeyV sẽ bị xóa vĩnh viễn và không thể khôi phục.")
        }
    }

    @ViewBuilder
    private var updateStatusLabel: some View {
        switch updater.state {
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Đang kiểm tra…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .upToDate(let ver):
            Label("Đang dùng bản mới nhất (v\(ver))", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .updateAvailable(let avail):
            Label("Có bản mới v\(avail.version.description)", systemImage: "sparkles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
        case .downloading(_, let pct):
            Text("Đang tải \(Int(pct * 100))%…")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color.accentColor)
        case .installing(let avail):
            Text("Đang cài đặt v\(avail.version.description)…")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
        case .failed:
            Label("Kiểm tra thất bại", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        case .idle:
            Text("Sẵn sàng kiểm tra")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Tab THÔNG TIN

private struct SettingsAboutTab: View {
    @ObservedObject private var updater = UpdateService.shared
    private let signing = SigningStatusInfo.inspectCurrentBundle()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    if let icon = KeyVIcon.swiftImage(size: 56) {
                        icon
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 56, height: 56)
                    } else {
                        Image(systemName: "keyboard.fill")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 56, height: 56)
                            .foregroundStyle(Color.accentColor)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("KeyV v\(updater.currentVersionString)")
                            .font(.system(size: 20, weight: .bold))
                        Text("Bộ gõ tiếng Việt hiện đại & Lịch sử Clipboard bảo mật cho macOS")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            archBadge("Rust Core + SwiftUI", symbol: "cpu")
                            archBadge("AES-256-GCM Vault", symbol: "lock.shield")
                            archBadge("MIT / Apache-2.0", symbol: "checkmark.seal")
                        }
                        .padding(.top, 2)
                    }
                    Spacer()
                }
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                )

                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(
                            "Chữ ký số & Duy trì quyền Trợ năng (TCC)",
                            systemImage: signing.preservesTCC ? "checkmark.seal.fill" : "signature"
                        )
                        .font(.headline)
                        .foregroundStyle(signing.preservesTCC ? .green : .primary)

                        Divider()

                        HStack {
                            Text("Trạng thái chữ ký:")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Text(signing.summary)
                                .font(.callout.weight(.semibold))
                        }

                        Text(
                            signing.preservesTCC
                                ? "Gói ứng dụng được ký bằng chứng chỉ định danh ổn định — macOS giữ nguyên quyền Trợ năng qua các lần cập nhật tự động."
                                : "Gói ứng dụng đang dùng chữ ký cục bộ (ad-hoc). Chạy scripts/setup_signing_cert.sh trước khi đóng gói để giữ nguyên quyền Trợ năng khi cập nhật."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 5) {
                        Label("Kiến trúc nguồn mở sạch (Clean-Room)", systemImage: "sparkles.rectangle.stack")
                            .font(.headline)
                        Text("Nhân xử lý tiếng Việt viết mới hoàn toàn bằng Rust nhúng qua C ABI, tự động lược bỏ dữ liệu nhạy cảm khỏi clipboard (1Password / Keychain) và không sử dụng bất kỳ mã nguồn GPL bên thứ ba nào.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 10) {
                    Button {
                        updater.showUpdateWindowAndCheck()
                    } label: {
                        Label("Kiểm tra cập nhật…", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        NSWorkspace.shared.open(URL(string: "https://github.com/nhuuduc/keyv")!)
                    } label: {
                        Label("Mở trang GitHub", systemImage: "arrow.up.right.square")
                    }

                    Spacer()
                }
            }
            .padding(10)
        }
    }

    private func archBadge(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color(nsColor: .quaternaryLabelColor).opacity(0.35), in: Capsule())
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

    @Published public var toggleHotKeyCode: Int { didSet { guard !syncing else { return }; AppSettings.shared.toggleHotKeyCode = toggleHotKeyCode } }
    @Published public var toggleHotKeyModifierMask: UInt { didSet { guard !syncing else { return }; AppSettings.shared.toggleHotKeyModifiers = toggleHotKeyModifierMask } }
    @Published public var ctrlShiftSwitch: Bool { didSet { guard !syncing else { return }; AppSettings.shared.ctrlShiftSwitch = ctrlShiftSwitch } }
    @Published public var autoCheckUpdates: Bool { didSet { guard !syncing else { return }; AppSettings.shared.autoCheckUpdates = autoCheckUpdates } }

    @Published public var repeatedRestore: Bool { didSet { guard !syncing else { return }; AppSettings.shared.repeatedRestore = repeatedRestore } }
    @Published public var spellCheck: Bool { didSet { guard !syncing else { return }; AppSettings.shared.spellCheck = spellCheck } }
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

    @Published public var selectedTab: SettingsTab = .engine
    @Published public var rows: [AppOverrideRow] = []
    @Published public var selectedRowID: String?
    @Published public var macroText: String = ""
    @Published public var macroStatus: String?
    @Published public var macroSaveSucceeded: Bool = true
    @Published public var quickMacroShortcut: String = ""
    @Published public var quickMacroExpansion: String = ""
    @Published public var showWipeConfirmation: Bool = false
    @Published public var didWipeClipboardBanner: Bool = false
    @Published public var launchAtStartup: Bool {
        didSet {
            guard !syncing else { return }
            SMAppServiceHelper.setEnabled(launchAtStartup)
        }
    }

    public var macroRuleCount: Int {
        macroText
            .split(whereSeparator: \.isNewline)
            .filter { line in
                let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                return parts.count == 2 && !parts[0].trimmingCharacters(in: .whitespaces).isEmpty
            }
            .count
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
        toggleHotKeyCode = s.toggleHotKeyCode
        toggleHotKeyModifierMask = s.toggleHotKeyModifiers
        ctrlShiftSwitch = s.ctrlShiftSwitch
        autoCheckUpdates = s.autoCheckUpdates
        repeatedRestore = s.repeatedRestore
        spellCheck = s.spellCheck
        autoCapitalize = s.autoCapitalize
        beepOnModeSwitch = s.beepOnModeSwitch
        compatFix = s.compatFix
        useStatefulOrthography = (s.orthography == .traditional)
        isEnglishMode = (s.method == .off)
        launchAtStartup = SMAppServiceHelper.isEnabled()
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
        allowWAsConsonant = s.allowWAsConsonant
        macroEnabled = s.macroEnabled
        retentionLimit = s.clipboardRetentionLimit
        repeatedRestore = s.repeatedRestore
        spellCheck = s.spellCheck
        autoCapitalize = s.autoCapitalize
        beepOnModeSwitch = s.beepOnModeSwitch
        compatFix = s.compatFix
        ctrlShiftSwitch = s.ctrlShiftSwitch
        autoCheckUpdates = s.autoCheckUpdates
        toggleHotKeyCode = s.toggleHotKeyCode
        toggleHotKeyModifierMask = s.toggleHotKeyModifiers
        overlayHotKeyCode = s.overlayHotKeyCode
        overlayHotKeyModifierMask = s.overlayHotKeyModifiers
        rebuildRows()
    }

    func reloadMacros() {
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
        panel.message = "Chọn ứng dụng muốn đặt kiểu gõ riêng"
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

    public func loadMacroFile() {
        macroText = LookupMacroURL().flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "hvbt\tNhé bạn\n"
        macroStatus = nil
        macroSaveSucceeded = true
    }

    public func saveMacroFile() {
        guard let url = LookupMacroURL() else { return }
        do {
            try macroText.write(to: url, atomically: true, encoding: .utf8)
            reloadMacros()
            macroSaveSucceeded = true
            macroStatus = "Đã lưu (\(macroRuleCount) quy tắc)."
        } catch {
            macroSaveSucceeded = false
            macroStatus = "Không lưu được: \(error.localizedDescription)"
        }
    }

    public func appendMacroRule(shortcut rawKey: String, expansion rawValue: String) {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !value.isEmpty else { return }

        var existingLines = macroText
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        var replaced = false
        for idx in existingLines.indices {
            let parts = existingLines[idx].split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 && String(parts[0]).trimmingCharacters(in: .whitespaces) == key {
                existingLines[idx] = "\(key)\t\(value)"
                replaced = true
                break
            }
        }
        if !replaced {
            existingLines.append("\(key)\t\(value)")
        }
        macroText = existingLines.joined(separator: "\n") + "\n"
        saveMacroFile()
        if macroSaveSucceeded {
            macroStatus = replaced ? "Đã cập nhật \"\(key)\"." : "Đã thêm \"\(key)\"."
        }
    }

    private func LookupMacroURL() -> URL? {
        let dir = ClipboardStore.dataDir()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("macros.tsv")
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
