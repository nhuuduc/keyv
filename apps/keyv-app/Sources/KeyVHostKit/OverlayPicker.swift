import AppKit
import SwiftUI

/// Borderless, floating, non-activating panel hosting the SwiftUI picker.
/// Card style matched against the macOS 14 vibes; arrows/enter handled by
/// the panel's own keyDown (SwiftUI focus engines are more erratic here).
public final class OverlayPickerPanel: NSPanel {
    let controller = PickerController()

    public init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                   styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        hasShadow = true

        let hosting = NSHostingView(rootView: PickerList(controller: controller))
        contentView = hosting

        // Refresh items whenever the panel is summoned.
        NotificationCenter.default.addObserver(
            self, selector: #selector(onWillShow),
            name: NSWindow.didBecomeKeyNotification, object: self)
    }

    @objc private func onWillShow() {
        controller.reload()
    }

    func toggleNearFrontmost() {
        if isVisible {
            orderOut(nil)
        } else {
            positionNearFrontmost()
            makeKeyAndOrderFront(nil)
        }
    }

    func closePanel() {
        orderOut(nil)
    }

    public override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 125: controller.moveSelection(1); return          // ↓
        case 123: controller.moveSelection(-1); return         // ←? left: no-op in vertical list — fall through
        case 126: controller.moveSelection(-1); return         // ↑
        case 36: controller.confirmSelection(); closePanel(); return  // ⏎
        case 53: closePanel(); return                          // esc
        default: break
        }
        super.keyDown(with: event)
    }

    private func positionNearFrontmost() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let frame = screen.visibleFrame
        let size = self.frame.size
        setFrameOrigin(NSPoint(x: frame.midX - size.width / 2,
                               y: frame.maxY - size.height - 120))
    }
}

/// Non-UI controller bridging List state and keyboard handling in one object.
@MainActor
public final class PickerController: ObservableObject {
    public init() {}

    @Published public var entries: [ClipboardEntry] = []
    @Published public var selectionIndex: Int = 0

    public func reload() {
        entries = ClipboardStore.shared.latest(limit: AppSettings.shared.clipboardRetentionLimit)
        selectionIndex = min(max(selectionIndex, 0), max(entries.count - 1, 0))
    }

    public func moveSelection(_ delta: Int) {
        let count = entries.count
        guard count > 0 else { return }
        selectionIndex = (selectionIndex + delta + count) % count
    }

    public func confirmSelection() {
        guard entries.indices.contains(selectionIndex) else { return }
        ClipboardPaster.paste(entries[selectionIndex])
    }
}

// MARK: - SwiftUI list

public struct PickerList: View {
    @ObservedObject private var controller: PickerController

    public init(controller: PickerController) {
        self.controller = controller
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Clipboard")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Text("↑↓ select · ⏎ paste · esc close")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding([.top, .horizontal], 14)
            .padding(.bottom, 8)

            List(controller.entries.indices, id: \.self) { index in
                let entry = controller.entries[index]
                PickerRow(entry: entry)
                    .background(index == controller.selectionIndex
                                ? Color.accentColor.opacity(0.22)
                                : Color.clear)
            }
            .listStyle(.plain)
        }
        .background(VisualEffectBackground())
    }
}

public struct PickerRow: View {
    let entry: ClipboardEntry

    public init(entry: ClipboardEntry) {
        self.entry = entry
    }

    public var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    private var iconName: String {
        switch entry.kind {
        case .text: return "doc.text"
        case .image: return "photo"
        case .fileURL: return "folder"
        }
    }

    private var summary: String {
        switch entry.kind {
        case .text: return entry.text
        case .image: return "Image (\(entry.imageData.count) bytes)"
        case .fileURL: return entry.fileURL.lastPathComponent
        }
    }

    private var subtitle: String {
        let fmt = DateFormatter()
        fmt.dateStyle = .none
        fmt.timeStyle = .short
        let source = entry.sourceBundleID.isEmpty ? "-" : entry.sourceBundleID
        return "\(source) · \(fmt.string(from: entry.createdAt))"
    }
}

public struct VisualEffectBackground: NSViewRepresentable {
    public init() {}
    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 14
        view.layer?.masksToBounds = true
        return view
    }
    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
