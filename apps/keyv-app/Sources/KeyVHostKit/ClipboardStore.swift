import Foundation
import CryptoKit
import SQLite3
import Security
import SQLite3

// SQLITE_TRANSIENT is a C macro ((sqlite3_destructor_type)-1) not exported
// to Swift; express it with the standard unsafeBitCast trick.
private var SQLITE_TRANSIENT: sqlite3_destructor_type {
    unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
}

/// Clipboard entry stored in the vault.
public struct ClipboardEntry: Identifiable, Equatable {
    public enum Kind: String { case text, image, fileURL }

    public var id: Int64
    public var kind: Kind
    public var createdAt: Date
    public var sourceBundleID: String
    var secret = false  // never stored; filter applies before persist

    // Payload decoded lazily (one of these based on kind):
    public var text: String = ""
    public var imageData: Data = .init()
    public var fileURL: URL = .init(fileURLWithPath: "")

    public init(id: Int64,
                kind: Kind,
                createdAt: Date,
                sourceBundleID: String,
                text: String = "",
                imageData: Data = .init(),
                fileURL: URL = .init(fileURLWithPath: "")) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.sourceBundleID = sourceBundleID
        self.text = text
        self.imageData = imageData
        self.fileURL = fileURL
    }
}

/// SQLite + AES-256-GCM vault (Gotcha 4: no SQLCipher dependency, AES at the
/// application layer with a macOS Keychain-resident 256-bit key; large blobs
/// stay in-DB for P4-MVP, sized-config pruning trims the table).
final class ClipboardStore {
    static let shared = ClipboardStore()

    private var db: OpaquePointer?
    private var key = SymmetricKey(size: .bits256)
    private let queue = DispatchQueue(label: "keyv.clipboard-store", qos: .utility)

