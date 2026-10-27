import Foundation
import CryptoKit
import LocalAuthentication
import Security

// MARK: - Secret variables
//
// Threat model: somebody gets the storage folder (backup, cloud sync, a copied project, a shared Mac account directory)
// and reads collections / globals.json / history. A hidden variable must be useless to them:
//   • the value in globals.json is AES-256-GCM ciphertext (`"type": "secret"` is Postman's own variable type, so the file stays valid);
//   • the key is a random 256-bit master key that lives only in the Keychain, never in a file; when iCloud Keychain is on it is synced end-to-end encrypted to your other Apple devices;
//   • using the key needs Touch ID / Apple Watch / the login password (LocalAuthentication): once per launch for running,
//     and every time for revealing a value;
//   • secret values are masked in the Log and in the history, and are handed to node through a pipe, never through a file.
// No home-made cipher: the "proprietary" part is the envelope format below, built from Apple's CryptoKit primitives.

/// `pwenc:1:<key id>:<base64( salt16 | nonce12 | ciphertext | tag16 )>`
///  • per-value random salt → HKDF-SHA256 → a one-time AES key (the master key never encrypts data directly);
///  • plaintext is length-prefixed and padded to 64-byte blocks, so the length of a password is not visible;
///  • the prefix is authenticated data (AAD): the format cannot be silently downgraded;
///  • the key id (first 4 bytes of a hash of the key) tells "wrong Mac / reset Keychain" apart from "corrupted file".
enum SecretBox {
    static let prefix = "pwenc:1:"
    private static let info = Data("postwoman.secret.v1".utf8)

    enum Failure: LocalizedError {
        case notSealed, corrupt, wrongKey, tooLong
        var errorDescription: String? {
            switch self {
            case .wrongKey: return L("A secret was encrypted with another key (another Mac or a reset Keychain) and cannot be read. Enter it again.")
            case .tooLong: return L("Secret storage is unavailable: %@", "value is longer than 64 KB")
            default: return L("Secret storage is unavailable: %@", "stored value is damaged")
            }
        }
    }

    static func isSealed(_ s: String) -> Bool { s.hasPrefix(prefix) }

    static func keyID(_ key: SymmetricKey) -> String {
        var h = SHA256()
        h.update(data: Data("postwoman.kid.v1".utf8))
        key.withUnsafeBytes { h.update(bufferPointer: $0) }
        return h.finalize().prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    static func seal(_ plain: String, with key: SymmetricKey) throws -> String {
        let bytes = Array(plain.utf8)
        guard bytes.count <= 0xFFFF else { throw Failure.tooLong }
        var padded = Data([UInt8(bytes.count >> 8), UInt8(bytes.count & 0xFF)]) + Data(bytes)
        padded.append(Data(count: (64 - padded.count % 64) % 64))
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })           // system CSPRNG
        let sub = HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: salt, info: info, outputByteCount: 32)
        let box = try AES.GCM.seal(padded, using: sub, authenticating: Data(prefix.utf8))
        guard let combined = box.combined else { throw Failure.corrupt }
        return prefix + keyID(key) + ":" + (salt + combined).base64EncodedString()
    }

    static func open(_ s: String, with key: SymmetricKey) throws -> String {
        guard s.hasPrefix(prefix) else { throw Failure.notSealed }
        let rest = s.dropFirst(prefix.count)
        guard let colon = rest.firstIndex(of: ":") else { throw Failure.corrupt }
        guard String(rest[..<colon]) == keyID(key) else { throw Failure.wrongKey }
        guard let blob = Data(base64Encoded: String(rest[rest.index(after: colon)...])), blob.count >= 16 + 12 + 16 else { throw Failure.corrupt }
        let salt = Data(blob.prefix(16))
        let sub = HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: salt, info: info, outputByteCount: 32)
        let padded: Data
        do {
            let box = try AES.GCM.SealedBox(combined: Data(blob.dropFirst(16)))
            padded = try AES.GCM.open(box, using: sub, authenticating: Data(prefix.utf8))
        } catch { throw Failure.corrupt }
        let b = [UInt8](padded)
        guard b.count >= 2 else { throw Failure.corrupt }
        let n = Int(b[0]) << 8 | Int(b[1])
        guard 2 + n <= b.count else { throw Failure.corrupt }
        return String(decoding: b[2..<(2 + n)], as: UTF8.self)
    }
}

