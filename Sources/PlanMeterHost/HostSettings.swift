import Foundation
import PlanMeterCore
import PlanMeterRemote

/// The daemon's user settings, as the control API exposes them. Range ids
/// match the Mac's `TimeRange` ids, so a spend limit means the same thing on
/// every desktop.
public struct HostSettings: Codable, Equatable {
    public static let rangeIds = ["lastHour", "today", "day", "week", "month", "quarter"]

    /// Account id → group, for accounts the user moved from their suggested group.
    public var groupOverrides: [String: PlanGroup]
    /// The groups whose spend the desktop's headline figure includes. Never empty.
    public var spendGroups: [PlanGroup]
    /// Range id → personal spend target.
    public var spendThresholds: [String: SpendThreshold]

    public init(groupOverrides: [String: PlanGroup] = [:], spendGroups: [PlanGroup] = PlanGroup.allCases, spendThresholds: [String: SpendThreshold] = [:]) {
        self.groupOverrides = groupOverrides
        self.spendGroups = spendGroups
        self.spendThresholds = spendThresholds
    }

    enum CodingKeys: String, CodingKey { case groupOverrides, spendGroups, spendThresholds }

    /// Lenient: unknown groups, ranges, and invalid thresholds are dropped
    /// rather than failing the whole document.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let overrides = (try? c.decodeIfPresent([String: String].self, forKey: .groupOverrides)) ?? nil
        groupOverrides = (overrides ?? [:]).compactMapValues(PlanGroup.init(rawValue:))
        let groups = ((try? c.decodeIfPresent([String].self, forKey: .spendGroups)) ?? nil)?.compactMap(PlanGroup.init(rawValue:)) ?? []
        spendGroups = Self.normalized(groups)
        let thresholds = (try? c.decodeIfPresent([String: SpendThreshold].self, forKey: .spendThresholds)) ?? nil
        spendThresholds = (thresholds ?? [:]).filter { Self.rangeIds.contains($0.key) && $0.value.isValid }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(groupOverrides.mapValues(\.rawValue), forKey: .groupOverrides)
        try c.encode(spendGroups.map(\.rawValue), forKey: .spendGroups)
        try c.encode(spendThresholds, forKey: .spendThresholds)
    }

    /// Unique, in `PlanGroup.allCases` order; all groups when empty.
    public static func normalized(_ groups: [PlanGroup]) -> [PlanGroup] {
        let set = Set(groups)
        let ordered = PlanGroup.allCases.filter(set.contains)
        return ordered.isEmpty ? PlanGroup.allCases : ordered
    }
}

/// Remote access settings, persisted next to `HostSettings`.
public struct RemoteSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var port: UInt16
    public var httpsEnabled: Bool

    public init(enabled: Bool = false, port: UInt16 = RemoteService.defaultPort, httpsEnabled: Bool = false) {
        self.enabled = enabled
        self.port = port
        self.httpsEnabled = httpsEnabled
    }

    enum CodingKeys: String, CodingKey { case enabled, port, httpsEnabled }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? nil ?? false
        let port = (try? c.decodeIfPresent(Int.self, forKey: .port)) ?? nil
        self.port = port.flatMap { RemoteSettings.validPort($0) } ?? RemoteService.defaultPort
        httpsEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .httpsEnabled)) ?? nil ?? false
    }

    /// Unprivileged ports only, as the Mac's port field allows.
    public static func validPort(_ value: Int) -> UInt16? {
        (1025...65535).contains(value) ? UInt16(value) : nil
    }
}

/// `settings.json` in the config directory: user settings plus remote access.
/// Written atomically, 0600, in a 0700 directory.
@MainActor
public final class HostSettingsStore {
    public let url: URL
    public private(set) var settings: HostSettings
    public private(set) var remote: RemoteSettings
    /// Why the file on disk could not be read, if it could not.
    public private(set) var loadError: String?

    struct Document: Codable {
        var version = 1
        var settings: HostSettings
        var remote: RemoteSettings

        enum CodingKeys: String, CodingKey { case version, groupOverrides, spendGroups, spendThresholds, remote }

        init(settings: HostSettings, remote: RemoteSettings) {
            self.settings = settings
            self.remote = remote
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? nil ?? 1
            settings = try HostSettings(from: decoder)
            remote = ((try? c.decodeIfPresent(RemoteSettings.self, forKey: .remote)) ?? nil) ?? RemoteSettings()
        }

        func encode(to encoder: Encoder) throws {
            try settings.encode(to: encoder)
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(version, forKey: .version)
            try c.encode(remote, forKey: .remote)
        }
    }

    public init(url: URL) {
        self.url = url
        settings = HostSettings()
        remote = RemoteSettings()
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let document = try JSONDecoder().decode(Document.self, from: data)
            settings = document.settings
            remote = document.remote
        } catch {
            loadError = "Could not read \(url.path); using defaults. \(error.localizedDescription)"
        }
    }

    public func update(_ change: (inout HostSettings) -> Void) throws {
        var next = settings
        change(&next)
        next.spendGroups = HostSettings.normalized(next.spendGroups)
        try write(Document(settings: next, remote: remote))
        settings = next
    }

    public func updateRemote(_ change: (inout RemoteSettings) -> Void) throws {
        var next = remote
        change(&next)
        try write(Document(settings: settings, remote: next))
        remote = next
    }

    private func write(_ document: Document) throws {
        let directory = url.deletingLastPathComponent()
        try HostPaths.preparePrivateDirectory(directory.path, tighten: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        loadError = nil
    }
}
