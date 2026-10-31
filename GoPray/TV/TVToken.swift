// TVToken.swift — the one place the app touches the Keychain (Samsung TV Plan §5/§7). Guard 4d pins it here.
//
// What is stored: the remote-control token a Samsung TV hands out when the person presses Allow, and the SHA-256
// of the TV's certificate (leaf, DER) seen at that moment. One generic-password item per TV, account = `TVDevice.id`.
// This device only (no iCloud sync, not in backups, never in settings.json), readable while the Mac is unlocked,
// deleted when the TV is removed. Nothing in this file logs a value.

import CryptoKit
import Foundation
import Security

struct StoredTVToken: Equatable, Sendable {
    var token: String
    /// Lowercase hex SHA-256 of the leaf certificate, no prefix.
    var fingerprint: String
}

protocol TokenStore: Sendable {
    func load(_ tvID: String) -> StoredTVToken?
    @discardableResult func save(_ tvID: String, token: String, fingerprint: String) -> Bool
    func delete(_ tvID: String)
}

enum TVTokenRules {
    /// What a token and a fingerprint may look like. Anything else is refused on the way in and on the way out.
    static func isValidToken(_ s: String) -> Bool { s.range(of: "^[A-Za-z0-9]{1,64}\\z", options: .regularExpression) != nil }
    static func isValidFingerprint(_ s: String) -> Bool { s.range(of: "^[0-9a-f]{64}\\z", options: .regularExpression) != nil }

    /// `token\nsha256:<hex>`
    static func encode(_ t: StoredTVToken) -> Data? {
        guard isValidToken(t.token), isValidFingerprint(t.fingerprint) else { return nil }
        return Data("\(t.token)\nsha256:\(t.fingerprint)".utf8)
    }

    static func decode(_ data: Data) -> StoredTVToken? {
        guard data.count <= 256, let text = String(data: data, encoding: .utf8) else { return nil }
        let parts = text.components(separatedBy: "\n")
        guard parts.count == 2, parts[1].hasPrefix("sha256:") else { return nil }
        let t = StoredTVToken(token: parts[0], fingerprint: String(parts[1].dropFirst("sha256:".count)))
        return isValidToken(t.token) && isValidFingerprint(t.fingerprint) ? t : nil
    }
}

struct KeychainTokenStore: TokenStore {
    static let service = "com.ahmedelgazar.gopray.tv"

    private func query(_ tvID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: tvID,
         kSecAttrSynchronizable as String: false]
    }

    func load(_ tvID: String) -> StoredTVToken? {
        var q = query(tvID)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return TVTokenRules.decode(data)
    }

    @discardableResult
    func save(_ tvID: String, token: String, fingerprint: String) -> Bool {
        guard let data = TVTokenRules.encode(StoredTVToken(token: token, fingerprint: fingerprint)) else { return false }
        delete(tvID)
        var q = query(tvID)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    func delete(_ tvID: String) {
        SecItemDelete(query(tvID) as CFDictionary)
    }
}

// MARK: - The Android TV Remote client identity (Google TV Plan §4/§7)

/// The Mac's one client identity for the Android TV Remote protocol: an RSA key and its self-signed certificate. The TV
/// trusts the certificate after pairing. `identity` is the Keychain's pairing of the two (nil in the in-memory test store).
struct StoredIdentity: @unchecked Sendable {
    var key: SecKey
    var certificate: SecCertificate
    var identity: SecIdentity?
}

protocol IdentityStore: Sendable {
    func load() -> StoredIdentity?
    /// Makes the one identity (key and certificate) and keeps it; replaces anything this store held before.
    func makeIdentity() -> StoredIdentity?
    func delete()
}

enum IdentityStoreRules {
    /// What `SecKeyCreateRandomKey` is asked for in memory: RSA 2048, not stored by the call itself.
    static var keyAttributes: CFDictionary {
        [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
         kSecAttrKeySizeInBits as String: 2048] as CFDictionary
    }
}

/// The identity lives in a keychain FILE this app owns, never in the person's own keychains. A first version kept it in
/// the login keychain and deleted the person's own code-signing identities (the label filter is ignored for the identity
/// class). So here nothing can name another keychain: the file is never added to the search list, every query goes through
/// the one `scoped(` helper (`kSecMatchSearchList: [file]`), the key is born permanent in the file (`kSecUseKeychain`),
/// and there is no item-level delete at all: `delete()` removes the whole file, which holds only our key and certificate.
/// The file's password is 32 random bytes kept as one generic-password item through `TokenStore` (the only login entry).
/// Lost password: `delete()` and pair again. Never exported, never logged.
struct KeychainIdentityStore: IdentityStore {
    static let tag = Data("com.ahmedelgazar.gopray.tv.remote".utf8)
    static let keyLabel = "Go Pray TV Remote"
    /// The subject summary of the certificate `RemoteIdentity` makes.
    static let subject = "Go Pray"
    /// `TokenStore` account of the file's password.
    static let passwordAccount = "gopray-tv-remote-keychain-password"

