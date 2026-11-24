import AppKit
import CryptoKit
import Foundation
import Security
import SwiftUI

public struct SemVer: Comparable, Equatable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: String?

    public var description: String {
        if let prerelease, !prerelease.isEmpty {
            return "\(major).\(minor).\(patch)-\(prerelease)"
        }
        return "\(major).\(minor).\(patch)"
    }

    public init?(parsing raw: String) {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            trimmed.removeFirst()
        }
        if let plusIdx = trimmed.firstIndex(of: "+") {
            trimmed = String(trimmed[..<plusIdx])
        }
        let dashParts = trimmed.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let corePart = dashParts.first, !corePart.isEmpty else { return nil }
        let nums = corePart.split(separator: ".", omittingEmptySubsequences: false)
        guard nums.count >= 2 && nums.count <= 3 else { return nil }
        guard let maj = Int(nums[0]), let min = Int(nums[1]) else { return nil }
        let pat: Int
        if nums.count == 3 {
            guard let p = Int(nums[2]) else { return nil }
            pat = p
        } else {
            pat = 0
        }
        self.major = maj
        self.minor = min
        self.patch = pat
        self.prerelease = dashParts.count > 1 && !dashParts[1].isEmpty ? String(dashParts[1]) : nil
    }

    public static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil): return false
        case (.some, nil): return true
        case (nil, .some): return false
        case let (.some(a), .some(b)): return a.localizedStandardCompare(b) == .orderedAscending
        }
    }
}

public struct GitHubReleasePayload: Codable, Sendable {
    public struct Asset: Codable, Sendable, Equatable {
        public let name: String
        public let browserDownloadURL: URL
        public let size: Int
        public let digest: String?

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case size
            case digest
        }
    }

    public let tagName: String
    public let name: String?
    public let body: String?
    public let htmlURL: URL
    public let draft: Bool
    public let prerelease: Bool
    public let publishedAt: String?
    public let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case draft
        case prerelease
        case publishedAt = "published_at"
        case assets
    }
}

