import BrowserCore
import BrowserTesting
import CryptoKit
import Foundation
import Testing
@testable import FeaturePasswords

struct BigUIntTests {
    @Test func arithmeticMatchesReference() {
        let p = BigUInt(hex: Vectors.P)!, q = BigUInt(hex: Vectors.Q)!
        #expect(p * q == BigUInt(hex: Vectors.PQ)!)
        #expect(p.quotientAndRemainder(dividingBy: q).quotient == BigUInt(hex: Vectors.PdivQ)!)
        #expect(p % q == BigUInt(hex: Vectors.PmodQ)!)
        #expect(p.power(q, modulus: PasswordsSession.N) == BigUInt(hex: Vectors.POW)!)
        #expect((p * q - p) + p == p * q)
        #expect(BigUInt(hex: "00ff")!.bytes == Data([0xff]))
    }
}

/// Fixed inputs shared with the Python reference (`Vectors`).
enum Fixed {
    static let identity = Data(1...16)
    static let a = BigUInt(bytes: Array(32..<64))
    static let b = BigUInt(bytes: Array(100..<132))
    static let salt = Data(hex: "00a1b2c3d4e5f60718293a4b5c6d7e8f")
    static let code = "123456"
}

/// The helper's side of the protocol, for tests.
final class FakeHelper: PasswordsTransport {
    var onMessage: (([String: Any]) -> Void)?
    var onClose: ((Bool) -> Void)?
    var logins: [String: [(user: String, password: String)]] = [:]
    var saved: [(url: String, user: String, password: String)] = []
    var key: SymmetricKey?
    var tid = ""
    private var A = BigUInt(), B = BigUInt(), v = BigUInt()

    func send(_ message: [String: Any]) throws {
        let reply = handle(message)
        DispatchQueue.main.async { self.onMessage?(reply) }
    }
    func close() {}

    func handle(_ m: [String: Any]) -> [String: Any] {
        let cmd = m["cmd"] as! Int
        switch cmd {
        case 14: return ["cmd": 14, "capabilities": ["shouldUseBase64": false, "secretSessionVersion": 1]]
        case 2:
            let msg = PasswordsClient.object(m["msg"] as! String)!
            let pake = PasswordsClient.object(String(decoding: Data(base64Encoded: msg["PAKE"] as! String)!, as: UTF8.self))!
            tid = pake["TID"] as! String
            let N = PasswordsSession.N, g = PasswordsSession.g, L = PasswordsSession.length
            if msg["QID"] as? String == "m0" {
                A = BigUInt(bytes: Data(hex: pake["A"] as! String))
                let x = BigUInt(bytes: PasswordsSession.H(Fixed.salt, PasswordsSession.H(Data("\(tid):\(Fixed.code)".utf8))))
                v = g.power(x, modulus: N)
                let k = BigUInt(bytes: PasswordsSession.H(N.bytes(paddedTo: L), g.bytes(paddedTo: L)))
                B = (k * v + g.power(Fixed.b, modulus: N)) % N
                return pakeReply(["TID": tid, "MSG": 1, "s": "0x" + Fixed.salt.hex, "B": "0x" + B.bytes.hex, "PROTO": 1])
            }
            let u = BigUInt(bytes: PasswordsSession.H(A.bytes(paddedTo: L), B.bytes(paddedTo: L)))
            let S = ((A * v.power(u, modulus: N)) % N).power(Fixed.b, modulus: N)
            let K = PasswordsSession.H(S.bytes)
            let hN = PasswordsSession.H(N.bytes), hg = PasswordsSession.H(g.bytes(paddedTo: L))
            let M = PasswordsSession.H(Data(zip(hN, hg).map { $0 ^ $1 }), PasswordsSession.H(Data(tid.utf8)), Fixed.salt, A.bytes, B.bytes, K)
            guard Data(hex: pake["M"] as! String) == M else { return pakeReply(["TID": tid, "MSG": 3, "ErrCode": 1]) }
            key = SymmetricKey(data: K.prefix(16))
            return pakeReply(["TID": tid, "MSG": 3, "ErrCode": 0, "HAMK": PasswordsSession.H(A.bytes, M, K).hex])
        default:
            let payload = PasswordsClient.object(m["payload"] as! String)!
            let body = open(payload["SMSG"] as! String)
            switch cmd {
            case 4: return ["cmd": 4, "payload": ["SMSG": seal(["STATUS": 0, "Entries": (logins[body["URL"] as! String] ?? []).map { ["USR": $0.user, "sites": [body["URL"]!]] }])]]
            case 5:
                let match = (logins[body["URL"] as! String] ?? []).first { $0.user == body["USR"] as? String }
                return ["cmd": 5, "payload": ["SMSG": seal(["STATUS": 0, "Entries": [["USR": match?.user ?? "", "PWD": match?.password ?? "Not Included"]]])]]
            default:
                saved.append((body["NURL"] as! String, body["NUSR"] as! String, body["NPWD"] as! String))
                return ["cmd": 6, "payload": [:]]
            }
        }
    }

