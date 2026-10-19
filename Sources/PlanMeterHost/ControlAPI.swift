import Foundation
import PlanMeterCore
import PlanMeterRemote

// MARK: - Wire types
//
// The local control API (`planmeterd` ↔ desktop UI) is specified in
// docs/cross-platform.md. Responses use `RemoteJSON` (ISO-8601 dates, standard
// base64, sorted keys). Optional fields are always present, as `null` when
// unset, so clients can rely on every documented key.

public enum ControlAPIVersion {
    public static let current = 1
}

public struct DaemonStatus: Codable, Equatable, Sendable {
    public var apiVersion: Int
    public var version: String
    public var serverName: String
    public var isScanning: Bool
    public var lastScanAt: Date?
    public var lastError: String?
    public var pricingSource: String
    public var pricingError: String?
    public var accountCount: Int

    public init(apiVersion: Int = ControlAPIVersion.current, version: String, serverName: String, isScanning: Bool, lastScanAt: Date?,
                lastError: String?, pricingSource: String, pricingError: String?, accountCount: Int) {
        self.apiVersion = apiVersion
        self.version = version
        self.serverName = serverName
        self.isScanning = isScanning
        self.lastScanAt = lastScanAt
        self.lastError = lastError
        self.pricingSource = pricingSource
        self.pricingError = pricingError
        self.accountCount = accountCount
    }

    enum CodingKeys: String, CodingKey {
        case apiVersion, version, serverName, isScanning, lastScanAt, lastError, pricingSource, pricingError, accountCount
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(apiVersion, forKey: .apiVersion)
        try c.encode(version, forKey: .version)
        try c.encode(serverName, forKey: .serverName)
        try c.encode(isScanning, forKey: .isScanning)
        try c.encode(lastScanAt, forKey: .lastScanAt)
        try c.encode(lastError, forKey: .lastError)
        try c.encode(pricingSource, forKey: .pricingSource)
        try c.encode(pricingError, forKey: .pricingError)
        try c.encode(accountCount, forKey: .accountCount)
    }
}

public struct RemoteStatus: Codable, Equatable {
    public struct Tailscale: Codable, Equatable, Sendable {
        public var available: Bool
        public var address: String?
        public var dnsName: String?

        public init(available: Bool, address: String?, dnsName: String?) {
            self.available = available
            self.address = address
            self.dnsName = dnsName
        }

        enum CodingKeys: String, CodingKey { case available, address, dnsName }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(available, forKey: .available)
            try c.encode(address, forKey: .address)
            try c.encode(dnsName, forKey: .dnsName)
        }
    }

    public struct HTTPS: Codable, Equatable, Sendable {
        public var enabled: Bool
        public var active: Bool
        public var url: String?
        /// Why HTTPS is unavailable or failed (Tailscale's own diagnostic), if it is.
        public var certificateStatus: String?

        public init(enabled: Bool, active: Bool, url: String?, certificateStatus: String?) {
            self.enabled = enabled
            self.active = active
            self.url = url
            self.certificateStatus = certificateStatus
        }

        enum CodingKeys: String, CodingKey { case enabled, active, url, certificateStatus }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(enabled, forKey: .enabled)
            try c.encode(active, forKey: .active)
            try c.encode(url, forKey: .url)
            try c.encode(certificateStatus, forKey: .certificateStatus)
        }
    }

    public struct Invite: Codable, Equatable, Sendable {
        /// `planmeter://pair?…` for the tailnet host. A secret until it expires.
        public var url: String
        /// The same invite for a client on this machine (loopback), if bound.
        public var localUrl: String?
        /// Browser pairing link (HTTPS origin, or loopback), if available.
        public var webUrl: String?
        /// Eight digits for a web app that is already open.
        public var webCode: String?
        public var expiresAt: Date

        public init(url: String, localUrl: String?, webUrl: String?, webCode: String?, expiresAt: Date) {
            self.url = url
            self.localUrl = localUrl
            self.webUrl = webUrl
            self.webCode = webCode
            self.expiresAt = expiresAt
        }

        enum CodingKeys: String, CodingKey { case url, localUrl, webUrl, webCode, expiresAt }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(url, forKey: .url)
            try c.encode(localUrl, forKey: .localUrl)
            try c.encode(webUrl, forKey: .webUrl)
            try c.encode(webCode, forKey: .webCode)
            try c.encode(expiresAt, forKey: .expiresAt)
        }
    }

    public var enabled: Bool
    public var port: Int
    /// "off", "listening", "unavailable" (no tailnet address to bind), or "error".
    public var status: String
    /// Human-readable detail for `status`, if any.
    public var message: String?
    public var bindAddresses: [String]
    public var tailscale: Tailscale
    public var https: HTTPS
    public var devices: [PairedDevice]
    public var invite: Invite?
    /// Recent activity, newest first.
    public var log: [String]

    public init(enabled: Bool, port: Int, status: String, message: String?, bindAddresses: [String], tailscale: Tailscale,
                https: HTTPS, devices: [PairedDevice], invite: Invite?, log: [String]) {
        self.enabled = enabled
        self.port = port
        self.status = status
        self.message = message
        self.bindAddresses = bindAddresses
        self.tailscale = tailscale
        self.https = https
        self.devices = devices
        self.invite = invite
        self.log = log
    }

    enum CodingKeys: String, CodingKey { case enabled, port, status, message, bindAddresses, tailscale, https, devices, invite, log }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(port, forKey: .port)
        try c.encode(status, forKey: .status)
        try c.encode(message, forKey: .message)
        try c.encode(bindAddresses, forKey: .bindAddresses)
        try c.encode(tailscale, forKey: .tailscale)
        try c.encode(https, forKey: .https)
        try c.encode(devices, forKey: .devices)
        try c.encode(invite, forKey: .invite)
        try c.encode(log, forKey: .log)
    }
}

