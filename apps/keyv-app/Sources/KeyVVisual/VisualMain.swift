import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Carbon.HIToolbox
import KeyVCore
import KeyVHostKit

// Visual harness: renders the real SwiftUI views to PNG for eyeballing.
// Run manually only; not part of the shipped app.

@MainActor
private func renderPNG<V: View>(_ view: V, size: NSSize, name: String, dark: Bool = false) {
    print("render \(name)", terminator: "\n"); fflush(stdout)
    let appearanceName: NSAppearance.Name = dark ? .darkAqua : .aqua
    let appearance = NSAppearance(named: appearanceName)
    NSApp.appearance = appearance
    let colorScheme: ColorScheme = dark ? .dark : .light
    let hosted = view.environment(\.colorScheme, colorScheme)

    let hosting = NSHostingView(rootView: hosted)
    hosting.frame = NSRect(origin: .zero, size: size)
    hosting.appearance = appearance

    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    window.appearance = appearance
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    hosting.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.06))
    hosting.layoutSubtreeIfNeeded()

    guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
        print("bitmap rep nil for \(name)", terminator: "\n"); fflush(stdout)
        return
    }
    if let appearance {
        appearance.performAsCurrentDrawingAppearance {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
        }
    } else {
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
    }

    guard let png = rep.representation(using: .png, properties: [:]) else {
        print("png nil for \(name)", terminator: "\n"); fflush(stdout)
        return
    }
    do {
        try png.write(to: URL(fileURLWithPath: name))
        print("wrote \(name)", terminator: "\n"); fflush(stdout)
    } catch {
        print("WRITE ERR \(name): \(error)", terminator: "\n"); fflush(stdout)
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.04))
}