    func pakeReply(_ pake: [String: Any]) -> [String: Any] {
        ["cmd": 2, "payload": ["PAKE": Data(PasswordsClient.json(pake).utf8).base64EncodedString()]]
    }
    func seal(_ body: [String: Any]) -> [String: Any] {
        let iv = PasswordsSession.random(16)
        let box = try! AES.GCM.seal(try! JSONSerialization.data(withJSONObject: body), using: key!, nonce: AES.GCM.Nonce(data: iv))
        return ["TID": tid, "SDATA": (iv + box.ciphertext + box.tag).hex]
    }
    func open(_ smsg: String) -> [String: Any] {
        let data = Data(hex: PasswordsClient.object(smsg)!["SDATA"] as! String)  // ciphertext‖tag‖iv
        let box = try! AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: data.suffix(16)), ciphertext: data.dropLast(32), tag: data.dropLast(16).suffix(16))
        return try! JSONSerialization.jsonObject(with: AES.GCM.open(box, using: key!)) as! [String: Any]
    }
}

struct SessionTests {
    @Test func handshakeMatchesReference() throws {
        let session = PasswordsSession(useBase64: false, identity: Fixed.identity, a: Fixed.a)
        #expect(session.A.bytes.hex == Vectors.A)
        let hello = PasswordsClient.object(String(decoding: Data(base64Encoded: session.clientHello())!, as: UTF8.self))!
        #expect(hello["PROTO"] as? [Int] == [0, 1])
        let proof = try session.clientProof(serverHello: ["TID": session.tid, "MSG": 1, "s": "0x" + Fixed.salt.hex, "B": "0x" + Vectors.B], code: Fixed.code)
        let m = PasswordsClient.object(String(decoding: Data(base64Encoded: proof)!, as: UTF8.self))!
        #expect(m["M"] as? String == Vectors.M)
        #expect(throws: PasswordsSession.SessionError.badServerProof) { try session.verifyServerProof(["ErrCode": 0, "HAMK": String(repeating: "0", count: 64)]) }
        try session.verifyServerProof(["ErrCode": 0, "HAMK": Vectors.HAMK])
        #expect(session.isPaired)
        #expect(session.key.map { $0.withUnsafeBytes { Data($0) } } == Data(hex: Vectors.K).prefix(16))
    }
}

@MainActor
struct ClientTests {
    func pairedClient(_ helper: FakeHelper) async throws -> PasswordsClient {
        let client = PasswordsClient(makeTransport: { helper })
        await client.connect()
        #expect(client.state == .needsCode)
        try await client.pair(code: Fixed.code)
        #expect(client.state == .ready)
        return client
    }

    @Test func pairsAutofillsAndSaves() async throws {
        let helper = FakeHelper()
        helper.logins["example.com"] = [("ada", "s3cret")]
        let client = try await pairedClient(helper)
        let logins = try await client.loginNames(for: "example.com")
        #expect(logins.map(\.username) == ["ada"])
        #expect(try await client.password(for: logins[0], host: "example.com") == "s3cret")
        try await client.save(url: "https://example.com", username: "bob", password: "x-y-z")
        #expect(helper.saved.first?.user == "bob")
    }

    @Test func wrongCodeRestartsPairing() async throws {
        let client = PasswordsClient(makeTransport: { FakeHelper() })
        await client.connect()
        await #expect(throws: PasswordsSession.SessionError.wrongCode) { try await client.pair(code: "000000") }
        #expect(client.state == .needsCode)
    }

