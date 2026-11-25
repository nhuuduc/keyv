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
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                if let icon = KeyVIcon.swiftImage(size: 56) {
                    icon.resizable().frame(width: 56, height: 56)
                } else {
                    Image(systemName: "keyboard.badge.ellipsis")
                        .font(.system(size: 40))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 56, height: 56)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Thiết lập KeyV")
                        .font(.system(size: 23, weight: .bold))
                    Text("Bộ gõ tiếng Việt tốc độ cao & lịch sử clipboard bảo mật")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                permissionBadge
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Label(
                    model.status == .hookUnavailable
                        ? "Đã cấp quyền · Đang chờ kết nối bàn phím"
                        : "Cấp quyền Trợ năng (Accessibility)",
                    systemImage: model.status == .hookUnavailable ? "exclamationmark.triangle.fill" : "hand.raised.shield.fill"
                )
                .font(.headline)
                .foregroundStyle(model.status == .hookUnavailable ? .orange : .primary)

                Text(
                    model.status == .hookUnavailable
                        ? "macOS đã ghi nhận quyền nhưng chưa cho phép phiên chạy hiện tại lắng nghe bàn phím. Hãy nhấn \"Kiểm tra lại\" hoặc khởi động lại KeyV."
                        : "KeyV cần quyền Trợ năng của macOS để xử lý tổ hợp dấu tiếng Việt theo thời gian thực. Mọi dữ liệu gõ phím được xử lý cục bộ ngay trên máy của bạn."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 12) {
                stepRow(
                    number: 1,
                    symbol: "gearshape.fill",
                    title: "Mở Cài đặt Hệ thống → Trợ năng",
                    detail: "Nhấn nút \"Mở Cài đặt Trợ năng…\" bên dưới để chuyển thẳng tới mục cấp quyền."
                )
                Divider()
                stepRow(
                    number: 2,
                    symbol: "switch.2",
                    title: "Bật công tắc cho phép KeyV",
                    detail: "Tìm ứng dụng KeyV trong danh sách và chuyển công tắc sang trạng thái bật."
                )
                Divider()
                stepRow(
                    number: 3,
                    symbol: "checkmark.circle.fill",
                    title: "Tự động kích hoạt",
                    detail: "Quay lại cửa sổ này — KeyV tự động nhận quyền và thu gọn lên thanh menu."
                )
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 6) {
                Label("Mẹo khắc phục khi đã bật nhưng chưa nhận quyền", systemImage: "wrench.and.screwdriver")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Nếu vừa cài đè bản build cục bộ, hãy xóa mục KeyV cũ bằng nút dấu trừ (–) trong Trợ năng rồi kéo bản đang chạy bên dưới vào lại:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Bundle.main.bundlePath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .quaternaryLabelColor).opacity(0.25), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack(spacing: 10) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                } label: {
                    Label("Hiện trong Finder", systemImage: "folder")
                }

                Spacer()

                Button("Kiểm tra lại", action: checkAgain)

                Button {
                    AccessibilityGate.openSettingsPane()
                } label: {
                    Label("Mở Cài đặt Trợ năng…", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var permissionBadge: some View {
        let (title, symbol, color): (String, String, Color) = {
            switch model.status {
            case .ready:
                return ("Đã sẵn sàng", "checkmark.shield.fill", .green)
            case .hookUnavailable:
                return ("Chờ kết nối", "exclamationmark.shield.fill", .orange)
            case .permissionRequired:
                return ("Cần cấp quyền", "lock.shield.fill", .orange)
            }
        }()
        return Label(title, systemImage: symbol)
            .font(.system(size: 11.5, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(0.14), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.35), lineWidth: 1))
            .fixedSize(horizontal: true, vertical: false)
    }

    private func stepRow(number: Int, symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 26, height: 26)
                Text("\(number)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
