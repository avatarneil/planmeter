import CryptoKit
import Foundation
import Network
import PlanMeterRemote

// Interop harness for android/protocol, built on this checkout's PlanMeterRemote.
//
//   planmeter-interop vectors <out.json>
//       Writes keys, Swift-sealed requests and responses, CryptoKit signatures,
//       Swift-encoded replies, and Swift's verdict on a list of pairing links.
//       The Kotlin tests check all of them (protocol/src/test/resources/interop).
//
//   planmeter-interop serve [--port 7799] [--advertise-host host.docker.internal]
//                           [--invite-file path] [--seconds 600]
//       Runs a host that answers /v1/info, /v1/pair, and /v1/rpc exactly as
//       RemoteState does (same checks, same SecureChannel calls) with canned
//       data, and prints a pairing link. The Kotlin LiveSwiftServerTest pairs
//       with it and calls every RPC method.

// MARK: - Canned data

enum Canned {
    static let generatedAt = Date(timeIntervalSince1970: 1_792_411_200) // 2026-10-19T12:00:00Z
    static let serverName = "Interop Host ✓"
    static let version = "interop-1"

    static let personal = RemoteAccount(id: "codex-personal", name: "Codex (personal)", provider: "codex", providerName: "Codex", group: "personal", email: "me@example.com", plan: "Plus", accentColorHex: "#10a37f")
    static let work = RemoteAccount(id: "claude-work", name: "Claude Code (work)", provider: "claude", providerName: "Claude", group: "work", plan: "Team", accentColorHex: "#d97757")
    static let other = RemoteAccount(id: "opencode", name: "OpenCode", provider: "opencode", providerName: "OpenCode", group: "other")
    static let accounts = [personal, work, other]

    static func totals(_ cost: Double, _ tokens: Int) -> RemoteTotals {
        RemoteTotals(costUsd: cost, tokens: tokens, inputTokens: tokens * 3 / 4, cachedInputTokens: tokens / 2, outputTokens: tokens / 4, sessions: tokens / 1_000_000 + 1, cacheSavingsUsd: cost / 3)
    }

    static func reply(for request: RemoteRequest) -> RemoteReply {
        let days = request.days ?? 30
        switch request.method {
        case .summary:
            let span: TimeInterval = request.minutes.map { TimeInterval($0 * 60) } ?? TimeInterval(days * 86_400)
            let groups = [
                RemoteGroupUsage(group: "personal", totals: totals(12.5, 3_400_000_000), accounts: [RemoteAccountUsage(account: personal, totals: totals(12.5, 3_400_000_000))]),
                RemoteGroupUsage(group: "work", totals: totals(80.25, 21_000_000), accounts: [RemoteAccountUsage(account: work, totals: totals(80.25, 21_000_000))]),
                RemoteGroupUsage(group: "other", totals: totals(0, 0), accounts: [RemoteAccountUsage(account: other, totals: totals(0, 0))]),
            ]
            return RemoteReply(summary: RemoteSummary(days: days, from: generatedAt.addingTimeInterval(-span), to: generatedAt, groups: groups, total: totals(92.75, 3_421_000_000), todayCostUsd: 4.56, generatedAt: generatedAt, serverName: serverName, pricingSource: "litellm", usesProviderDates: true, minutes: request.minutes))
        case .timeline:
            let resolution = request.resolution ?? "day"
            let step = RemoteTimeline.stepSeconds(resolution) ?? 86_400
            let periods = (0..<3).map { generatedAt.addingTimeInterval(-step * Double(2 - $0)) }
            let points = [
                RemoteTimelinePoint(period: periods[0], accountId: personal.id, costUsd: 1.25, tokens: 1000),
                RemoteTimelinePoint(period: periods[1], accountId: work.id, costUsd: 2.5, tokens: 2000, baselineCostUsd: 0.5),
                RemoteTimelinePoint(period: periods[2], accountId: personal.id, costUsd: 0.75, tokens: 300),
            ]
            return RemoteReply(timeline: RemoteTimeline(days: days, resolution: resolution, periods: periods, points: points, accounts: accounts, minutes: request.minutes))
        case .limits:
            let windows = [
                RemoteLimitWindow(label: "5h", usedPercent: 42.5, windowMinutes: 300, resetsAt: generatedAt.addingTimeInterval(3_600)),
                RemoteLimitWindow(label: "Weekly", usedPercent: 91, windowMinutes: 10_080, resetsAt: generatedAt.addingTimeInterval(259_200)),
            ]
            return RemoteReply(limits: RemoteLimits(accounts: [RemoteAccountLimits(account: personal, windows: windows, note: nil, asOf: generatedAt)], note: "From Codex CLI rate-limit headers."))
        case .models:
            var rows = [
                RemoteModelRow(accountId: work.id, accountName: work.name, group: "work", provider: "claude", model: "claude-opus-4-1", totals: totals(70, 15_000_000), priced: true),
                RemoteModelRow(accountId: personal.id, accountName: personal.name, group: "personal", provider: "codex", model: "gpt-5-codex", totals: totals(12.5, 3_400_000_000), priced: true),
                RemoteModelRow(accountId: other.id, accountName: other.name, group: "other", provider: "opencode", model: "local/qwen3", totals: totals(0, 5_000), priced: false),
            ]
            if let account = request.account { rows = rows.filter { $0.accountId == account } }
            return RemoteReply(models: rows)
        case .accounts:
            return RemoteReply(accounts: RemoteAccounts(accounts: accounts, sources: [
                RemoteSource(provider: "codex", path: "/Users/me/.codex/sessions", status: "ok"),
                RemoteSource(provider: "claude", path: "/Users/me/.claude/projects", status: "ok"),
            ], scannedAt: generatedAt))
        }
    }
}