private struct TypingPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox {
                Label("Phương thức gõ", systemImage: "keyboard")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Picker("Gõ", selection: .constant(1)) {
                    Text("Off (Anh)").tag(0)
                    Text("Telex").tag(1)
                    Text("Simple Telex").tag(2)
                    Text("VNI").tag(3)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .padding(.vertical, 2)

                Picker("Kiểu dấu (oa oe oy uy)", selection: .constant(0)) {
                    Text("Kiểu cũ — òa, oẹ, úy").tag(0)
                    Text("Kiểu mới — oà, oẹ, uý").tag(1)
                }
                .pickerStyle(.segmented)

                Toggle("'w' đầu word giữ nguyên phụ âm", isOn: .constant(true))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Toggle("Bật macro (gõ tắt) — macros.tsv", isOn: .constant(true))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(6)

            GroupBox {
                Label("Phím mở Clipboard history", systemImage: "doc.on.clipboard")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("⌥ Space")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                Text("Nhấp vào đây rồi nhấn tổ hợp phím mới…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(6)
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct AppsPreview: View {
    var body: some View {
        SettingsAppsTab(model: .shared)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct OverlayRowsPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PickerRow(entry: ClipboardEntry(id: 1, kind: .text, createdAt: Date(), sourceBundleID: "com.apple.TextEdit", text: "Hôm nay trời đẹp — minutes of meeting…"), isSelected: true)
            PickerRow(entry: ClipboardEntry(id: 2, kind: .image, createdAt: Date(), sourceBundleID: "com.apple.Screenshot", imageData: Data(count: 49_152)))
            PickerRow(entry: ClipboardEntry(id: 3, kind: .fileURL, createdAt: Date(), sourceBundleID: "com.apple.Finder", fileURL: URL(fileURLWithPath: "/Users/you/Downloads/bao-cao-quy3.key")))
            PickerRow(entry: ClipboardEntry(id: 4, kind: .text, createdAt: Date(), sourceBundleID: "com.tinyspeck.slackmacgap", text: "fix: đổi mode qua ⌥Space rồi gõ thử 'ddawng' = đăng như TestNote…"))
            Spacer()
        }
        .padding(8)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Mirror of the OpenKey-style panel layout without any NSView-backed
/// controls (recorder → key pill, Table → static rows) so ImageRenderer
/// can rasterize the whole thing for layout eyeballing.
private struct SettingsLitePreview: View {
    @ObservedObject private var model = SettingsModel.shared

    var body: some View {
        VStack(spacing: 0) {
            GroupBox(label: Text("Điều khiển").font(.headline)) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text("Kiểu gõ:").frame(width: 78, alignment: .leading)
                            Picker("", selection: $model.method) {
                                Text("Telex").tag(ViInputMethod.telex)
                                Text("Simple Telex").tag(ViInputMethod.simpleTelex)
                                Text("VNI").tag(ViInputMethod.vni)
                                Text("Tắt").tag(ViInputMethod.off)
                            }
                            .labelsHidden().frame(width: 150)
                        }
                        HStack(spacing: 8) {
                            Text("Bảng mã:").frame(width: 78, alignment: .leading)
                            Picker("", selection: .constant(0)) { Text("Unicode").tag(0) }
                                .labelsHidden().frame(width: 150).disabled(true)
                        }
                        HStack(spacing: 8) {
                            Text("Phím chuyển:").frame(width: 78, alignment: .leading)
                            Text("⌥ Z")
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(Color(nsColor: .controlBackgroundColor))
                                .cornerRadius(6)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                            Toggle("Âm báo", isOn: $model.beepOnModeSwitch)
                                .toggleStyle(.checkbox).font(.footnote)
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Chế độ gõ").font(.subheadline).bold()
                        Picker("", selection: $model.isEnglishMode) {
                            Text("Tiếng Việt").tag(false)
                            Text("English").tag(true)
                        }
                        .pickerStyle(.radioGroup).labelsHidden()
                        .horizontalRadioGroupLayout()
                        Text("Chuyển nhanh: menu bar V/E hoặc phím chuyển")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(8)
            }
            .padding([.horizontal, .top])

            VStack(spacing: 12) {
                Picker("", selection: .constant(0)) {
                    Text("Bộ gõ").tag(0)
                    Text("Gõ tắt").tag(1)
                    Text("Hệ thống").tag(2)
                    Text("Thông tin").tag(3)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                engineLite
            }
        }
        .frame(width: 640, height: 500)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var engineLite: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
            GridRow {
                Toggle("Đặt dấu òa, úy (thay vì oà, uý)", isOn: .constant(true)).toggleStyle(.checkbox)
                Toggle("Kiểm tra chính tả tiếng Việt", isOn: .constant(true)).toggleStyle(.checkbox)
            }
            GridRow {
                Toggle("Tương thích gợi ý tự động", isOn: .constant(true)).toggleStyle(.checkbox)
                Toggle("Tự khôi phục phím khi gõ lặp", isOn: .constant(true)).toggleStyle(.checkbox)
            }
            GridRow {
                Toggle("Tự động viết hoa đầu câu", isOn: .constant(false)).toggleStyle(.checkbox)
                Toggle("Giữ phím W đầu từ làm phụ âm", isOn: .constant(true)).toggleStyle(.checkbox)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }
}

private func typingPreview() -> some View { TypingPreview() }
private func appsPreview() -> some View { AppsPreview() }
private func overlayRowsPreview() -> some View { OverlayRowsPreview() }

@main
struct KeyVVisualHarness {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        print("harness start", terminator: "\n"); fflush(stdout)

        // ImageRenderer's SwiftUI update cycle only survives one render
        // per process — run one view per invocation (see README note).
        guard CommandLine.arguments.count >= 2 else {
            print("usage: KeyVVisual <settings|onboarding|overlay|update>", terminator: "\n"); fflush(stdout)
            exit(2)
        }
        let which = CommandLine.arguments[1]

        if which == "settings-window" {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 650),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "KeyV — Xem trước cài đặt"
            window.minSize = NSSize(width: 700, height: 620)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsRootView())
            window.center()
            WindowFocusCoordinator.shared.present(window)
            NSApp.run()
            return
        }

        let isDark = CommandLine.arguments.contains("--dark")
        let suffix = isDark ? "_dark" : ""

        switch which {
        case "settings":
            renderPNG(SettingsRootView(initialTab: .engine).background(Color(nsColor: .windowBackgroundColor)), size: NSSize(width: 720, height: 650), name: "kv_settings\(suffix).png", dark: isDark)
        case "settings-apps":
            renderPNG(SettingsRootView(initialTab: .apps).background(Color(nsColor: .windowBackgroundColor)), size: NSSize(width: 720, height: 650), name: "kv_settings_apps\(suffix).png", dark: isDark)
        case "settings-macros":
            renderPNG(SettingsRootView(initialTab: .macros).background(Color(nsColor: .windowBackgroundColor)), size: NSSize(width: 720, height: 650), name: "kv_settings_macros\(suffix).png", dark: isDark)
        case "settings-system":
            renderPNG(SettingsRootView(initialTab: .system).background(Color(nsColor: .windowBackgroundColor)), size: NSSize(width: 720, height: 650), name: "kv_settings_system\(suffix).png", dark: isDark)
        case "settings-about":
            renderPNG(SettingsRootView(initialTab: .about).background(Color(nsColor: .windowBackgroundColor)), size: NSSize(width: 720, height: 650), name: "kv_settings_about\(suffix).png", dark: isDark)
        case "settingslite":
            renderPNG(SettingsLitePreview(), size: NSSize(width: 640, height: 500), name: "kv_settings_lite\(suffix).png", dark: isDark)
        case "onboarding":
            renderPNG(OnboardingView().background(Color(nsColor: .windowBackgroundColor)), size: NSSize(width: 540, height: 560), name: "kv_onboarding\(suffix).png", dark: isDark)
        case "update":
            renderPNG(UpdateWindowView().background(Color(nsColor: .windowBackgroundColor)), size: NSSize(width: 520, height: 390), name: "kv_update\(suffix).png", dark: isDark)
        case "typing":
            renderPNG(typingPreview(), size: NSSize(width: 540, height: 380), name: "kv_typing\(suffix).png", dark: isDark)
        case "apps":
            renderPNG(appsPreview(), size: NSSize(width: 640, height: 420), name: "kv_apps\(suffix).png", dark: isDark)
        case "overlayrows":
            renderPNG(overlayRowsPreview(), size: NSSize(width: 580, height: 440), name: "kv_overlayrows\(suffix).png", dark: isDark)
        case "overlay":
            let controller = PickerController()
            controller.entries = [
                ClipboardEntry(id: 1, kind: .text, createdAt: Date(), sourceBundleID: "com.apple.TextEdit", text: "Hôm nay trời đẹp — minutes of meeting…"),
                ClipboardEntry(id: 2, kind: .image, createdAt: Date(), sourceBundleID: "com.apple.Screenshot", imageData: Data(count: 49_152)),
                ClipboardEntry(id: 3, kind: .fileURL, createdAt: Date(), sourceBundleID: "com.apple.Finder", fileURL: URL(fileURLWithPath: "/Users/you/Downloads/bao-cao-quy3.key")),
                ClipboardEntry(id: 4, kind: .text, createdAt: Date(), sourceBundleID: "com.tinyspeck.slackmacgap", text: "fix: đổi mode qua ⌥Space rồi gõ thử 'ddawng' = đăng như TestNote…"),
            ]
            controller.selectionIndex = 0
            renderPNG(PickerList(controller: controller), size: NSSize(width: 580, height: 440), name: "kv_overlay\(suffix).png", dark: isDark)
        default:
            exit(2)
        }
        exit(0)
    }
}
