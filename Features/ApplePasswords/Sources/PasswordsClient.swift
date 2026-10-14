import AppKit
import Foundation

/// A pipe to the helper: Chrome native-messaging framing (4-byte little-endian length + JSON).
protocol PasswordsTransport: AnyObject {
    /// Delivered on the main thread.
    var onMessage: (([String: Any]) -> Void)? { get set }
    /// `refused`: macOS killed the helper at launch (the browser lacks Apple's web-browser entitlement).
    var onClose: ((_ refused: Bool) -> Void)? { get set }
    func send(_ message: [String: Any]) throws
    func close()
}

/// Spawns Apple's `PasswordManagerBrowserExtensionHelper` as the iCloud Passwords extension would.
/// macOS lets it start only under a parent holding `com.apple.developer.web-browser.public-key-credential`
/// (or an allow-listed browser); otherwise it is SIGKILLed with a launch-constraint violation.
final class PasswordsHelperProcess: PasswordsTransport {
    static let path = "/System/Cryptexes/App/System/Library/CoreServices/PasswordManagerBrowserExtensionHelper.app/Contents/MacOS/PasswordManagerBrowserExtensionHelper"
    /// The origin of Apple's Chrome extension: the helper serves only that caller.
    static let extensionOrigin = "chrome-extension://pejdijmoenmkgeppbflobdenhhabjlaj/"

    var onMessage: (([String: Any]) -> Void)?
    var onClose: ((Bool) -> Void)?
    private let process = Process()
    private let input = Pipe(), output = Pipe()
    private var buffer = Data()
    private let started = Date()

    static var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: path) }

    init() throws {
        process.executableURL = URL(fileURLWithPath: Self.path)
        process.arguments = [Self.extensionOrigin]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            DispatchQueue.main.async { self?.receive(chunk) }
        }
        process.terminationHandler = { [weak self] p in
            let killedAtLaunch = p.terminationReason == .uncaughtSignal && p.terminationStatus == SIGKILL
            DispatchQueue.main.async {
                guard let self else { return }
                self.onClose?(killedAtLaunch && Date().timeIntervalSince(self.started) < 2)
            }
        }
        try process.run()
    }

    func send(_ message: [String: Any]) throws {
        let json = try JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes])
        var length = UInt32(json.count).littleEndian
        try input.fileHandleForWriting.write(contentsOf: Data(bytes: &length, count: 4) + json)
    }

    func close() {
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }

    private func receive(_ chunk: Data) {
        buffer.append(chunk)
        while buffer.count >= 4 {
            let length = Int(buffer.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian })
            guard buffer.count >= 4 + length else { return }
            let body = buffer.dropFirst(4).prefix(length)
            buffer = Data(buffer.dropFirst(4 + length))
            if let message = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] { onMessage?(message) }
        }
    }
}

struct PasswordsLogin: Equatable, Identifiable {
    var username: String
    /// Sites the login was used on; the first is where it is fetched from.
    var sites: [String]
    var id: String { username + "|" + (sites.first ?? "") }
}

/// Talks to the helper: capabilities, pairing with the code it displays, then encrypted queries.
/// Autofill (command 5) makes the helper show macOS's own "AutoFill for …" Touch ID prompt; saving
/// (command 6) shows its native "Save Password?" sheet and writes to the Passwords app.
@MainActor
final class PasswordsClient {
    enum State: Equatable {
        case idle
        case connecting
        /// The helper displays a 6-digit code; `pair(code:)` with it.
        case needsCode
        case ready
        /// Passwords can't be reached: the reason is shown in settings.
        case unavailable(String)
    }

    enum Command: Int {
        case handshake = 2, loginNames = 4, password = 5, save = 6, passwordsDisabled = 9, reloginNeeded = 10, capabilities = 14
    }

    enum ClientError: Error, Equatable { case notReady, timeout, closed, rejected(Int) }

    private(set) var state: State = .idle { didSet { onStateChange?(state) } }
    var onStateChange: ((State) -> Void)?
    private let makeTransport: () throws -> PasswordsTransport
    private var transport: PasswordsTransport?
    private var session: PasswordsSession?
    private var serverHello: [String: Any]?
    private var waiters: [(cmd: Int, resume: (Result<[String: Any], Error>) -> Void)] = []

    init(makeTransport: @escaping () throws -> PasswordsTransport = { try PasswordsHelperProcess() }) {
        self.makeTransport = makeTransport
    }

    /// Starts the helper and the handshake. Ends in `.needsCode` (the helper shows the code) or `.unavailable`.
    func connect() async {
        guard state == .idle || state == .needsCode || { if case .unavailable = state { true } else { false } }() else { return }
        state = .connecting
        do {
            let transport = try makeTransport()
            transport.onMessage = { [weak self] in self?.deliver($0) }
            transport.onClose = { [weak self] refused in self?.closed(refused: refused) }
            self.transport = transport
            let hello = try await request(.capabilities, [:])
            let caps = hello["capabilities"] as? [String: Any] ?? [:]
            let session = PasswordsSession(useBase64: caps["shouldUseBase64"] as? Bool ?? false)
            self.session = session
            let reply = try await request(.handshake, ["msg": Self.json(["QID": "m0", "PAKE": session.clientHello(), "HSTBRSR": "Chrome"])])
            serverHello = try Self.pake(reply)
            state = .needsCode
        } catch {
            fail(error)
        }
    }

    /// Completes pairing with the code the helper displays. Throws `wrongCode` (state stays `.needsCode`).
    func pair(code: String) async throws {
        guard state == .needsCode, let session, let serverHello else { throw ClientError.notReady }
        let proof = try session.clientProof(serverHello: serverHello, code: code)
        let reply = try await request(.handshake, ["msg": Self.json(["QID": "m2", "PAKE": proof])])
        do {
            try session.verifyServerProof(try Self.pake(reply))
            state = .ready
        } catch PasswordsSession.SessionError.wrongCode {
            // A new handshake: the helper shows a fresh code.
            state = .idle
            await connect()
            throw PasswordsSession.SessionError.wrongCode
        }
    }

