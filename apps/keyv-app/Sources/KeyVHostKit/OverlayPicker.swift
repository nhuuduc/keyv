import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
public final class AppMetadataCache {
    public static let shared = AppMetadataCache()

    public struct Info {
        public let name: String
        public let icon: NSImage?
    }

    private var cache: [String: Info] = [:]

    public func info(for bundleID: String) -> Info {
        if bundleID.isEmpty {
            return Info(name: "Hệ thống", icon: nil)
        }
        if let cached = cache[bundleID] {
            return cached
        }
        let seenName = AppSettings.shared.seenAppsJSON[bundleID]
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let rawName = seenName ?? appURL.deletingPathExtension().lastPathComponent
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            icon.size = NSSize(width: 24, height: 24)
            let resolved = Info(name: rawName, icon: icon)
            cache[bundleID] = resolved
            return resolved
        }
        let fallbackIcon = NSWorkspace.shared.icon(for: .applicationBundle)
        fallbackIcon.size = NSSize(width: 24, height: 24)
        let fallbackName = seenName ?? bundleID
        let resolved = Info(name: fallbackName, icon: fallbackIcon)
        cache[bundleID] = resolved
        return resolved
    }

    public func displayName(for bundleID: String) -> String {
        info(for: bundleID).name
    }
}

/// Borderless, floating, non-activating panel hosting the SwiftUI picker.
/// Card style matched against the macOS 14 vibes; arrows/enter handled by
/// the panel's own keyDown (SwiftUI focus engines are more erratic here).
public final class OverlayPickerPanel: NSPanel {
    let controller = PickerController()

    public init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 440),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
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

        controller.onConfirmPaste = { [weak self] in
            self?.confirmAndClose()
        }

        let hosting = NSHostingView(rootView: PickerList(controller: controller))
        contentView = hosting

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onWillShow),
            name: NSWindow.didBecomeKeyNotification,
            object: self
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: self
        )
    }

    public override var canBecomeKey: Bool { true }

    @objc private func onWillShow() {
        controller.searchQuery = ""
        controller.selectionIndex = 0
        controller.reload()
        controller.focusTrigger &+= 1
    }

    @objc private func onDidResignKey() {
        if isVisible {
            closePanel()
        }
    }

    func toggleNearFrontmost() {
        if isVisible {
            orderOut(nil)
        } else {
            controller.searchQuery = ""
            controller.selectionIndex = 0
            controller.reload()
            positionNearFrontmost()
            makeKeyAndOrderFront(nil)
        }
    }

    func closePanel() {
        orderOut(nil)
    }

    private func confirmAndClose() {
        let items = controller.filteredEntries
        guard items.indices.contains(controller.selectionIndex) else { return }
        let chosen = items[controller.selectionIndex]
        orderOut(nil)
        ClipboardPaster.paste(chosen)
    }

    public override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            let hasMarked = (firstResponder as? NSTextView)?.hasMarkedText() == true
            if !hasMarked {
                switch Int(event.keyCode) {
                case 125:
                    controller.moveSelection(1)
                    return
                case 126:
                    controller.moveSelection(-1)
                    return
                case 36, 76:
                    confirmAndClose()
                    return
                case 53:
                    if controller.handleEscape() {
                        closePanel()
                    }
                    return
                default:
                    break
                }
            }
        }
        super.sendEvent(event)
    }

    private func positionNearFrontmost() {
        let mouseLocation = NSEvent.mouseLocation
        let activeScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens[0]
        let frame = activeScreen.visibleFrame
        let size = self.frame.size
        setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.maxY - size.height - 110
        ))
    }
}

/// Non-UI controller bridging List state and keyboard handling in one object.
@MainActor
public final class PickerController: ObservableObject {
    public init() {}

    @Published public var entries: [ClipboardEntry] = [] {
        didSet { clampSelection() }
    }
    @Published public var searchQuery: String = "" {
        didSet {
            if oldValue != searchQuery {
                selectionIndex = 0
            }
        }
    }
    @Published public var selectionIndex: Int = 0
    @Published public var focusTrigger: Int = 0
    public var onConfirmPaste: (() -> Void)?

    public var filteredEntries: [ClipboardEntry] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries }
        return entries.filter { entry in
            switch entry.kind {
            case .text:
                if entry.text.localizedStandardContains(trimmed) { return true }
            case .fileURL:
                if entry.fileURL.lastPathComponent.localizedStandardContains(trimmed) { return true }
                if entry.fileURL.path.localizedStandardContains(trimmed) { return true }
            case .image:
                if "hình ảnh image screenshot ảnh".localizedStandardContains(trimmed) { return true }
            }
            if entry.sourceBundleID.localizedStandardContains(trimmed) { return true }
            let appName = AppMetadataCache.shared.displayName(for: entry.sourceBundleID)
            return appName.localizedStandardContains(trimmed)
        }
    }

    public func reload() {
        entries = ClipboardStore.shared.latest(limit: AppSettings.shared.clipboardRetentionLimit)
        clampSelection()
    }

    public func moveSelection(_ delta: Int) {
        let count = filteredEntries.count
        guard count > 0 else { return }
        selectionIndex = (selectionIndex + delta + count) % count
    }

    @discardableResult
    public func confirmSelection() -> Bool {
        let items = filteredEntries
        guard items.indices.contains(selectionIndex) else { return false }
        ClipboardPaster.paste(items[selectionIndex])
        return true
    }

    @discardableResult
    public func handleEscape() -> Bool {
        if !searchQuery.isEmpty {
            searchQuery = ""
            return false
        }
        return true
    }

    private func clampSelection() {
        let count = filteredEntries.count
        if count == 0 {
            selectionIndex = 0
        } else {
            selectionIndex = min(max(selectionIndex, 0), count - 1)
        }
    }
}

