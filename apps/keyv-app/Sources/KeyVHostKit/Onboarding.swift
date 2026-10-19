import SwiftUI
import ApplicationServices

/// Icon loading shared by menu bar, onboarding and About.
/// Loads from the host-kit resource bundle (KeyVIcon.png copied there by
/// scripts/make_icon.swift), with a system fallback if missing.
public enum KeyVIcon {
    /// Locates the KeyVHostKit resource bundle without the generated
    /// accessor's fatalError-on-missing behavior (the bundle must be in
    /// Contents/Resources for packaged apps).
    static var moduleBundle: Bundle? {
        let bundleName = "KeyVApp_KeyVHostKit"
        let candidates = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
        ]
        for baseURL in candidates {
            if let base = baseURL,
               let found = Bundle(url: base.appendingPathComponent("\(bundleName).bundle")) {
                return found
            }
        }
        if Bundle.allBundles.first(where: { $0.bundleURL.lastPathComponent == "\(bundleName).bundle" }) != nil {
            return Bundle.allBundles
                .first { $0.bundleURL.lastPathComponent == "\(bundleName).bundle" }
        }
        return nil
    }

    public static func nsImage() -> NSImage? {
        if let bundle = moduleBundle,
           let url = bundle.url(forResource: "KeyVIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = false
            return image
        }
        // Fallback: app-bundle .icns (ships with every release).
        if let image = NSImage(named: "KeyV") {
            image.isTemplate = false
            return image
        }
        return nil
    }

    public static func swiftImage(size: CGFloat) -> Image? {
        guard let base = nsImage() else { return nil }
        base.size = NSSize(width: size, height: size)
        return Image(nsImage: base)
    }
}

/// Deep link to the Accessibility privacy pane. Shared by the onboarding
/// button and the auto-open on first launch.
public enum AccessibilityGate {
    public static let settingsPaneURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    public static func openSettingsPane() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        NSWorkspace.shared.open(settingsPaneURL)
    }
}

@MainActor
public final class PermissionModel: ObservableObject {
    public static let shared = PermissionModel()
    public enum Status { case permissionRequired, hookUnavailable, ready }
    @Published public var status: Status = .permissionRequired
}

public struct OnboardingView: View {
    @ObservedObject private var model = PermissionModel.shared
    private let checkAgain: () -> Void
    public init(checkAgain: @escaping () -> Void = {}) { self.checkAgain = checkAgain }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                if let icon = KeyVIcon.swiftImage(size: 64) {
                    icon.resizable().frame(width: 64, height: 64)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Thiết lập KeyV").font(.system(size: 25, weight: .semibold))
                    Text("Gõ tiếng Việt trong các ứng dụng của bạn")
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            Label(model.status == .hookUnavailable ? "Đã có quyền · Bộ gõ chưa kết nối" : "Cần quyền điều khiển bàn phím",
                  systemImage: model.status == .hookUnavailable ? "exclamationmark.triangle" : "lock.shield")
                .font(.headline)
            Text(model.status == .hookUnavailable
                 ? "macOS đã cấp quyền Trợ năng nhưng chưa cho KeyV kết nối bàn phím. Hãy thử kiểm tra lại; nếu vẫn chưa được, thoát rồi mở lại KeyV."
                 : "KeyV cần quyền Trợ năng để nhận phím và chèn chữ tiếng Việt. Nội dung được xử lý trên máy của bạn.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                Text("1. Mở Cài đặt hệ thống bằng nút bên dưới.")
                Text("2. Bật KeyV trong Trợ năng / Device Control and Data Access.")
                Text("3. Quay lại đây. KeyV sẽ tự kiểm tra quyền.")
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            Text("Đã bật nhưng vẫn chưa nhận? Bản app có thể đã thay đổi sau khi build. Hãy xóa mục KeyV cũ trong danh sách, rồi thêm đúng bản đang chạy bên dưới và bật lại.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Hiện app trong Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }
                Spacer()
                Button("Kiểm tra lại", action: checkAgain)
                Button("Mở Cài đặt…") {
                    AccessibilityGate.openSettingsPane()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            Text(Bundle.main.bundlePath)
                .font(.caption).foregroundStyle(.tertiary)
                .lineLimit(2).textSelection(.enabled)
        }
        .padding(28)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}