func encodeString<T: Encodable>(_ value: T) -> String {
    String(decoding: try! RemoteJSON.encoder.encode(value), as: UTF8.self)
}

func keyBytes(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

// MARK: - Vectors

struct SealCase: Codable {
    var name: String
    var method: String
    var path: String
    var deviceId: String
    var cipher: String
    var requestPlaintext: Data
    /// The envelope exactly as Swift serialized it.
    var sealedRequest: String
    var responseKey: Data
    var responsePlaintext: Data
    var sealedResponse: String
}

struct SignatureCase: Codable {
    var message: Data
    var signature: Data
}

struct PairingURLCase: Codable {
    var url: String
    var valid: Bool
    var serverHost: String?
    var port: Int?
    var serverName: String?
    var serverPublicKey: Data?
    var token: String?
    var expiresAt: Int64?
}

struct Vectors: Codable {
    var generator: String
    var serverPrivateKey: Data
    var serverPublicKey: Data
    var devicePrivateKey: Data
    var devicePublicKey: Data
    var deviceId: String
    var seals: [SealCase]
    var signatures: [SignatureCase]
    var pairingURLs: [PairingURLCase]
    /// RemoteJSON-encoded replies, one per RPC method plus an error reply.
    var replies: [String: String]
}

func makeVectors() throws -> Vectors {
    let server = SoftwareAgreementKey()
    let device = SoftwareSigningKey()
    let deviceId = DeviceId.derive(fromPublicKey: device.publicKeyRaw)

    func sealCase(name: String, path: String, deviceId: String, cipher: SecureChannel.Cipher, plaintext: Data, response: Data) throws -> SealCase {
        let sealed = try SecureChannel.seal(plaintext: plaintext, serverPublicKeyRaw: server.publicKeyRaw, deviceId: deviceId, signer: device, method: "POST", path: path, cipher: cipher)
        // Prove the envelope is good on the Swift side before handing it over.
        precondition(SecureChannel.verifySignature(sealed.request, devicePublicKeyRaw: device.publicKeyRaw, method: "POST", path: path))
        let opened = try SecureChannel.open(sealed.request, serverKey: server, method: "POST", path: path)
        precondition(opened.plaintext == plaintext)
        let sealedResponse = try SecureChannel.sealResponse(plaintext: response, key: opened.responseKey, cipher: cipher)
        let reopened = try SecureChannel.openResponse(sealedResponse, key: sealed.responseKey)
        precondition(reopened == response)
        return SealCase(name: name, method: "POST", path: path, deviceId: deviceId, cipher: cipher.rawValue, requestPlaintext: plaintext, sealedRequest: encodeString(sealed.request), responseKey: keyBytes(opened.responseKey), responsePlaintext: response, sealedResponse: encodeString(sealedResponse))
    }

    let rpcBody = try RemoteJSON.encoder.encode(RemoteRequest(method: .timeline, days: 1, resolution: "minute", minutes: 60))
    let rpcReply = try RemoteJSON.encoder.encode(Canned.reply(for: RemoteRequest(method: .summary, days: 7)))
    let pairBody = try RemoteJSON.encoder.encode(PairRequest(token: "tok_-123", deviceName: "Pixel 10 Pro", devicePublicKey: device.publicKeyRaw, platform: "Android 17"))
    let pairReply = try RemoteJSON.encoder.encode(PairResponse(deviceId: deviceId, serverName: Canned.serverName, serverVersion: Canned.version))
    var seals: [SealCase] = []
    for cipher in [SecureChannel.Cipher.chacha20poly1305, .aes256gcm] {
        seals.append(try sealCase(name: "rpc-\(cipher.rawValue)", path: RemoteClient.rpcPath, deviceId: deviceId, cipher: cipher, plaintext: rpcBody, response: rpcReply))
        seals.append(try sealCase(name: "pair-\(cipher.rawValue)", path: RemoteClient.pairPath, deviceId: "pairing", cipher: cipher, plaintext: pairBody, response: pairReply))
    }
    seals.append(try sealCase(name: "empty-body", path: RemoteClient.rpcPath, deviceId: deviceId, cipher: .chacha20poly1305, plaintext: Data(), response: Data()))

    var signatures: [SignatureCase] = []
    for i in 0..<64 {
        let message = Data("message \(i) \(UUID().uuidString)".utf8)
        signatures.append(SignatureCase(message: message, signature: try device.sign(message)))
    }

    let invite = PairingInvite(serverHost: "devbox.tail1234.ts.net", port: 7787, serverName: "Neil’s MacBook Pro", serverPublicKey: server.publicKeyRaw, token: PairingInvite.makeToken(), expiresAt: Canned.generatedAt.addingTimeInterval(300))
    let k = server.publicKeyRaw.base64URLEncodedString()
    let candidates: [String] = [
        invite.url.absoluteString,
        "planmeter://pair?h=100.64.0.7&p=7787&k=\(k)&t=abc&e=1792411500",
        "planmeter://pair?h=fd7a:115c:a1e0::1&p=7787&n=&k=\(k)&t=abc&e=1792411500",
        "planmeter://pair?h=100.64.0.7&p=7787&n=Mac%20mini&k=\(k)&t=a%2Bb&e=1792411500",
        "planmeter://pair?h=100.64.0.7&p=7787&n=Mac+mini&k=\(k)&t=abc&e=1792411500",
        "planmeter://pair?h=first&h=second&p=7787&k=\(k)&t=abc&e=1792411500",
        "planmeter://pair/?h=100.64.0.7&p=7787&k=\(k)&t=abc&e=1792411500",
        "planmeter://pair?h=100.64.0.7&p=+7787&k=\(k)&t=abc&e=+1792411500",
        "planmeter://pair?h=100.64.0.7&p=7787&k=\(k)&t=abc&e=-5",
        "planmeter://pair?h=100.64.0.7&p=7787&k=\(k)&t=abc&e=1792411500#frag",
        "planmeter://pair?h=100.64.0.7&p=0&k=\(k)&t=abc&e=1792411500",
        "planmeter://pair?h=100.64.0.7&p=65536&k=\(k)&t=abc&e=1792411500",
        "planmeter://pair?h=100.64.0.7&p=77x&k=\(k)&t=abc&e=1792411500",
        "planmeter://pair?h=&p=7787&k=\(k)&t=abc&e=1792411500",
        "planmeter://pair?p=7787&k=\(k)&t=abc&e=1792411500",
        "planmeter://pair?h=100.64.0.7&p=7787&k=\(k)&t=&e=1792411500",
        "planmeter://pair?h=100.64.0.7&p=7787&k=\(k)&e=1792411500",
        "planmeter://pair?h=100.64.0.7&p=7787&k=\(k)&t=abc",
        "planmeter://pair?h=100.64.0.7&p=7787&k=\(k)&t=abc&e=soon",
        "planmeter://pair?h=100.64.0.7&p=7787&k=\(String(k.dropLast(2)))&t=abc&e=1792411500",
        "planmeter://pair?h=100.64.0.7&p=7787&k=\(k)AAAA&t=abc&e=1792411500",
        "planmeter://pair?h=100.64.0.7&p=7787&k=\(server.publicKeyRaw.base64EncodedString())&t=abc&e=1792411500",
        "planmeter://pair?h=100.64.0.7&p=7787&k=!!!&t=abc&e=1792411500",
        "planmeter://other?h=100.64.0.7&p=7787&k=\(k)&t=abc&e=1792411500",
        "https://pair?h=100.64.0.7&p=7787&k=\(k)&t=abc&e=1792411500",
        "https://devbox.tail1234.ts.net/#k=\(k)&t=abc&e=1792411500&n=Mac",
        "planmeter://pair",
        "not a url",
    ]
    let pairingURLs: [PairingURLCase] = candidates.map { text in
        guard let url = URL(string: text), let parsed = PairingInvite(url: url) else { return PairingURLCase(url: text, valid: false) }
        return PairingURLCase(url: text, valid: true, serverHost: parsed.serverHost, port: parsed.port, serverName: parsed.serverName, serverPublicKey: parsed.serverPublicKey, token: parsed.token, expiresAt: Int64(parsed.expiresAt.timeIntervalSince1970))
    }

    var replies: [String: String] = [:]
    for method in RemoteMethod.allCases {
        replies[method.rawValue] = encodeString(Canned.reply(for: RemoteRequest(method: method, days: 7, resolution: "hour")))
    }
    replies["error"] = encodeString(RemoteReply(error: "server not ready"))
    replies["info"] = encodeString(ServerInfo(version: Canned.version, serverName: Canned.serverName))

    return Vectors(generator: "android/interop/swift (PlanMeterRemote)", serverPrivateKey: server.blobRaw, serverPublicKey: server.publicKeyRaw, devicePrivateKey: device.blobRaw, devicePublicKey: device.publicKeyRaw, deviceId: deviceId, seals: seals, signatures: signatures, pairingURLs: pairingURLs, replies: replies)
}

extension SoftwareAgreementKey {
    var blobRaw: Data { if case .software(let raw) = blob { return raw } else { fatalError() } }
}

extension SoftwareSigningKey {
    var blobRaw: Data { if case .software(let raw) = blob { return raw } else { fatalError() } }
}

// MARK: - Server (mirrors RemoteState's handlers)

final class InteropHost: @unchecked Sendable {
    let serverKey = SoftwareAgreementKey()
    let replay = ReplayCache()
    let lock = NSLock()
    var invite: PairingInvite?
    var devices: [PairedDevice] = []
    var pairFailures = 0
    var stats: [String: Int] = [:]

    init(advertiseHost: String, port: Int) {
        invite = PairingInvite(serverHost: advertiseHost, port: port, serverName: Canned.serverName, serverPublicKey: serverKey.publicKeyRaw, token: PairingInvite.makeToken(), expiresAt: Date().addingTimeInterval(600))
    }

    func count(_ key: String) { stats[key, default: 0] += 1 }

    func handle(method: String, path: String, body: Data) -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        switch (method, path) {
        case ("GET", RemoteClient.infoPath):
            return (200, try! JSONEncoder().encode(ServerInfo(version: Canned.version, serverName: Canned.serverName)))
        case ("POST", RemoteClient.pairPath):
            return handlePair(body)
        case ("POST", RemoteClient.rpcPath):
            return handleRPC(body)
        default:
            return failure(404, "not found")
        }
    }

    func failure(_ status: Int, _ message: String) -> (Int, Data) {
        count("http-\(status)")
        log("-> \(status) \(message)")
        return (status, try! JSONEncoder().encode(["error": message]))
    }

    func decodeSealed(_ body: Data) -> SecureChannel.SealedRequest? {
        guard let sealed = try? RemoteJSON.decoder.decode(SecureChannel.SealedRequest.self, from: body) else { return nil }
        do { try SecureChannel.checkTimestamp(sealed) } catch { return nil }
        return sealed
    }

    func handlePair(_ body: Data) -> (Int, Data) {
        guard let sealed = decodeSealed(body), sealed.deviceId == "pairing" else { return failure(400, "bad pairing request") }
        guard let invite, !invite.isExpired else { return failure(403, "no active pairing code") }
        guard replay.record(deviceId: "pairing", nonce: sealed.nonce) else { return failure(409, "replay") }
        let opened: SecureChannel.Opened
        let pair: PairRequest
        do {
            opened = try SecureChannel.open(sealed, serverKey: serverKey, method: "POST", path: RemoteClient.pairPath)
            pair = try RemoteJSON.decoder.decode(PairRequest.self, from: opened.plaintext)
        } catch {
            return pairFailure("undecryptable pairing request")
        }
        guard pair.devicePublicKey.count == 65,
              SecureChannel.verifySignature(sealed, devicePublicKeyRaw: pair.devicePublicKey, method: "POST", path: RemoteClient.pairPath) else {
            return pairFailure("pairing signature failed")
        }
        guard Data(pair.token.utf8).constantTimeEquals(Data(invite.token.utf8)) else { return pairFailure("wrong pairing token") }
        let id = DeviceId.derive(fromPublicKey: pair.devicePublicKey)
        devices.removeAll { $0.id == id }
        devices.append(PairedDevice(id: id, name: pair.deviceName, platform: pair.platform, publicKey: pair.devicePublicKey, pairedAt: Date()))
        self.invite = nil
        count("paired")
        count("cipher-\(opened.cipher.rawValue)")
        log("paired \(pair.deviceName) (\(pair.platform)) as \(id)")
        return seal(PairResponse(deviceId: id, serverName: Canned.serverName, serverVersion: Canned.version), key: opened.responseKey, cipher: opened.cipher)
    }

    func pairFailure(_ message: String) -> (Int, Data) {
        pairFailures += 1
        log(message)
        if pairFailures >= 5 { invite = nil; log("pairing code cancelled after repeated failures") }
        return failure(403, "pairing rejected")
    }

    func handleRPC(_ body: Data) -> (Int, Data) {
        guard let sealed = decodeSealed(body) else { return failure(400, "bad request") }
        guard let index = devices.firstIndex(where: { $0.id == sealed.deviceId }) else { return failure(401, "unknown device") }
        let device = devices[index]
        guard SecureChannel.verifySignature(sealed, devicePublicKeyRaw: device.publicKey, method: "POST", path: RemoteClient.rpcPath) else {
            return failure(401, "signature failed")
        }
        guard replay.record(deviceId: device.id, nonce: sealed.nonce) else { return failure(409, "replay") }
        let opened: SecureChannel.Opened
        let rpc: RemoteRequest
        do {
            opened = try SecureChannel.open(sealed, serverKey: serverKey, method: "POST", path: RemoteClient.rpcPath)
            rpc = try RemoteJSON.decoder.decode(RemoteRequest.self, from: opened.plaintext)
        } catch {
            return failure(400, "undecryptable request")
        }
        devices[index].requestCount += 1
        count("rpc-\(rpc.method.rawValue)")
        count("cipher-\(opened.cipher.rawValue)")
        return seal(Canned.reply(for: rpc), key: opened.responseKey, cipher: opened.cipher)
    }

    func seal<T: Encodable>(_ value: T, key: SymmetricKey, cipher: SecureChannel.Cipher) -> (Int, Data) {
        let plaintext = try! RemoteJSON.encoder.encode(value)
        let sealed = try! SecureChannel.sealResponse(plaintext: plaintext, key: key, cipher: cipher)
        return (200, try! RemoteJSON.encoder.encode(sealed))
    }
}