    init(dbPath: URL? = nil) {
        key = Self.loadOrCreateVaultKey()
        db = openConnection(at: dbPath ?? Self.defaultPath())
        if let db {
            Self.execSchema(db)
        }
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    // MARK: - Paths

    static func dataDir() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("KeyV", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func defaultPath() -> URL {
        dataDir().appendingPathComponent("clipboard.db")
    }

    // MARK: - Keychain key

    private static func loadOrCreateVaultKey() -> SymmetricKey {
        let service = "KeyV"
        let account = "clipboard-vault-key"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data {
            return SymmetricKey(data: data)
        }

        // Generate and store a fresh key.
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: keyData,
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess {
            NSLog("[KeyV] Keychain add failed (\(addStatus)); using in-memory key (vault lost on exit)")
        }
        return key
    }

    // MARK: - SQLite plumbing

    private func openConnection(at path: URL) -> OpaquePointer? {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            NSLog("[KeyV] sqlite open failed at \(path.path)")
            return nil
        }
        sqlite3_busy_timeout(handle, 1200)
        return handle
    }

    private static func execSchema(_ handle: OpaquePointer) {
        let sql = """
        CREATE TABLE IF NOT EXISTS entries (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            kind TEXT NOT NULL,
            created REAL NOT NULL,
            bundle_id TEXT NOT NULL DEFAULT '',
            data BLOB NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_entries_created ON entries(created DESC);
        """
        let qualifiedErr = sqlite3_exec(handle, sql, nil, nil, nil)
        if qualifiedErr != SQLITE_OK {
            NSLog("[KeyV] schema exec failed: \(String(cString: sqlite3_errmsg(handle)))")
        }
    }

    private static func errorMessage(_ db: OpaquePointer?) -> String {
        String(cString: sqlite3_errmsg(db))
    }

    // MARK: - Crypto (AES-256-GCM, AAD ties blob → row)

    private static func seal(plain: Data, aad: String, key: SymmetricKey) -> Data {
        let sealed = try? AES.GCM.seal(plain, using: key, authenticating: Data(aad.utf8))
        return sealed?.combined ?? Data()
    }

    private static func unseal(combined: Data, aad: String, key: SymmetricKey) -> Data? {
        try? AES.GCM.open(.init(combined: combined), using: key, authenticating: Data(aad.utf8))
    }

    // MARK: - CRUD

    enum InsertOutcome {
        case stored
        case encryptedFailed
        case dbFailed
    }

    func insert(kind: ClipboardEntry.Kind, payload: Data, bundleID: String, createdAt: Date = Date()) -> Int64 {
        guard let db else { return -1 }
        let id = Int64(Date().timeIntervalSince1970 * 1_000)
        let aad = "\(kind.rawValue)#\(createdAt.timeIntervalSince1970)"
        let sealed = Self.seal(plain: payload, aad: aad, key: key)
        guard !sealed.isEmpty else { return -2 }

        return queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "INSERT INTO entries (kind, created, bundle_id, data) VALUES (?, ?, ?, ?)", -1, &stmt, nil) == SQLITE_OK else {
                NSLog("[KeyV] insert prepare err: \(Self.errorMessage(db))")
                return -1
            }
            sqlite3_bind_text(stmt, 1, kind.rawValue, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_double(stmt, 2, createdAt.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 3, bundleID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sealed.withUnsafeBytes { rawBuf in
                let ptr = rawBuf.bindMemory(to: UInt8.self).baseAddress!
                sqlite3_bind_blob(stmt, 4, ptr, Int32(rawBuf.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                NSLog("[KeyV] insert step err: \(Self.errorMessage(db))")
                return -1
            }
            let rowID = sqlite3_last_insert_rowid(db)
            _ = id
            return rowID
        }
    }

    func latest(limit: Int) -> [ClipboardEntry] {
        guard let db else { return [] }
        return queue.sync {
            var out: [ClipboardEntry] = []
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT id, kind, created, bundle_id, data FROM entries ORDER BY created DESC LIMIT ?", -1, &stmt, nil) == SQLITE_OK else {
                return out
            }
            sqlite3_bind_int(stmt, 1, Int32(limit))
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let kindRaw = String(cString: sqlite3_column_text(stmt, 1))
                let created = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
                let bundle = String(cString: sqlite3_column_text(stmt, 3))
                let dataPointer = sqlite3_column_blob(stmt, 4)
                let dataLen = Int(sqlite3_column_bytes(stmt, 4))
                let combined = dataPointer.map { Data(bytes: $0, count: dataLen) } ?? Data()
                let kind = ClipboardEntry.Kind(rawValue: kindRaw) ?? .text
                let aad = "\(kind.rawValue)#\(created.timeIntervalSince1970)"
                guard let plain = Self.unseal(combined: combined, aad: aad, key: key) else { continue }

                var entry = ClipboardEntry(id: id, kind: kind, createdAt: created, sourceBundleID: bundle)
                switch kind {
                case .text:
                    entry.text = String(data: plain, encoding: .utf8) ?? ""
                case .image:
                    entry.imageData = plain
                case .fileURL:
                    entry.fileURL = URL(string: String(data: plain, encoding: .utf8) ?? "") ?? entry.fileURL
                }
                out.append(entry)
            }
            return out
        }
    }

    /// Delete all entries (from the picker or settings).
    func wipe() {
        guard let db else { return }
        _ = queue.sync {
            sqlite3_exec(db, "DELETE FROM entries", nil, nil, nil)
        }
    }

    /// Trim table beyond a retention limit.
    func prune(keep: Int) {
        guard let db else { return }
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "DELETE FROM entries WHERE id NOT IN (SELECT id FROM entries ORDER BY created DESC LIMIT ?)", -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_int(stmt, 1, Int32(keep))
            _ = sqlite3_step(stmt)
        }
    }

    func touchLastUsed(id: Int64) {
        // For P4-MVP frecency = reorder by created; P4.1 adds use_count.
        guard let db else { return }
        _ = queue.sync {
            sqlite3_exec(db, "UPDATE entries SET created = \(Date().timeIntervalSince1970) WHERE id = \(id)", nil, nil, nil)
        }
    }
}
