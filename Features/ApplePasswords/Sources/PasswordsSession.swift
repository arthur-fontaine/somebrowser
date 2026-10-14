import CryptoKit
import Foundation
import Security

/// The encrypted session with Apple's `PasswordManagerBrowserExtensionHelper`: SRP-6a over the RFC 5054
/// 3072-bit group (SHA-256, g = 5), keyed by the 6-digit code the helper shows, then AES-128-GCM messages.
///
/// Byte-level choices follow Apple's own extension (sjcl), as reverse-engineered by
/// au2001/icloud-passwords-firefox (Apache-2.0) and rderaison/bromure (MIT): A, B and S hash in their
/// minimal form, the salt as received, the session key as the full 32-byte hash; 16-byte GCM IVs, sent as
/// `ciphertext‖tag‖iv` and received as `iv‖ciphertext‖tag`.
final class PasswordsSession {
    static let N = BigUInt(hex: """
        FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B
        302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE6
        49286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB9ED529077096966D
        670C354E4ABC9804F1746C08CA18217C32905E462E36CE3BE39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF695581718
        3995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D04507A33A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7D
        B3970F85A6E1E4C7ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864D87602733EC86A64521F2B18177B200C
        BBE117577A615D6C770988C0BAD946E208E24FA074E5AB3143DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF
        """)!
    static let g = BigUInt(5)
    static let length = 384

    enum SessionError: Error, Equatable {
        case badServerHello, wrongCode, badServerProof, notPaired, badMessage
    }

    let identity: Data
    let a: BigUInt
    let A: BigUInt
    /// The helper's `capabilities.shouldUseBase64`: binary values as base64 instead of hex.
    let useBase64: Bool
    private(set) var key: SymmetricKey?
    private var expectedProof: Data?

    init(useBase64: Bool, identity: Data = PasswordsSession.random(16), a: BigUInt = BigUInt(bytes: PasswordsSession.random(32))) {
        self.useBase64 = useBase64
        self.identity = identity
        self.a = a
        A = Self.g.power(a, modulus: Self.N)
    }

    var isPaired: Bool { key != nil }

    /// The session id: the identity as the helper expects it on the wire.
    var tid: String { useBase64 ? identity.base64EncodedString() : "0x" + identity.hex }

    func encode(_ data: Data, prefixed: Bool = true) -> String {
        useBase64 ? data.base64EncodedString() : (prefixed ? "0x" : "") + data.hex
    }

    func decode(_ string: String) -> Data {
        useBase64 ? (Data(base64Encoded: string) ?? Data()) : Data(hex: string)
    }

    // MARK: Handshake

    /// PAKE message 0 (base64 JSON). Key order matches Apple's extension.
    func clientHello() -> String {
        Data("{\"TID\":\"\(tid)\",\"MSG\":0,\"A\":\"\(encode(A.bytes))\",\"VER\":\"1.0\",\"PROTO\":[0,1]}".utf8).base64EncodedString()
    }

    /// From the helper's message 1 (`s`, `B`) and the code it displays: derives the key, returns message 2.
    func clientProof(serverHello pake: [String: Any], code: String) throws -> String {
        guard pake["TID"] as? String == tid, "\(pake["MSG"] ?? "")" == "1",
              let s = pake["s"] as? String, let b = pake["B"] as? String else { throw SessionError.badServerHello }
        let salt = decode(s)
        let B = BigUInt(bytes: decode(b))
        guard !(B % Self.N).isZero else { throw SessionError.badServerHello }

        let x = BigUInt(bytes: Self.H(salt, Self.H(Data("\(tid):\(code)".utf8))))
        let v = Self.g.power(x, modulus: Self.N)
        let k = BigUInt(bytes: Self.H(Self.N.bytes(paddedTo: Self.length), Self.g.bytes(paddedTo: Self.length)))
        let u = BigUInt(bytes: Self.H(A.bytes(paddedTo: Self.length), B.bytes(paddedTo: Self.length)))
        let kv = (k * v) % Self.N
        let base = B >= kv ? B - kv : B + Self.N - kv
        let S = base.power(a + u * x, modulus: Self.N)
        let sessionKey = Self.H(S.bytes)

        let hN = Self.H(Self.N.bytes), hg = Self.H(Self.g.bytes(paddedTo: Self.length))
        let xorNg = Data(zip(hN, hg).map { $0 ^ $1 })
        let M = Self.H(xorNg, Self.H(Data(tid.utf8)), salt, A.bytes, B.bytes, sessionKey)
        expectedProof = Self.H(A.bytes, M, sessionKey)
        pendingKey = SymmetricKey(data: sessionKey.prefix(16))
        return Data("{\"TID\":\"\(tid)\",\"MSG\":2,\"M\":\"\(encode(M, prefixed: false))\"}".utf8).base64EncodedString()
    }
    private var pendingKey: SymmetricKey?

    /// The helper's message 3: `ErrCode` 1 is a wrong code; `HAMK` proves the helper derived the same key.
    func verifyServerProof(_ pake: [String: Any]) throws {
        if let err = pake["ErrCode"] as? Int, err != 0 { throw err == 1 ? SessionError.wrongCode : SessionError.badServerProof }
        guard let hamk = pake["HAMK"] as? String, decode(hamk) == expectedProof, let pendingKey else { throw SessionError.badServerProof }
        key = pendingKey
    }

    // MARK: Messages

    /// An `SMSG` envelope (JSON string) carrying `body` encrypted.
    func seal(_ body: [String: Any]) throws -> String {
        guard let key else { throw SessionError.notPaired }
        let plaintext = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        let iv = Self.random(16)
        let box = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(data: iv))
        let envelope = ["TID": tid, "SDATA": encode(box.ciphertext + box.tag + iv, prefixed: false)]
        return String(decoding: try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }

    /// Decrypts an `SMSG` (a JSON string or an already-parsed object).
    func open(_ smsg: Any) throws -> [String: Any] {
        guard let key else { throw SessionError.notPaired }
        let envelope: [String: Any]?
        if let s = smsg as? String { envelope = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] }
        else { envelope = smsg as? [String: Any] }
        guard let envelope, envelope["TID"] as? String == tid, let sdata = envelope["SDATA"] as? String else { throw SessionError.badMessage }
        let data = decode(sdata)
        guard data.count > 32 else { throw SessionError.badMessage }
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: data.prefix(16)), ciphertext: data.dropFirst(16).dropLast(16), tag: data.suffix(16))
        let plaintext = try AES.GCM.open(box, using: key)
        guard let body = (try? JSONSerialization.jsonObject(with: plaintext)) as? [String: Any] else { throw SessionError.badMessage }
        return body
    }

    // MARK: Helpers

    static func H(_ parts: Data...) -> Data {
        var hasher = SHA256()
        for part in parts { hasher.update(data: part) }
        return Data(hasher.finalize())
    }

    static func random(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }

    init(hex: String) {
        var chars = Array(hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex)
        if chars.count % 2 == 1 { chars.insert("0", at: 0) }
        self.init(stride(from: 0, to: chars.count, by: 2).compactMap { UInt8(String(chars[$0...$0 + 1]), radix: 16) })
    }
}
