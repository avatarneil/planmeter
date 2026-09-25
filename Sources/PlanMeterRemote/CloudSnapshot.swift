import CryptoKit
import Foundation

/// A bounded, versioned set of aggregate reports. Never includes source files or credentials.
public struct CloudSnapshot: Codable, Sendable, Equatable, Identifiable {
    public static let supportedDays = [1, 7, 30, 90]
    public var version = 1
    public var id: String
    public var name: String
    public var generatedAt: Date
    public var reports: [RemoteReply]

    public init(id: String, name: String, generatedAt: Date, reports: [RemoteReply]) {
        self.id = id
        self.name = name
        self.generatedAt = generatedAt
        self.reports = reports.map(Self.sanitized)
    }

    public func report(days: Int) throws -> RemoteReply {
        guard version == 1 else { throw CloudSyncError.unsupportedVersion }
        guard let report = reports.first(where: { $0.summary?.days == days }),
              report.summary != nil, report.timeline != nil, report.limits != nil, report.models != nil else {
            throw CloudSyncError.incompleteSnapshot
        }
        return report
    }

    private static func sanitized(_ input: RemoteReply) -> RemoteReply {
        // Attribution IDs can contain local home-directory paths. Hash them consistently
        // across every report so charts retain their joins without uploading those paths.
        func identifier(_ id: String) -> String { SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined() }
        func account(_ input: RemoteAccount) -> RemoteAccount {
            var value = input
            value.id = identifier(value.id)
            value.email = nil
            return value
        }
        var value = input
        value.accounts = nil
        value.error = nil
        if var summary = value.summary {
            summary.groups = summary.groups.map { group in
                var group = group
                group.accounts = group.accounts.map { usage in
                    var usage = usage
                    usage.account = account(usage.account)
                    return usage
                }
                return group
            }
            value.summary = summary
        }
        if var timeline = value.timeline {
            timeline.accounts = timeline.accounts.map(account)
            timeline.points = timeline.points.map { point in
                var point = point
                point.accountId = identifier(point.accountId)
                return point
            }
            value.timeline = timeline
        }
        value.models = value.models?.map { row in
            var row = row
            row.accountId = identifier(row.accountId)
            return row
        }
        if var limits = value.limits {
            limits.accounts = limits.accounts.map { row in
                var row = row
                row.account = account(row.account)
                return row
            }
            value.limits = limits
        }
        return value
    }
}

public enum CloudSyncError: LocalizedError {
    case unavailable, signedOut, unsupportedVersion, incompleteSnapshot
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "iCloud requires a provisioned PlanMeter build with the iCloud capability."
        case .signedOut: return "Sign in to iCloud in System Settings on your Mac and Settings on your iPhone using the same Apple Account."
        case .unsupportedVersion: return "This iCloud snapshot needs a newer version of PlanMeter."
        case .incompleteSnapshot: return "The iCloud snapshot is incomplete. Refresh PlanMeter on your Mac."
        }
    }
}