// MARK: - Masking secrets in everything that is shown or stored after a run
struct Redactor {
    private var pairs: [(String, String)] = []
    init(secrets: [String: String]) {
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        var p: [(String, String)] = []
        for (name, v) in secrets where v.count >= 3 {
            let label = "‹secret: \(name)›"
            p.append((v, label))
            for enc in [v.addingPercentEncoding(withAllowedCharacters: unreserved),            // form / query encoding
                        v.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
                        v.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")]   // inside a JSON string
            where enc != nil && enc != v { p.append((enc!, label)) }
        }
        pairs = p.sorted { $0.0.count > $1.0.count }
    }
    var isEmpty: Bool { pairs.isEmpty }
    func mask(_ s: String) -> String {
        guard !pairs.isEmpty else { return s }
        var r = s
        for (v, l) in pairs where r.contains(v) { r = r.replacingOccurrences(of: v, with: l) }
        return r
    }
}

// MARK: - The key and the authentication
@MainActor
final class SecretVault: ObservableObject {
    static let shared = SecretVault()

    /// Where the master key lives (known after the first use in this launch).
    enum Tier { case unknown, synced, biometric, login }
    @Published private(set) var unlocked = false
    @Published private(set) var tier: Tier = .unknown
    var log: ((String, LogLevel) -> Void)?

    private var key: SymmetricKey?
    private let service = "com.postwoman.app.vault", account = "master-key-v1"

    enum Failure: LocalizedError {
        case cancelled, auth(String), keychain(String)
        var errorDescription: String? {
            switch self {
            case .cancelled: return L("Authentication cancelled.")
            case .auth(let m): return L("Authentication failed: %@", m)
            case .keychain(let m): return L("Secret storage is unavailable: %@", m)
            }
        }
    }

    /// The master key. The first use after launch asks for Touch ID / Apple Watch / the login password;
    /// `fresh: true` (revealing a value) asks again every time and re-reads the key from the Keychain.
    func unlock(reason: String, fresh: Bool = false) async throws -> SymmetricKey {
        if !fresh, let k = key { return k }
        let ctx = try await authenticate(reason: reason)
        let k = try loadOrCreateKey(ctx: ctx)
        key = k; unlocked = true
        return k
    }

    /// Forget the key now: the next use asks for authentication again.
    func lock() {
        key = nil; unlocked = false
        log?("Vault locked: the next use of a secret asks for authentication", .info)
    }

