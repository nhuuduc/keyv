import AppKit
import Darwin
import Foundation

public enum RemoteSourceKind: Int, Equatable, Hashable, CaseIterable, Sendable {
    case local = 0
    case rustDesk
    case anyDesk
    case teamViewer
    case screenSharing
    case parsec
    case jumpDesktop
    case chromeRemoteDesktop
    case moonlightSunshine

    public var isRemote: Bool {
        self != .local
    }

    public var displayName: String {
        switch self {
        case .local: return "Bàn phím máy Mac"
        case .rustDesk: return "RustDesk"
        case .anyDesk: return "AnyDesk"
        case .teamViewer: return "TeamViewer"
        case .screenSharing: return "Screen Sharing"
        case .parsec: return "Parsec"
        case .jumpDesktop: return "Jump Desktop"
        case .chromeRemoteDesktop: return "Chrome Remote Desktop"
        case .moonlightSunshine: return "Sunshine"
        }
    }
}

public struct ProcessInspectorMetadata: Equatable, Sendable {
    public let bundleID: String?
    public let executablePath: String?
    public let processName: String?

    public init(bundleID: String? = nil, executablePath: String? = nil, processName: String? = nil) {
        self.bundleID = bundleID
        self.executablePath = executablePath
        self.processName = processName
    }
}

public final class RemoteInputDetector {
    public static let shared = RemoteInputDetector()
    public static let rustDeskEnigoUserData: Int64 = 100

    private static let cacheTTLNs: UInt64 = 60_000_000_000
    private static let maxCacheEntries = 512

    private struct CacheEntry {
        let kind: RemoteSourceKind
        let expiresAtNs: UInt64
    }

    private let selfPID: pid_t = ProcessInfo.processInfo.processIdentifier
    private var cache: [pid_t: CacheEntry] = [:]
    private var overrides: [pid_t: RemoteSourceKind] = [:]
    public var metadataResolver: ((pid_t) -> ProcessInspectorMetadata)?

    public init(metadataResolver: ((pid_t) -> ProcessInspectorMetadata)? = nil) {
        self.metadataResolver = metadataResolver
        self.cache.reserveCapacity(64)
    }

    public func setOverride(_ kind: RemoteSourceKind?, for pid: pid_t) {
        overrides[pid] = kind
        cache.removeValue(forKey: pid)
    }

    public func invalidate(pid: pid_t) {
        cache.removeValue(forKey: pid)
    }

    public func invalidateAll() {
        cache.removeAll(keepingCapacity: true)
    }

    @inline(__always)
    public func sourceKind(for pid: pid_t, eventUserData: Int64 = 0, nowNs: UInt64) -> RemoteSourceKind {
        if pid <= 0 || pid == selfPID {
            return .local
        }
        if !overrides.isEmpty, let forced = overrides[pid] {
            return forced
        }
        if let entry = cache[pid], nowNs < entry.expiresAtNs {
            if entry.kind == .local && eventUserData == Self.rustDeskEnigoUserData {
                return .rustDesk
            }
            return entry.kind
        }
        let resolved = resolveAndCache(pid: pid, nowNs: nowNs)
        if resolved == .local && eventUserData == Self.rustDeskEnigoUserData {
            return .rustDesk
        }
        return resolved
    }

    @inline(never)
    private func resolveAndCache(pid: pid_t, nowNs: UInt64) -> RemoteSourceKind {
        let meta = metadataResolver?(pid) ?? Self.systemMetadata(for: pid)
        let kind = Self.classify(meta)
        if cache.count >= Self.maxCacheEntries {
            cache = cache.filter { nowNs < $0.value.expiresAtNs }
            if cache.count >= Self.maxCacheEntries {
                cache.removeAll(keepingCapacity: true)
            }
        }
        cache[pid] = CacheEntry(kind: kind, expiresAtNs: nowNs &+ Self.cacheTTLNs)
        return kind
    }

    public static func classify(
        bundleID: String? = nil,
        executablePath: String? = nil,
        processName: String? = nil
    ) -> RemoteSourceKind {
        classify(ProcessInspectorMetadata(
            bundleID: bundleID,
            executablePath: executablePath,
            processName: processName
        ))
    }