    @Test func refusedLaunchIsUnavailable() async {
        final class Refusing: PasswordsTransport {
            var onMessage: (([String: Any]) -> Void)?
            var onClose: ((Bool) -> Void)?
            func send(_ message: [String: Any]) throws { DispatchQueue.main.async { self.onClose?(true) } }
            func close() {}
        }
        let client = PasswordsClient(makeTransport: { Refusing() })
        await client.connect()
        guard case .unavailable(let reason) = client.state else { Issue.record("expected unavailable"); return }
        #expect(reason.contains("entitlement"))
    }
}

@MainActor
func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(50)) }
    #expect(condition())
}

@MainActor
struct FeatureTests {
    let rect: [String: Any] = ["x": 10, "y": 20, "width": 200, "height": 30]

    func setUp(_ helper: FakeHelper) async throws -> (TestHarness, ApplePasswordsFeature) {
        let client = PasswordsClient(makeTransport: { helper })
        await client.connect()
        try await client.pair(code: Fixed.code)
        let h = try TestHarness(features: [ApplePasswordsFeature.self], manifestDirectory: #filePath, activate: false)
        let feature = ApplePasswordsFeature(context: h.context, client: client)
        feature.activate()
        return (h, feature)
    }

    @Test func focusShowsLoginsAndChoosingFills() async throws {
        let helper = FakeHelper()
        helper.logins["example.com"] = [("ada", "s3cret")]
        let (h, feature) = try await setUp(helper)
        let tab = h.fakeTab(h.openTab("https://example.com/login"))
        tab.simulateScriptMessage("passwords.focus", body: ["kind": "login", "rect": rect])
        try await waitUntil { !feature.model.logins.isEmpty }
        #expect(feature.model.rows == [.login(PasswordsLogin(username: "ada", sites: ["example.com"])), .openApp])
        #expect(feature.model.field?.rect == CGRect(x: 10, y: 20, width: 200, height: 30))
        tab.simulateScriptMessage("passwords.key", body: ["key": "Enter"])
        try await waitUntil { tab.evaluatedScripts.contains { $0.contains("s3cret") && $0.contains("ada") } }
    }

    /// A page can post anything: the site must come from the tab, or evil.example could read bank.example's logins.
    @Test func pagesCannotClaimAnotherSite() async throws {
        let helper = FakeHelper()
        helper.logins["evil.example"] = [("mallory", "x")]
        helper.logins["bank.example"] = [("ada", "s3cret")]
        let (h, feature) = try await setUp(helper)
        let tab = h.fakeTab(h.openTab("https://evil.example/"))
        tab.simulateScriptMessage("passwords.focus", body: ["kind": "login", "rect": rect, "host": "bank.example", "url": "https://bank.example"])
        try await waitUntil { !feature.model.logins.isEmpty }
        #expect(feature.model.field?.host == "evil.example")
        #expect(feature.model.logins.map(\.username) == ["mallory"])
        tab.simulateScriptMessage("passwords.submit", body: ["username": "ada", "password": "attacker", "url": "https://bank.example"])
        try await waitUntil { !helper.saved.isEmpty }
        #expect(helper.saved.first?.url == "https://evil.example")
    }

    @Test func iframesAreIgnored() async throws {
        let helper = FakeHelper()
        helper.logins["example.com"] = [("ada", "s3cret")]
        let (h, feature) = try await setUp(helper)
        let tab = h.fakeTab(h.openTab("https://example.com/"))
        tab.simulateScriptMessage("passwords.focus", body: ["kind": "login", "rect": rect], mainFrame: false,
                                  frameURL: URL(string: "https://ads.example/frame"))
        tab.simulateScriptMessage("passwords.submit", body: ["username": "a", "password": "b"], mainFrame: false)
        try await Task.sleep(for: .milliseconds(200))
        #expect(feature.model.field == nil)
        #expect(helper.saved.isEmpty)
    }

    @Test func newPasswordFieldsOfferApplesStrongPassword() throws {
        #expect(ApplePasswordsFeature.strongPassword()?.count ?? 0 >= 15)
        #expect(PasswordsScripts.literal("a\"b</script>") == "\"a\\\"b</script>\"")
    }
}