    // MARK: LocalAuthentication
    private func authenticate(reason: String) async throws -> LAContext {
        let ctx = LAContext()
        ctx.localizedCancelTitle = L("Cancel")
        var nsErr: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &nsErr) else {
            throw Failure.auth(nsErr?.localizedDescription ?? "not available")
        }
        log?("Authentication requested: \(reason)", .debug)
        do {
            guard try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) else { throw Failure.cancelled }
            log?("Authentication succeeded", .debug)
            return ctx
        } catch let e as LAError {
            switch e.code {
            case .userCancel, .systemCancel, .appCancel: throw Failure.cancelled
            default: throw Failure.auth(e.localizedDescription)
            }
        }
    }

    // MARK: Keychain
    // Preferred: an iCloud-Keychain item (kSecAttrSynchronizable) in the data-protection keychain, so every Mac signed in to the same
    // Apple ID gets the same master key and can read the same secrets. A synchronizable item cannot carry a biometric access control,
    // so Touch ID / password is enforced by the app (LocalAuthentication) before the key is ever read.
    // Fallbacks: a device-only item with a user-presence access control, then the login keychain (builds without a developer team:
    // errSecMissingEntitlement -34018). Existing local keys are copied to iCloud Keychain on first use, the key itself does not change.
    private let missingEntitlement: OSStatus = -34018

    private enum Kind { case synced, local, login }
    private func query(_ kind: Kind) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: account]
        switch kind {
        case .synced: q[kSecUseDataProtectionKeychain as String] = true; q[kSecAttrSynchronizable as String] = true
        case .local:  q[kSecUseDataProtectionKeychain as String] = true; q[kSecAttrSynchronizable as String] = false
        case .login:  break
        }
        return q
    }
    private func read(_ kind: Kind, ctx: LAContext) -> (Data?, OSStatus) {
        var q = query(kind)
        q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        if kind == .local { q[kSecUseAuthenticationContext as String] = ctx }
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        return (st == errSecSuccess ? out as? Data : nil, st)
    }
    private func describe(_ st: OSStatus) -> String {
        if let m = SecCopyErrorMessageString(st, nil) { return "\(m as String) (\(st))" }
        return "OSStatus \(st)"
    }
    /// Stores the key in iCloud Keychain; false when this build cannot (no team / no entitlement / iCloud Keychain off).
    private func addSynced(_ raw: Data) -> Bool {
        var add = query(.synced)
        add[kSecValueData as String] = raw
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let st = SecItemAdd(add as CFDictionary, nil)
        if st != errSecSuccess && st != errSecDuplicateItem { log?("iCloud Keychain not available for the master key: \(describe(st))", .debug) }
        return st == errSecSuccess || st == errSecDuplicateItem
    }

    private func loadOrCreateKey(ctx: LAContext) throws -> SymmetricKey {
        let (d0, s0) = read(.synced, ctx: ctx)
        if let d = d0 { tier = .synced; return SymmetricKey(data: d) }
        guard s0 == errSecItemNotFound || s0 == missingEntitlement else { throw Failure.keychain(describe(s0)) }

        let (d1, s1) = read(.local, ctx: ctx)
        if let d = d1 {
            if addSynced(d) { tier = .synced; log?("Master key copied to iCloud Keychain (synced to your other devices)", .info) } else { tier = .biometric }
            return SymmetricKey(data: d)
        }
        guard s1 == errSecItemNotFound || s1 == missingEntitlement else { throw Failure.keychain(describe(s1)) }

        let (d2, s2) = read(.login, ctx: ctx)
        if let d = d2 {
            if addSynced(d) { tier = .synced; log?("Master key copied to iCloud Keychain (synced to your other devices)", .info) } else { tier = .login }
            return SymmetricKey(data: d)
        }
        guard s2 == errSecItemNotFound else { throw Failure.keychain(describe(s2)) }

        // first use: create the master key
        let fresh = SymmetricKey(size: .bits256)
        let raw = fresh.withUnsafeBytes { Data($0) }
        if addSynced(raw) { tier = .synced; log?("Master key created in iCloud Keychain (synced; Touch ID / password is asked by the app)", .info); return fresh }

        var add = query(.local)
        add[kSecValueData as String] = raw
        add[kSecUseAuthenticationContext as String] = ctx
        var cfErr: Unmanaged<CFError>?
        if let ac = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, &cfErr) {
            add[kSecAttrAccessControl as String] = ac
            let st = SecItemAdd(add as CFDictionary, nil)
            if st == errSecSuccess { tier = .biometric; log?("Master key created in the Keychain (this device only: Touch ID / password access control)", .info); return fresh }
            guard st == missingEntitlement else { throw Failure.keychain(describe(st)) }
        }
        var legacy = query(.login)
        legacy[kSecValueData as String] = raw
        let st = SecItemAdd(legacy as CFDictionary, nil)
        guard st == errSecSuccess else { throw Failure.keychain(describe(st)) }
        tier = .login
        log?("Master key created in the login keychain (this build has no keychain entitlement, so it is not synced and the Keychain itself does not enforce Touch ID; the app does)", .warn)
        return fresh
    }
}