    public static func classify(_ meta: ProcessInspectorMetadata) -> RemoteSourceKind {
        if let rawBundle = meta.bundleID?.lowercased(), !rawBundle.isEmpty {
            if rawBundle == "com.carriez.rustdesk" || rawBundle.hasPrefix("com.carriez.rustdesk.") {
                return .rustDesk
            }
            if rawBundle == "com.philandro.anydesk" || rawBundle.hasPrefix("com.philandro.anydesk.") {
                return .anyDesk
            }
            if rawBundle.hasPrefix("com.teamviewer.") {
                return .teamViewer
            }
            if rawBundle == "com.apple.screensharing.agent"
                || rawBundle == "com.apple.screensharing.daemon"
                || rawBundle == "com.apple.remotedesktopagent"
                || rawBundle.hasPrefix("com.edovia.screens.connect")
                || rawBundle.hasPrefix("com.realvnc.vncserver") {
                return .screenSharing
            }
            if rawBundle.hasPrefix("tv.parsec.") {
                return .parsec
            }
            if rawBundle == "com.p5sys.jump.connect" || rawBundle.hasPrefix("com.p5sys.jump.connect.") {
                return .jumpDesktop
            }
            if rawBundle.hasPrefix("com.google.chromeremotedesktop")
                || rawBundle.hasPrefix("org.chromium.chromoting") {
                return .chromeRemoteDesktop
            }
            if rawBundle.hasPrefix("com.lizardbyte.sunshine")
                || rawBundle.hasPrefix("org.moonlight-stream.") {
                return .moonlightSunshine
            }
        }

        if let rawPath = meta.executablePath?.lowercased(), !rawPath.isEmpty {
            if rawPath.contains("/rustdesk.app/") {
                return .rustDesk
            }
            if rawPath.contains("/anydesk.app/") {
                return .anyDesk
            }
            if rawPath.contains("/teamviewer.app/") || rawPath.contains("/teamviewerhost.app/") {
                return .teamViewer
            }
            if rawPath.contains("/screensharingagent.bundle/")
                || rawPath.contains("/remotedesktopagent.app/")
                || rawPath.contains("/screens connect.app/") {
                return .screenSharing
            }
            if rawPath.contains("/parsec.app/") {
                return .parsec
            }
            if rawPath.contains("/jump desktop connect.app/") {
                return .jumpDesktop
            }
            if rawPath.contains("/chromeremotedesktophost.app/") {
                return .chromeRemoteDesktop
            }
            if rawPath.contains("/sunshine.app/") {
                return .moonlightSunshine
            }

            let base = (rawPath as NSString).lastPathComponent
            if let byExec = classifyExecutableName(base) {
                return byExec
            }
        }

        if let rawProc = meta.processName?.lowercased(),
           let byProc = classifyExecutableName(rawProc) {
            return byProc
        }

        return .local
    }

    private static func classifyExecutableName(_ name: String) -> RemoteSourceKind? {
        switch name {
        case "rustdesk":
            return .rustDesk
        case "anydesk":
            return .anyDesk
        case "teamviewer", "teamviewer_service", "teamviewer_desktop", "teamviewer_desk":
            return .teamViewer
        case "screensharingd", "screensharingagent", "ardagent", "screensconnect", "vncserver":
            return .screenSharing
        case "parsecd", "pservice":
            return .parsec
        case "jumpdesktopconnect", "jumpdesktopconn":
            return .jumpDesktop
        case "remoting_me2me_host", "remoting_me2me_":
            return .chromeRemoteDesktop
        case "sunshine":
            return .moonlightSunshine
        default:
            return nil
        }
    }

    public static func systemMetadata(for pid: pid_t) -> ProcessInspectorMetadata {
        let app = NSRunningApplication(processIdentifier: pid)
        let bundleID = app?.bundleIdentifier
        let pidPath = kernelProcessPath(for: pid)
        let procName = (bundleID == nil && pidPath == nil) ? kernelProcessName(for: pid) : nil
        return ProcessInspectorMetadata(
            bundleID: bundleID,
            executablePath: pidPath,
            processName: procName
        )
    }

    public static func kernelProcessPath(for pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let len = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard len > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func kernelProcessName(for pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let rc = sysctl(&mib, 4, &info, &size, nil, 0)
        guard rc == 0 && size > 0 else { return nil }
        return withUnsafePointer(to: &info.kp_proc.p_comm) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { cStr in
                let s = String(cString: cStr)
                return s.isEmpty ? nil : s
            }
        }
    }

    public func runningRemoteServers() -> [RemoteSourceKind] {
        var found: Set<RemoteSourceKind> = []
        for app in NSWorkspace.shared.runningApplications {
            let pid = app.processIdentifier
            guard pid > 0 && pid != selfPID else { continue }
            let path = Self.kernelProcessPath(for: pid)
            let kind = Self.classify(bundleID: app.bundleIdentifier, executablePath: path)
            if kind.isRemote {
                found.insert(kind)
            }
        }

        let estimatedCount = proc_listallpids(nil, 0)
        if estimatedCount > 0 {
            var pids = [pid_t](repeating: 0, count: Int(estimatedCount) + 32)
            let byteCount = Int32(pids.count * MemoryLayout<pid_t>.stride)
            let actualBytes = proc_listallpids(&pids, byteCount)
            if actualBytes > 0 {
                let count = min(pids.count, Int(actualBytes) / MemoryLayout<pid_t>.stride)
                for idx in 0..<count {
                    let pid = pids[idx]
                    guard pid > 0 && pid != selfPID else { continue }
                    if let path = Self.kernelProcessPath(for: pid) {
                        let kind = Self.classify(executablePath: path)
                        if kind.isRemote {
                            found.insert(kind)
                        }
                    } else if let name = Self.kernelProcessName(for: pid) {
                        let kind = Self.classify(processName: name)
                        if kind.isRemote {
                            found.insert(kind)
                        }
                    }
                }
            }
        }

        let priority: [RemoteSourceKind] = [
            .rustDesk,
            .anyDesk,
            .teamViewer,
            .screenSharing,
            .parsec,
            .jumpDesktop,
            .chromeRemoteDesktop,
            .moonlightSunshine,
        ]
        return priority.filter { found.contains($0) }
    }
}