// MARK: - SwiftUI list

public struct PickerList: View {
    @ObservedObject private var controller: PickerController
    @FocusState private var isSearchFocused: Bool

    public init(controller: PickerController) {
        self.controller = controller
    }

    public var body: some View {
        let items = controller.filteredEntries
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)

                TextField("Tìm văn bản, tên tệp hoặc ứng dụng nguồn…", text: $controller.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($isSearchFocused)

                if !controller.searchQuery.isEmpty {
                    Button {
                        controller.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Xóa từ khóa tìm kiếm")
                }

                Text("\(items.count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color(nsColor: .quaternaryLabelColor).opacity(0.5), in: Capsule())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.65))

            Divider()

            if controller.entries.isEmpty {
                emptyStateView(
                    symbol: "doc.on.clipboard",
                    title: "Chưa có mục clipboard nào",
                    subtitle: "Sao chép văn bản, hình ảnh hoặc tệp bằng ⌘C để lưu tự động vào đây."
                )
            } else if items.isEmpty {
                emptyStateView(
                    symbol: "magnifyingglass",
                    title: "Không tìm thấy kết quả phù hợp",
                    subtitle: "Thử từ khóa khác hoặc nhấn Esc để xóa bộ lọc tìm kiếm."
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, entry in
                                let isSelected = index == controller.selectionIndex
                                PickerRow(entry: entry, isSelected: isSelected)
                                    .id(index)
                                    .contentShape(RoundedRectangle(cornerRadius: 8))
                                    .onTapGesture {
                                        let clicks = NSApp.currentEvent?.clickCount ?? 1
                                        controller.selectionIndex = index
                                        if clicks >= 2 {
                                            if let onConfirmPaste = controller.onConfirmPaste {
                                                onConfirmPaste()
                                            } else {
                                                controller.confirmSelection()
                                            }
                                        }
                                    }
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: controller.selectionIndex) { _, newIndex in
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(newIndex, anchor: nil)
                        }
                    }
                }
            }

            Divider()

            HStack(spacing: 12) {
                Label("Lịch sử mã hóa AES-256", systemImage: "lock.shield")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("↑↓ chọn · ⏎ hoặc nhấp đúp để dán · Esc đóng")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
        }
        .background {
            ZStack {
                VisualEffectBackground()
                Color(nsColor: .windowBackgroundColor).opacity(0.75)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.75), lineWidth: 1)
        )
        .onAppear {
            isSearchFocused = true
        }
        .onChange(of: controller.focusTrigger) { _, _ in
            isSearchFocused = true
        }
    }

    private func emptyStateView(symbol: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

public struct PickerRow: View {
    let entry: ClipboardEntry
    let isSelected: Bool

    private static let timeFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateStyle = .none
        fmt.timeStyle = .short
        return fmt
    }()

    private static let byteFormatter: ByteCountFormatter = {
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useKB, .useMB]
        fmt.countStyle = .file
        return fmt
    }()

    public init(entry: ClipboardEntry, isSelected: Bool = false) {
        self.entry = entry
        self.isSelected = isSelected
    }

    public var body: some View {
        let appInfo = AppMetadataCache.shared.info(for: entry.sourceBundleID)
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                if let appIcon = appInfo.icon {
                    Image(nsImage: appIcon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 26, height: 26)
                } else {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .quaternaryLabelColor))
                        .frame(width: 26, height: 26)
                        .overlay {
                            Image(systemName: kindSymbol)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                }

                Image(systemName: kindSymbol)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 13, height: 13)
                    .background(Color(nsColor: .windowBackgroundColor), in: Circle())
                    .overlay(Circle().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
                    .offset(x: 3, y: 2)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(summary)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(kindLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            (isSelected ? Color.accentColor.opacity(0.16) : Color(nsColor: .quaternaryLabelColor).opacity(0.45)),
                            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                        )

                    Text(metadataSubtitle(appName: appInfo.name))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if isSelected {
                Text("⏎ Dán")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
            } else {
                Text(Self.timeFormatter.string(from: entry.createdAt))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 1)
        )
    }

    private var kindSymbol: String {
        switch entry.kind {
        case .text: return "doc.text"
        case .image: return "photo"
        case .fileURL: return "doc"
        }
    }

    private var kindLabel: String {
        switch entry.kind {
        case .text: return "Văn bản"
        case .image: return "Hình ảnh"
        case .fileURL: return "Tệp tin"
        }
    }

    private var summary: String {
        switch entry.kind {
        case .text:
            let collapsed = entry.text
                .replacingOccurrences(of: "\r\n", with: " ↵ ")
                .replacingOccurrences(of: "\n", with: " ↵ ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return collapsed.isEmpty ? "(Văn bản trống)" : collapsed
        case .image:
            let sizeStr = Self.byteFormatter.string(fromByteCount: Int64(entry.imageData.count))
            return "Hình ảnh (\(sizeStr))"
        case .fileURL:
            let name = entry.fileURL.lastPathComponent
            return name.isEmpty ? entry.fileURL.path : name
        }
    }

    private func metadataSubtitle(appName: String) -> String {
        let timeStr = Self.timeFormatter.string(from: entry.createdAt)
        switch entry.kind {
        case .text:
            return "\(appName) · \(entry.text.count) ký tự · \(timeStr)"
        case .image:
            let sizeStr = Self.byteFormatter.string(fromByteCount: Int64(entry.imageData.count))
            return "\(appName) · \(sizeStr) · \(timeStr)"
        case .fileURL:
            let folder = (entry.fileURL.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
            return "\(appName) · \(folder) · \(timeStr)"
        }
    }
}

public struct VisualEffectBackground: NSViewRepresentable {
    public init() {}
    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 14
        view.layer?.masksToBounds = true
        return view
    }
    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
