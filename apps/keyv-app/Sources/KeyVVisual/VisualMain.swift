import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Carbon.HIToolbox
import KeyVCore
import KeyVHostKit

// Visual harness: renders the real SwiftUI views to PNG for eyeballing.
// Run manually only; not part of the shipped app.

@MainActor
private func renderPNG<V: View>(_ view: V, size: NSSize, name: String) {


    print("render \(name)", terminator: "\n"); fflush(stdout)
    let renderer = ImageRenderer(content: view)
    renderer.proposedSize = ProposedViewSize(width: size.width, height: size.height)
    renderer.scale = 2
    guard let img = renderer.nsImage else {
        print("render nil for \(name)", terminator: "\n"); fflush(stdout)
        return
    }
    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else {
        print("tiff nil for \(name)", terminator: "\n"); fflush(stdout)
        return
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
    // Drain the SwiftUI update cycle so the next ImageRenderer has a
    // transaction to enqueue into (otherwise SwiftUICore traps).
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
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
                Text("⌥Space")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
                    .background(Color(white: 0.92))
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(white: 0.75)))
                Text("Click vào đây rồi nhấn tổ hợp phím mới…")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(6)
        }
        .padding()
    }
}

private struct AppsPreview: View {
    var body: some View {
        SettingsAppsTab(model: .shared)
    }
}

private struct OverlayRowsPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PickerRow(entry: ClipboardEntry(id: 1, kind: .text, createdAt: Date(), sourceBundleID: "com.apple.TextEdit", text: "Hôm nay trời đẹp — minutes of meeting…"))
            PickerRow(entry: ClipboardEntry(id: 2, kind: .image, createdAt: Date(), sourceBundleID: "com.apple.Screenshot"))
            PickerRow(entry: ClipboardEntry(id: 3, kind: .fileURL, createdAt: Date(), sourceBundleID: "com.apple.Finder", fileURL: URL(fileURLWithPath: "/Users/you/Downloads/bao-cao-quy3.key")))
            PickerRow(entry: ClipboardEntry(id: 4, kind: .text, createdAt: Date(), sourceBundleID: "slack", text: "fix: đổi mode qua ⌥Space rồi gõ thử 'ddawng' = đăng như TestNote…"))
            Spacer()
        }
        .background(Color(white: 0.12))
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
                            Text("Kiểu gõ:").frame(width: 72, alignment: .leading)
                            Picker("", selection: $model.method) {
                                Text("Telex").tag(ViInputMethod.telex)
                                Text("Simple Telex").tag(ViInputMethod.simpleTelex)
                                Text("VNI").tag(ViInputMethod.vni)
                                Text("Tắt").tag(ViInputMethod.off)
                            }
                            .labelsHidden().frame(width: 150)
                        }
                        HStack(spacing: 8) {
                            Text("Bảng mã:").frame(width: 72, alignment: .leading)
                            Picker("", selection: .constant(0)) { Text("Unicode").tag(0) }
                                .labelsHidden().frame(width: 150).disabled(true)
                        }
                        HStack(spacing: 8) {
                            Text("Phím chuyển:").frame(width: 72, alignment: .leading)
                            Text("⌥Space")
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 10).padding(.vertical, 3)
                                .background(Color(white: 0.92)).cornerRadius(5)
                            Toggle("Kêu beep", isOn: $model.beepOnModeSwitch)
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
                            .font(.caption).foregroundColor(.secondary)
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
        .frame(width: 560, height: 470)
    }

    private var engineLite: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
            GridRow {
                Toggle("Đặt dấu oa, úy (thay vì oà, uý)", isOn: .constant(true)).toggleStyle(.checkbox)
                Toggle("Kiểm tra chính tả", isOn: .constant(false)).toggleStyle(.checkbox).disabled(true)
            }
            GridRow {
                Toggle("Sửa lỗi gõ ý (trình duyệt, Excel,…)", isOn: .constant(true)).toggleStyle(.checkbox)
                Toggle("Tự khôi phục phím đã gõ sai", isOn: .constant(true)).toggleStyle(.checkbox)
            }
            GridRow {
                Toggle("Viết Hoa chữ cái đầu câu", isOn: .constant(false)).toggleStyle(.checkbox)
                Toggle("Cho phép \"z w j f\" làm phím âm", isOn: .constant(true)).toggleStyle(.checkbox)
            }
            GridRow {
                Toggle("Chuyển chế độ thông minh", isOn: .constant(false)).toggleStyle(.checkbox).disabled(true)
                Toggle("Tự ghi nhớ bảng mã theo ứng dụng", isOn: .constant(false)).toggleStyle(.checkbox).disabled(true)
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
            print("usage: KeyVVisual <settings|onboarding|overlay>", terminator: "\n"); fflush(stdout)
            exit(2)
        }
        let which = CommandLine.arguments[1]

        switch which {
        case "settings":
            renderPNG(SettingsRootView(), size: NSSize(width: 680, height: 540), name: "kv_settings.png")
        case "settingslite":
            renderPNG(SettingsLitePreview(), size: NSSize(width: 560, height: 470), name: "kv_settings_lite.png")
        case "onboarding":
            renderPNG(OnboardingView(), size: NSSize(width: 520, height: 540), name: "kv_onboarding.png")
        case "typing":
            // Tab content w/o the NSViewRepresentable recorder (ImageRenderer
            // cannot rasterize those; the real app renders them fine).
            renderPNG(typingPreview(), size: NSSize(width: 520, height: 380), name: "kv_typing.png")
        case "apps":
            renderPNG(appsPreview(), size: NSSize(width: 520, height: 380), name: "kv_apps.png")
        case "overlayrows":
            renderPNG(overlayRowsPreview(), size: NSSize(width: 560, height: 420), name: "kv_overlayrows.png")
        case "overlay":
            let controller = PickerController()
            controller.entries = [
                ClipboardEntry(id: 1, kind: .text, createdAt: Date(), sourceBundleID: "com.apple.TextEdit", text: "Hôm nay trời đẹp — minutes of meeting…"),
                ClipboardEntry(id: 2, kind: .image, createdAt: Date(), sourceBundleID: "com.apple.Screenshot"),
                ClipboardEntry(id: 3, kind: .fileURL, createdAt: Date(), sourceBundleID: "com.apple.Finder", fileURL: URL(fileURLWithPath: "/Users/you/Downloads/bao-cao-quy3.key")),
                ClipboardEntry(id: 4, kind: .text, createdAt: Date(), sourceBundleID: "slack", text: "fix: đổi mode qua ⌥Space rồi gõ thử 'ddawng' = đăng như TestNote…"),
            ]
            controller.selectionIndex = 0
            renderPNG(PickerList(controller: controller), size: NSSize(width: 560, height: 420), name: "kv_overlay.png")
        default:
            exit(2)
        }
        exit(0)
    }
}