func log(_ line: String) {
    FileHandle.standardError.write(Data("[interop] \(line)\n".utf8))
}

/// One request per connection, Content-Length bodies, Connection: close, like RemoteHTTPServer.
func serve(host: InteropHost, port: UInt16) throws -> NWListener {
    let params = NWParameters.tcp
    params.allowLocalEndpointReuse = true
    params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
    let listener = try NWListener(using: params)
    let queue = DispatchQueue(label: "interop")
    listener.newConnectionHandler = { connection in
        connection.start(queue: queue)
        var buffer = Data()
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let data { buffer.append(data) }
                if error != nil { connection.cancel(); return }
                guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    if isComplete { connection.cancel() } else { receive() }
                    return
                }
                let head = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
                let lines = head.components(separatedBy: "\r\n")
                let requestLine = lines.first?.split(separator: " ").map(String.init) ?? []
                var length = 0
                for line in lines.dropFirst() where line.lowercased().hasPrefix("content-length:") {
                    length = Int(line.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) ?? 0
                }
                let bodyStart = headerEnd.upperBound
                if buffer.count - bodyStart < length {
                    if isComplete { connection.cancel() } else { receive() }
                    return
                }
                let body = buffer.subdata(in: bodyStart..<(bodyStart + length))
                let method = requestLine.first ?? ""
                let path = requestLine.count > 1 ? String(requestLine[1].split(separator: "?").first ?? "") : ""
                let (status, responseBody) = host.handle(method: method, path: path, body: body)
                var response = Data("HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: application/json\r\nContent-Length: \(responseBody.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
                response.append(responseBody)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        receive()
    }
    listener.start(queue: queue)
    return listener
}