    var fileURL: URL
    var passwordStore: TokenStore

    init(fileURL: URL = Self.defaultFileURL, passwordStore: TokenStore = KeychainTokenStore()) {
        self.fileURL = fileURL
        self.passwordStore = passwordStore
    }

    static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GoPray", isDirectory: true).appendingPathComponent("tv-remote.keychain-db")
    }

    // MARK: the file

    private func storedPassword() -> String? { passwordStore.load(Self.passwordAccount)?.token }

    /// Opens (or, with `create`, creates) our file and unlocks it. Nothing here touches any search list.
    private func open(create: Bool) -> SecKeychain? {
        let path = fileURL.path
        var kc: SecKeychain?
        if FileManager.default.fileExists(atPath: path) {
            guard let pw = storedPassword(), SecKeychainOpen(path, &kc) == errSecSuccess, let kc else { return nil }
            let bytes = Array(pw.utf8)
            return SecKeychainUnlock(kc, UInt32(bytes.count), bytes, true) == errSecSuccess ? kc : nil
        }
        guard create else { return nil }
        var raw = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, raw.count, &raw) == errSecSuccess else { return nil }
        let pw = raw.map { String(format: "%02x", $0) }.joined()
        let digest = Data(SHA256.hash(data: Data(pw.utf8))).map { String(format: "%02x", $0) }.joined()
        guard (try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)) != nil,
              passwordStore.save(Self.passwordAccount, token: pw, fingerprint: digest) else { return nil }
        let bytes = Array(pw.utf8)
        guard SecKeychainCreate(path, UInt32(bytes.count), bytes, false, nil, &kc) == errSecSuccess, let kc else {
            passwordStore.delete(Self.passwordAccount)
            return nil
        }
        return kc
    }

    /// The one place a query gets its search list: our file, and only our file.
    private func scoped(_ q: [String: Any], _ kc: SecKeychain) -> [String: Any] {
        var out = q
        out[kSecMatchSearchList as String] = [kc] as CFArray
        return out
    }

    private func find(_ q: [String: Any], _ kc: SecKeychain) -> CFTypeRef? {
        var out: CFTypeRef?
        return SecItemCopyMatching(scoped(q, kc) as CFDictionary, &out) == errSecSuccess ? out : nil
    }

    // MARK: IdentityStore

    func load() -> StoredIdentity? {
        guard let kc = open(create: false),
              let found = find([kSecClass as String: kSecClassCertificate, kSecReturnRef as String: true,
                                kSecMatchLimit as String: kSecMatchLimitAll], kc) as? [SecCertificate],
              found.count == 1, (SecCertificateCopySubjectSummary(found[0]) as String?) == Self.subject else { return nil }
        var identity: SecIdentity?
        guard SecIdentityCreateWithCertificate([kc] as CFArray, found[0], &identity) == errSecSuccess, let identity else { return nil }
        var key: SecKey?
        guard SecIdentityCopyPrivateKey(identity, &key) == errSecSuccess, let key else { return nil }
        return StoredIdentity(key: key, certificate: found[0], identity: identity)
    }

    func makeIdentity() -> StoredIdentity? {
        delete()
        guard let kc = open(create: true) else { return nil }
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecUseKeychain as String: kc,
            kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: true, kSecAttrApplicationTag as String: Self.tag,
                                            kSecAttrLabel as String: Self.keyLabel],
            kSecPublicKeyAttrs as String: [kSecAttrIsPermanent as String: false]]
        guard let made = RemoteIdentity.generate(keyAttributes: attrs as CFDictionary) else { delete(); return nil }
        guard SecItemAdd([kSecClass as String: kSecClassCertificate, kSecValueRef as String: made.certificate, kSecUseKeychain as String: kc] as CFDictionary, nil) == errSecSuccess,
              let stored = load() else { delete(); return nil }
        return stored
    }

    /// Removes the whole file and its password. Nothing else can be in the file; no item is ever deleted on its own.
    func delete() {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            var kc: SecKeychain?
            if SecKeychainOpen(fileURL.path, &kc) == errSecSuccess, let kc { SecKeychainDelete(kc) }
        }
        passwordStore.delete(Self.passwordAccount)
    }
}