/// `POST /v1/refresh` body (optional).
public struct RefreshRequest: Codable, Equatable, Sendable {
    public var forceAccountUsage: Bool?
    public init(forceAccountUsage: Bool? = nil) { self.forceAccountUsage = forceAccountUsage }
}

/// `PUT /v1/settings/groups/{accountId}` body. `null` restores the suggested group.
public struct GroupUpdate: Codable, Equatable, Sendable {
    public var group: String?
    public init(group: String?) { self.group = group }

    enum CodingKeys: String, CodingKey { case group }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(group, forKey: .group)
    }
}

/// `PUT /v1/settings/spend` body. Each present field replaces the stored value.
public struct SpendUpdate: Codable, Equatable {
    public var groups: [String]?
    public var thresholds: [String: SpendThreshold]?
    public init(groups: [String]? = nil, thresholds: [String: SpendThreshold]? = nil) {
        self.groups = groups
        self.thresholds = thresholds
    }
}

/// `PUT /v1/remote` body.
public struct RemoteUpdate: Codable, Equatable, Sendable {
    public var enabled: Bool?
    public var httpsEnabled: Bool?
    public var port: Int?
    public init(enabled: Bool? = nil, httpsEnabled: Bool? = nil, port: Int? = nil) {
        self.enabled = enabled
        self.httpsEnabled = httpsEnabled
        self.port = port
    }
}

public struct ControlError: Codable, Equatable, Sendable {
    public var error: String
    public init(error: String) { self.error = error }
}

// MARK: - Routing

/// Answers the local control API. Transport-agnostic: the daemon serves it on
/// a Unix socket restricted to the same user.
@MainActor
public final class ControlAPI {
    public let engine: HostEngine
    public let settings: HostSettingsStore
    public let remote: RemoteController
    public let version: String

    public init(engine: HostEngine, settings: HostSettingsStore, remote: RemoteController, version: String) {
        self.engine = engine
        self.settings = settings
        self.remote = remote
        self.version = version
    }

