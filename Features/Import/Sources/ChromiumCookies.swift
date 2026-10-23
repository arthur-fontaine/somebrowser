import BrowserCore
import CommonCrypto
import CryptoKit
import Foundation
import Security
import SQLite3

/// A Chromium profile's cookies, so sites stay signed in. On a Mac the values are encrypted ("v10": AES-128-CBC) with a
/// key derived from a password the browser keeps in the login Keychain ("Chrome Safe Storage"). Reading that password
/// is what makes macOS ask the user, so rows are read for the preview and decrypted only on import.
nonisolated enum ChromiumCookies {
    struct Row: Equatable, Sendable {
        var host: String
        var name: String
        var value: String
        var encryptedValue: Data
        var path: String
        var expires: Date?
        var isSecure: Bool
        var isHTTPOnly: Bool
        /// Chromium's: -1 unspecified, 0 none, 1 lax, 2 strict.
        var sameSite: Int
        /// Database version 24 and up: the plaintext starts with SHA-256 of the host.
        var hostHashed: Bool
    }

    /// `Cookies` in the profile (or in its `Network` folder, where some versions keep it). Partitioned cookies (CHIPS,
    /// a third-party frame's state on one site) and expired ones are left out.
    static func read(profile: URL, now: Date = .now) -> [Row] {
        guard let file = ["Cookies", "Network/Cookies"].map({ profile.appendingPathComponent($0) })
            .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return [] }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("import-cookies-\(UUID().uuidString)")
        defer { for suffix in ["", "-journal", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: copy.path + suffix) } }
        for suffix in ["", "-wal"] where FileManager.default.fileExists(atPath: file.path + suffix) {
            try? FileManager.default.copyItem(atPath: file.path + suffix, toPath: copy.path + suffix)
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return [] }
        defer { sqlite3_close(db) }
        var version = 0
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = 'version'", -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW {
            version = Int(sqlite3_column_int(stmt, 0))
        }
        sqlite3_finalize(stmt)
        let sql = """
        SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly, samesite, has_expires
        FROM cookies WHERE top_frame_site_key = ''
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [Row] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            func text(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
            let expires = sqlite3_column_int(stmt, 9) != 0 ? ChromiumImport.date(chromium: sqlite3_column_int64(stmt, 5)) : nil
            if let expires, expires < now { continue }
            let blob = sqlite3_column_blob(stmt, 3).map { Data(bytes: $0, count: Int(sqlite3_column_bytes(stmt, 3))) } ?? Data()
            out.append(Row(host: text(0), name: text(1), value: text(2), encryptedValue: blob, path: text(4), expires: expires,
                           isSecure: sqlite3_column_int(stmt, 6) != 0, isHTTPOnly: sqlite3_column_int(stmt, 7) != 0,
                           sameSite: Int(sqlite3_column_int(stmt, 8)), hostHashed: version >= 24))
        }
        return out
    }

    /// The Safe Storage password from the login Keychain; macOS asks the user first (nil if they refuse or it's missing).
    static func password(service: String) -> Data? {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                      kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    /// Chromium's derivation on a Mac: PBKDF2-HMAC-SHA1, salt "saltysalt", 1003 rounds, 16 bytes.
    static func key(password: Data) -> Data {
        var key = Data(count: kCCKeySizeAES128)
        let salt = Data("saltysalt".utf8)
        _ = key.withUnsafeMutableBytes { k in
            password.withUnsafeBytes { p in
                salt.withUnsafeBytes { s in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), p.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                                         s.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                                         1003, k.baseAddress?.assumingMemoryBound(to: UInt8.self), kCCKeySizeAES128)
                }
            }
        }
        return key
    }

    /// AES-128-CBC with PKCS#7 padding and Chromium's fixed IV (16 spaces).
    static func aes(_ data: Data, key: Data, encrypt: Bool) -> Data? {
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var length = 0
        let status = out.withUnsafeMutableBytes { o in
            data.withUnsafeBytes { d in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { v in
                        CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                k.baseAddress, key.count, v.baseAddress, d.baseAddress, data.count, o.baseAddress, o.count, &length)
                    }
                }
            }
        }
        return status == kCCSuccess ? out.prefix(length) : nil
    }

    static func value(of row: Row, key: Data) -> String? {
        guard row.value.isEmpty else { return row.value }
        guard row.encryptedValue.starts(with: Data("v10".utf8)),
              var plain = aes(row.encryptedValue.dropFirst(3), key: key, encrypt: false) else { return nil }
        if row.hostHashed {
            // Also tells a wrong key apart from one whose garbage happened to pass the padding check.
            guard plain.prefix(32) == Data(SHA256.hash(data: Data(row.host.utf8))) else { return nil }
            plain = plain.dropFirst(32)
        }
        return String(data: plain, encoding: .utf8)
    }

    static func cookie(_ row: Row, key: Data) -> BrowserCookie? {
        guard let value = value(of: row, key: key) else { return nil }
        let sameSite: BrowserCookie.SameSite? = switch row.sameSite {
        case 0: .noRestriction
        case 1: .lax
        case 2: .strict
        default: nil
        }
        return BrowserCookie(name: row.name, value: value, domain: row.host, path: row.path.isEmpty ? "/" : row.path,
                             isSecure: row.isSecure, isHTTPOnly: row.isHTTPOnly, expires: row.expires, sameSite: sameSite)
    }
}