// MARK: - Entry point

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

switch args.first {
case "vectors":
    guard args.count >= 2 else { log("usage: vectors <out.json>"); exit(2) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(try makeVectors()).write(to: URL(fileURLWithPath: args[1]))
    log("wrote \(args[1])")
case "serve":
    let port = UInt16(option("--port") ?? "7799")!
    let advertise = option("--advertise-host") ?? "host.docker.internal"
    let seconds = Double(option("--seconds") ?? "600")!
    let host = InteropHost(advertiseHost: advertise, port: Int(port))
    let listener = try serve(host: host, port: port)
    let url = host.invite!.url.absoluteString
    print(url)
    fflush(stdout)
    if let file = option("--invite-file") { try url.write(toFile: file, atomically: true, encoding: .utf8) }
    log("listening on 127.0.0.1:\(port); advertising \(advertise)")
    let stop = {
        host.lock.lock()
        let summary = host.stats.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        host.lock.unlock()
        log("summary: \(summary)")
        listener.cancel()
        exit(0)
    }
    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)
    let sources = [SIGTERM, SIGINT].map { sig -> DispatchSourceSignal in
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler(handler: stop)
        source.resume()
        return source
    }
    _ = sources
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: stop)
    dispatchMain()
default:
    log("usage: planmeter-interop vectors <out.json> | serve [--port N] [--advertise-host H] [--invite-file F] [--seconds S]")
    exit(2)
}