    static let groupsPrefix = "/v1/settings/groups/"
    static let devicesPrefix = "/v1/remote/devices/"

    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        let path = request.path
        switch (request.method, path) {
        case ("GET", "/v1/status"):
            return .remoteJSON(status())
        case ("POST", "/v1/refresh"):
            let body: RefreshRequest
            if request.body.isEmpty {
                body = RefreshRequest()
            } else {
                guard let decoded = decode(RefreshRequest.self, request) else { return badRequest("expected {\"forceAccountUsage\": bool}") }
                body = decoded
            }
            await engine.refresh(forceAccountUsage: body.forceAccountUsage ?? false)
            return .remoteJSON(status())
        case ("POST", "/v1/rpc"):
            guard let rpc = decode(RemoteRequest.self, request) else { return badRequest("expected a RemoteRequest") }
            return .remoteJSON(await engine.reply(for: rpc))
        case ("GET", "/v1/settings"):
            return .remoteJSON(settings.settings)
        case ("PUT", "/v1/settings/spend"):
            return updateSpend(request)
        case ("PUT", _) where path.hasPrefix(Self.groupsPrefix):
            return updateGroup(request, encodedId: String(path.dropFirst(Self.groupsPrefix.count)))
        case ("GET", "/v1/remote"):
            return .remoteJSON(remote.status())
        case ("PUT", "/v1/remote"):
            guard let update = decode(RemoteUpdate.self, request) else { return badRequest("expected {\"enabled\": bool?, \"httpsEnabled\": bool?, \"port\": int?}") }
            do {
                try await remote.update(enabled: update.enabled, httpsEnabled: update.httpsEnabled, port: update.port)
            } catch RemoteController.ControllerError.invalidPort {
                return badRequest(RemoteController.ControllerError.invalidPort.localizedDescription)
            } catch {
                return .error(500, "could not save settings: \(error.localizedDescription)")
            }
            return .remoteJSON(remote.status())
        case ("POST", "/v1/remote/invite"):
            do {
                try remote.newInvite()
            } catch {
                return .error(409, error.localizedDescription)
            }
            return .remoteJSON(remote.status())
        case ("DELETE", "/v1/remote/invite"):
            remote.service.cancelInvite()
            return .remoteJSON(remote.status())
        case ("DELETE", _) where path.hasPrefix(Self.devicesPrefix):
            let id = String(path.dropFirst(Self.devicesPrefix.count)).removingPercentEncoding ?? ""
            guard remote.service.revoke(id: id) != nil else { return .error(404, "unknown device") }
            return .remoteJSON(remote.status())
        case (_, "/v1/status"), (_, "/v1/refresh"), (_, "/v1/rpc"), (_, "/v1/settings"), (_, "/v1/settings/spend"),
             (_, "/v1/remote"), (_, "/v1/remote/invite"):
            return .error(405, "method not allowed")
        case (_, _) where path.hasPrefix(Self.groupsPrefix) || path.hasPrefix(Self.devicesPrefix):
            return .error(405, "method not allowed")
        default:
            return .error(404, "not found")
        }
    }

    public func status() -> DaemonStatus {
        DaemonStatus(
            version: version,
            serverName: engine.serverName,
            isScanning: engine.isScanning,
            lastScanAt: engine.lastScan,
            lastError: engine.lastError,
            pricingSource: engine.rates.source,
            pricingError: engine.pricingError,
            accountCount: engine.accounts.count
        )
    }

    private func decode<T: Decodable>(_ type: T.Type, _ request: HTTPRequest) -> T? {
        try? RemoteJSON.decoder.decode(type, from: request.body)
    }

    private func badRequest(_ message: String) -> HTTPResponse { .error(400, message) }

    /// The account id is everything after the prefix, percent-decoded, so ids
    /// containing "/" (Claude homes) work whether or not the client encodes them.
    private func updateGroup(_ request: HTTPRequest, encodedId: String) -> HTTPResponse {
        guard let id = encodedId.removingPercentEncoding, !id.isEmpty else { return badRequest("missing account id") }
        guard let update = decode(GroupUpdate.self, request) else { return badRequest("expected {\"group\": \"personal\" | \"work\" | \"other\" | null}") }
        var group: PlanGroup?
        if let raw = update.group {
            guard let parsed = PlanGroup(rawValue: raw) else { return badRequest("unknown group \(raw)") }
            group = parsed
        }
        // Same rule as the Mac: choosing the suggested group clears the override.
        let account = engine.account(for: id)
        do {
            try settings.update { settings in
                if let group, group != account.suggestedGroup {
                    settings.groupOverrides[id] = group
                } else {
                    settings.groupOverrides.removeValue(forKey: id)
                }
            }
        } catch {
            return .error(500, "could not save settings: \(error.localizedDescription)")
        }
        engine.groupOverrides = settings.settings.groupOverrides
        return .remoteJSON(settings.settings)
    }

    private func updateSpend(_ request: HTTPRequest) -> HTTPResponse {
        guard let update = decode(SpendUpdate.self, request) else { return badRequest("expected {\"groups\": [String]?, \"thresholds\": {range: SpendThreshold}?}") }
        var groups: [PlanGroup]?
        if let raw = update.groups {
            let parsed = raw.compactMap(PlanGroup.init(rawValue:))
            guard parsed.count == raw.count else { return badRequest("unknown group in \(raw)") }
            guard !parsed.isEmpty else { return badRequest("spend groups cannot be empty") }
            groups = parsed
        }
        if let thresholds = update.thresholds {
            if let bad = thresholds.keys.first(where: { !HostSettings.rangeIds.contains($0) }) {
                return badRequest("unknown range \(bad); expected one of \(HostSettings.rangeIds.joined(separator: ", "))")
            }
            if let bad = thresholds.first(where: { !$0.value.isValid }) {
                return badRequest("invalid threshold for \(bad.key): limit must be 0.01…1e9 and warningPercent 1…99")
            }
        }
        do {
            try settings.update { settings in
                if let groups { settings.spendGroups = groups }
                if let thresholds = update.thresholds { settings.spendThresholds = thresholds }
            }
        } catch {
            return .error(500, "could not save settings: \(error.localizedDescription)")
        }
        return .remoteJSON(settings.settings)
    }
}