public enum UpdateVerification {
    public static func parseSHA256Sums(_ text: String, assetName: String) -> String? {
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2 else { continue }
            let hash = String(parts[0]).lowercased()
            var file = String(parts[1])
            if file.hasPrefix("*") || file.hasPrefix("./") {
                file = file.trimmingCharacters(in: CharacterSet(charactersIn: "*./"))
            }
            let base = (file as NSString).lastPathComponent
            if base == assetName && hash.count == 64 {
                return hash
            }
        }
        return nil
    }

    public static func selectArchiveAsset(from assets: [GitHubReleasePayload.Asset]) -> GitHubReleasePayload.Asset? {
        let zips = assets.filter { $0.name.lowercased().hasSuffix(".zip") }
        if let universal = zips.first(where: { $0.name.lowercased().contains("universal") || $0.name.lowercased().contains("macos") }) {
            return universal
        }
        return zips.first
    }

    public static func sha256Hex(of fileURL: URL) throws -> String {
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public struct SigningStatusInfo: Sendable {
    public let summary: String
    public let preservesTCC: Bool
    public let designatedRequirement: String

    public static func inspectCurrentBundle(at bundleURL: URL = Bundle.main.bundleURL) -> SigningStatusInfo {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else {
            return SigningStatusInfo(
                summary: "Chưa ký code (unsigned)",
                preservesTCC: false,
                designatedRequirement: ""
            )
        }

        var infoDict: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(code, flags, &infoDict) == errSecSuccess,
              let info = infoDict as? [String: Any] else {
            return SigningStatusInfo(
                summary: "Không đọc được chữ ký",
                preservesTCC: false,
                designatedRequirement: ""
            )
        }

        var reqString = ""
        var requirement: SecRequirement?
        if SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess,
           let requirement {
            var cfStr: CFString?
            if SecRequirementCopyString(requirement, [], &cfStr) == errSecSuccess,
               let cfStr {
                reqString = cfStr as String
            }
        }

        if let certs = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
           let leaf = certs.first {
            var commonName: CFString?
            SecCertificateCopyCommonName(leaf, &commonName)
            let name = (commonName as String?) ?? "Certificate"
            let stable = !reqString.contains("cdhash H\"")
            return SigningStatusInfo(
                summary: name,
                preservesTCC: stable,
                designatedRequirement: reqString
            )
        }

        return SigningStatusInfo(
            summary: "Ad-hoc (cục bộ)",
            preservesTCC: false,
            designatedRequirement: reqString
        )
    }
}

@MainActor
public final class UpdateService: ObservableObject {
    public static let shared = UpdateService()

    public static let repoOwner = "nhuuduc"
    public static let repoName = "keyv"
    public static let fallbackVersion = "0.3.0"

    public struct AvailableUpdate: Equatable, Sendable {
        public let version: SemVer
        public let tagName: String
        public let title: String
        public let notes: String
        public let htmlURL: URL
        public let archiveAsset: GitHubReleasePayload.Asset?
        public let checksumAsset: GitHubReleasePayload.Asset?
    }

    public enum State: Equatable {
        case idle
        case checking
        case upToDate(String)
        case updateAvailable(AvailableUpdate)
        case downloading(AvailableUpdate, Double)
        case installing(AvailableUpdate)
        case failed(String)
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var availableUpdate: AvailableUpdate?

    private var backgroundTimer: Timer?
    private var updateWindow: NSWindow?
    private let checkInterval: TimeInterval = 12 * 3600

    public var currentVersionString: String {
        if let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           !short.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return short
        }
        return Self.fallbackVersion
    }

    public var currentSemVer: SemVer {
        SemVer(parsing: currentVersionString) ?? SemVer(parsing: Self.fallbackVersion)!
    }

    public func startAutomaticChecks() {
        backgroundTimer?.invalidate()
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.runScheduledCheckIfNeeded()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        backgroundTimer = timer

        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self] in
            self?.runScheduledCheckIfNeeded()
        }
    }

    public func stopAutomaticChecks() {
        backgroundTimer?.invalidate()
        backgroundTimer = nil
    }

    private func runScheduledCheckIfNeeded() {
        guard AppSettings.shared.autoCheckUpdates else { return }
        let last = AppSettings.shared.lastUpdateCheckTimestamp
        let now = Date().timeIntervalSince1970
        guard now - last >= checkInterval else { return }
        Task {
            await checkForUpdates(userInitiated: false)
        }
    }

    public func showUpdateWindowAndCheck() {
        presentUpdateWindow()
        Task {
            await checkForUpdates(userInitiated: true)
        }
    }

    public func presentUpdateWindow() {
        if updateWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 340),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Cập nhật KeyV"
            window.isReleasedWhenClosed = false
            window.center()
            window.contentView = NSHostingView(rootView: UpdateWindowView(service: self))
            updateWindow = window
        }
        updateWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func checkForUpdates(userInitiated: Bool) async {
        if case .downloading = state { return }
        if case .installing = state { return }

        state = .checking
        let endpoint = URL(string: "https://api.github.com/repos/\(Self.repoOwner)/\(Self.repoName)/releases/latest")!
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("KeyV/\(currentVersionString)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            AppSettings.shared.lastUpdateCheckTimestamp = Date().timeIntervalSince1970

            if http.statusCode == 404 {
                state = .upToDate(currentVersionString)
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                throw NSError(
                    domain: "KeyVUpdate",
                    code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "GitHub trả về mã HTTP \(http.statusCode)."]
                )
            }

            let release = try JSONDecoder().decode(GitHubReleasePayload.self, from: data)
            guard !release.draft, !release.prerelease,
                  let remoteVer = SemVer(parsing: release.tagName) else {
                state = .upToDate(currentVersionString)
                return
            }

            if remoteVer > currentSemVer {
                let archive = UpdateVerification.selectArchiveAsset(from: release.assets)
                let checksum = release.assets.first {
                    let lower = $0.name.lowercased()
                    return lower == "sha256sums.txt" || lower.endswith(".sha256")
                }
                let update = AvailableUpdate(
                    version: remoteVer,
                    tagName: release.tagName,
                    title: (release.name?.isEmpty == false ? release.name! : "KeyV \(release.tagName)"),
                    notes: release.body ?? "",
                    htmlURL: release.htmlURL,
                    archiveAsset: archive,
                    checksumAsset: checksum
                )
                availableUpdate = update
                state = .updateAvailable(update)
                NotificationCenter.default.post(name: Notification.Name("KeyVUpdateStateChanged"), object: self)
            } else {
                availableUpdate = nil
                state = .upToDate(currentVersionString)
                NotificationCenter.default.post(name: Notification.Name("KeyVUpdateStateChanged"), object: self)
            }
        } catch {
            if userInitiated {
                state = .failed("Không kiểm tra được bản cập nhật: \(error.localizedDescription)")
            } else {
                state = .idle
            }
        }
    }

    public func downloadAndInstall(_ update: AvailableUpdate) async {
        guard let asset = update.archiveAsset else {
            NSWorkspace.shared.open(update.htmlURL)
            return
        }

        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else {
            state = .failed("KeyV đang chạy ngoài gói .app nên không thể tự thay thế. Hãy tải bản mới trên GitHub.")
            return
        }

        let parentDir = bundleURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parentDir.path) else {
            state = .failed("Không có quyền ghi vào \(parentDir.path). Hãy chuyển KeyV.app sang thư mục có quyền ghi hoặc tải thủ công.")
            return
        }

        state = .downloading(update, 0.1)
        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyVUpdate-\(UUID().uuidString)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            let archivePath = stagingDir.appendingPathComponent(asset.name)

            var dlReq = URLRequest(url: asset.browserDownloadURL)
            dlReq.setValue("KeyV/\(currentVersionString)", forHTTPHeaderField: "User-Agent")
            let (tempFile, response) = try await URLSession.shared.download(for: dlReq)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw NSError(domain: "KeyVUpdate", code: 2, userInfo: [NSLocalizedDescriptionKey: "Tải gói cập nhật thất bại."])
            }
            if FileManager.default.fileExists(atPath: archivePath.path) {
                try FileManager.default.removeItem(at: archivePath)
            }
            try FileManager.default.moveItem(at: tempFile, to: archivePath)
            state = .downloading(update, 0.7)

            let expectedDigest = try await resolveExpectedSHA256(for: update, asset: asset)
            if let expectedDigest {
                let actualDigest = try UpdateVerification.sha256Hex(of: archivePath)
                guard actualDigest.lowercased() == expectedDigest.lowercased() else {
                    throw NSError(
                        domain: "KeyVUpdate",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Mã kiểm tra SHA-256 không khớp (dự kiến \(expectedDigest.prefix(12))…, nhận \(actualDigest.prefix(12))…)."]
                    )
                }
            }

            state = .installing(update)
            let unpackDir = stagingDir.appendingPathComponent("unpacked", isDirectory: true)
            try FileManager.default.createDirectory(at: unpackDir, withIntermediateDirectories: true)
            try Self.runProcess("/usr/bin/ditto", arguments: ["-x", "-k", archivePath.path, unpackDir.path])

            guard let stagedApp = Self.locateAppBundle(in: unpackDir) else {
                throw NSError(domain: "KeyVUpdate", code: 4, userInfo: [NSLocalizedDescriptionKey: "Không tìm thấy KeyV.app trong gói tải về."])
            }

            guard let stagedBundle = Bundle(url: stagedApp),
                  stagedBundle.bundleIdentifier == "app.keyv.host" else {
                throw NSError(domain: "KeyVUpdate", code: 5, userInfo: [NSLocalizedDescriptionKey: "Bundle ID của bản cập nhật không hợp lệ."])
            }

            _ = try? Self.runProcess("/usr/bin/xattr", arguments: ["-dr", "com.apple.quarantine", stagedApp.path])
            try Self.runProcess("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", stagedApp.path])

            try Self.launchDetachedSwapAndRelaunch(
                currentPID: ProcessInfo.processInfo.processIdentifier,
                targetApp: bundleURL,
                stagedApp: stagedApp,
                stagingRoot: stagingDir
            )
            NSApp.terminate(nil)
        } catch {
            try? FileManager.default.removeItem(at: stagingDir)
            state = .failed(error.localizedDescription)
        }
    }

    private func resolveExpectedSHA256(
        for update: AvailableUpdate,
        asset: GitHubReleasePayload.Asset
    ) async throws -> String? {
        if let digest = asset.digest, digest.lowercased().hasPrefix("sha256:") {
            let hex = String(digest.dropFirst("sha256:".count)).lowercased()
            if hex.count == 64 { return hex }
        }
        guard let sumAsset = update.checksumAsset else { return nil }
        var req = URLRequest(url: sumAsset.browserDownloadURL)
        req.setValue("KeyV/\(currentVersionString)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return UpdateVerification.parseSHA256Sums(text, assetName: asset.name)
    }

    private static func locateAppBundle(in directory: URL) -> URL? {
        let direct = directory.appendingPathComponent("KeyV.app")
        if FileManager.default.fileExists(atPath: direct.path) {
            return direct
        }
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let url as URL in enumerator where url.pathExtension == "app" {
            return url
        }
        return nil
    }

    @discardableResult
    private static func runProcess(_ executable: String, arguments: [String]) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        try proc.run()
        proc.waitUntilExit()
        let errStr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard proc.terminationStatus == 0 else {
            throw NSError(
                domain: "KeyVUpdate",
                code: Int(proc.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: errStr.isEmpty ? "\(executable) thất bại (\(proc.terminationStatus))" : errStr.trimmingCharacters(in: .whitespacesAndNewlines)]
            )
        }
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private static func launchDetachedSwapAndRelaunch(
        currentPID: pid_t,
        targetApp: URL,
        stagedApp: URL,
        stagingRoot: URL
    ) throws {
        let scriptURL = stagingRoot.appendingPathComponent("relaunch.sh")
        let script = """
        #!/bin/sh
        OLD_PID="$1"
        TARGET_APP="$2"
        STAGED_APP="$3"
        STAGING_ROOT="$4"
        BACKUP_APP="${TARGET_APP}.backup.$$"

        i=0
        while kill -0 "$OLD_PID" 2>/dev/null && [ "$i" -lt 50 ]; do
            sleep 0.2
            i=$((i + 1))
        done

        if [ -d "$TARGET_APP" ]; then
            mv "$TARGET_APP" "$BACKUP_APP" || exit 1
        fi
        if mv "$STAGED_APP" "$TARGET_APP"; then
            rm -rf "$BACKUP_APP" "$STAGING_ROOT"
            /usr/bin/open "$TARGET_APP"
        else
            [ -d "$BACKUP_APP" ] && mv "$BACKUP_APP" "$TARGET_APP"
            exit 1
        fi
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = [
            scriptURL.path,
            String(currentPID),
            targetApp.path,
            stagedApp.path,
            stagingRoot.path,
        ]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
    }
}

private extension String {
    func endswith(_ suffix: String) -> Bool {
        hasSuffix(suffix)
    }
}

public struct UpdateWindowView: View {
    @ObservedObject var service: UpdateService

    @MainActor
    public init(service: UpdateService? = nil) {
        self.service = service ?? .shared
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                if let icon = KeyVIcon.swiftImage(size: 48) {
                    icon.resizable().frame(width: 48, height: 48)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                        .resizable()
                        .frame(width: 48, height: 48)
                        .foregroundStyle(Color.accentColor)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Cập nhật KeyV").font(.title3.bold())
                    Text("Phiên bản hiện tại: v\(service.currentVersionString)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            switch service.state {
            case .idle:
                Text("Nhấn Kiểm tra ngay để tìm phiên bản mới từ GitHub Releases.")
                    .foregroundStyle(.secondary)
                Spacer()
                HStack {
                    Spacer()
                    Button("Kiểm tra ngay") {
                        Task { await service.checkForUpdates(userInitiated: true) }
                    }
                    .buttonStyle(.borderedProminent)
                }

            case .checking:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Đang kiểm tra phiên bản mới trên GitHub…")
                }
                Spacer()

            case .upToDate(let ver):
                Label("Bạn đang sử dụng phiên bản mới nhất (v\(ver)).", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Spacer()
                HStack {
                    Button("Mở trang GitHub Releases") {
                        NSWorkspace.shared.open(URL(string: "https://github.com/nhuuduc/keyv/releases")!)
                    }
                    Spacer()
                    Button("Kiểm tra lại") {
                        Task { await service.checkForUpdates(userInitiated: true) }
                    }
                }

            case .updateAvailable(let update):
                Label("Đã có bản cập nhật mới: \(update.title) (v\(update.version.description))", systemImage: "sparkles")
                    .font(.headline)
                if !update.notes.isEmpty {
                    ScrollView {
                        Text(update.notes)
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    Spacer()
                }
                HStack {
                    Button("Xem trên GitHub") {
                        NSWorkspace.shared.open(update.htmlURL)
                    }
                    Spacer()
                    if update.archiveAsset != nil {
                        Button("Cập nhật và khởi động lại") {
                            Task { await service.downloadAndInstall(update) }
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button("Tải thủ công…") {
                            NSWorkspace.shared.open(update.htmlURL)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

            case .downloading(let update, let progress):
                Text("Đang tải bản cập nhật v\(update.version.description)…")
                    .font(.headline)
                ProgressView(value: progress, total: 1.0)
                Spacer()

            case .installing(let update):
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Đang xác minh chữ ký và cài đặt v\(update.version.description)… KeyV sẽ tự khởi động lại.")
                }
                Spacer()

            case .failed(let message):
                Label("Không thể cập nhật tự động", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                HStack {
                    Button("Mở GitHub Releases") {
                        NSWorkspace.shared.open(URL(string: "https://github.com/nhuuduc/keyv/releases")!)
                    }
                    Spacer()
                    Button("Thử lại") {
                        Task { await service.checkForUpdates(userInitiated: true) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(22)
        .frame(width: 480, height: 320)
    }
}