    func loginNames(for host: String) async throws -> [PasswordsLogin] {
        let body = try await query(.loginNames, ["ACT": 5, "URL": host], qid: "CmdGetLoginNames4URL", extra: ["url": host])
        return Self.entries(body).compactMap { e in
            guard let user = e["USR"] as? String, user != "Passwords not saved" else { return nil }
            return PasswordsLogin(username: user, sites: e["sites"] as? [String] ?? [])
        }
    }

    /// The helper asks for Touch ID (or the Mac's password) before answering.
    func password(for login: PasswordsLogin, host: String) async throws -> String? {
        let site = login.sites.first ?? host
        let body = try await query(.password, ["ACT": 2, "URL": site, "USR": login.username], qid: "CmdGetPassword4LoginName",
                                   extra: ["url": site], timeout: 120)
        let entries = Self.entries(body)
        let match = entries.first { $0["USR"] as? String == login.username } ?? entries.first
        return (match?["PWD"] as? String).flatMap { $0 == "Not Included" ? nil : $0 }
    }

    /// Offers to save (or update) a login: the helper shows the native "Save Password?" sheet.
    func save(url: String, username: String, password: String) async throws {
        _ = try await query(.save, ["ACT": 4, "URL": "", "USR": "", "PWD": "", "NURL": url, "NUSR": username, "NPWD": password],
                            qid: "CmdSetPassword4LoginName_URL", extra: [:], timeout: 120, decrypt: false)
    }

    func disconnect() {
        transport?.close()
        transport = nil
        session = nil
        state = .idle
    }

    // MARK: Plumbing

    private func query(_ cmd: Command, _ body: [String: Any], qid: String, extra: [String: Any], timeout: TimeInterval = 5,
                       decrypt: Bool = true) async throws -> [String: Any] {
        guard state == .ready, let session else { throw ClientError.notReady }
        var message: [String: Any] = ["tabId": 0, "frameId": 0, "payload": Self.json(["QID": qid, "SMSG": try session.seal(body)])]
        message.merge(extra) { $1 }
        let reply = try await request(cmd, message, timeout: timeout)
        guard decrypt else { return reply }
        let payload = (reply["payload"] as? [String: Any]) ?? (reply["payload"] as? String).flatMap { Self.object($0) } ?? [:]
        guard let smsg = payload["SMSG"] else { throw PasswordsSession.SessionError.badMessage }
        let result = try session.open(smsg)
        if let status = result["STATUS"] as? Int, status != 0, status != 3 { throw ClientError.rejected(status) }
        return result
    }

    private func request(_ cmd: Command, _ body: [String: Any], timeout: TimeInterval = 5) async throws -> [String: Any] {
        guard let transport else { throw ClientError.closed }
        var message = body
        message["cmd"] = cmd.rawValue
        let reply: Reply = try await withCheckedThrowingContinuation { continuation in
            var done = false
            let resume: (Result<[String: Any], Error>) -> Void = { result in
                guard !done else { return }
                done = true
                continuation.resume(with: result.map(Reply.init))
            }
            waiters.append((cmd.rawValue, resume))
            do { try transport.send(message) } catch { resume(.failure(error)) }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { resume(.failure(ClientError.timeout)) }
        }
        return reply.value
    }

    /// Helper replies are plain JSON values, only ever touched on the main actor.
    private struct Reply: @unchecked Sendable { let value: [String: Any] }

    private func deliver(_ message: [String: Any]) {
        guard let cmd = message["cmd"] as? Int else { return }
        if cmd == Command.passwordsDisabled.rawValue || cmd == Command.reloginNeeded.rawValue {
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume(.failure(ClientError.rejected(cmd))) }
            state = .unavailable(cmd == 9 ? "Passwords are turned off for this Mac (Passwords › Settings)." : "Sign in to iCloud Keychain again.")
            return
        }
        guard let index = waiters.firstIndex(where: { $0.cmd == cmd }) else { return }
        waiters.remove(at: index).resume(.success(message))
    }

    private func closed(refused: Bool) {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(.failure(ClientError.closed)) }
        transport = nil
        session = nil
        state = refused
            ? .unavailable("macOS only lets browsers signed with Apple's Web Browser Public Key Credential entitlement talk to Passwords.")
            : .idle
    }

    private func fail(_ error: Error) {
        if case .unavailable = state { return }
        transport?.close()
        transport = nil
        state = .unavailable(PasswordsHelperProcess.isInstalled ? "Passwords didn't answer (\(error))." : "This macOS has no Passwords helper.")
    }

    static func pake(_ reply: [String: Any]) throws -> [String: Any] {
        let payload = (reply["payload"] as? [String: Any]) ?? (reply["payload"] as? String).flatMap { object($0) }
        guard let encoded = payload?["PAKE"] as? String, let data = Data(base64Encoded: encoded),
              let pake = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw PasswordsSession.SessionError.badServerHello }
        return pake
    }

    /// `Entries`, or older helpers' `Entry_0`, `Entry_1`… keys.
    static func entries(_ body: [String: Any]) -> [[String: Any]] {
        if let list = body["Entries"] as? [[String: Any]] { return list }
        return body.keys.filter { $0.hasPrefix("Entry_") }.sorted().compactMap { body[$0] as? [String: Any] }
    }

    static func json(_ object: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data(), as: UTF8.self)
    }

    static func object(_ string: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(string.utf8))) as? [String: Any]
    }
}
