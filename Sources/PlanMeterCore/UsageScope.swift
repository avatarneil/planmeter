import Foundation

/// Stable identities keep similarly named accounts separate during drill-down.
public enum UsageScope: Hashable, Identifiable {
    case account(String)
    case provider(ProviderKind)
    case group(PlanGroup)

    public var id: String {
        switch self {
        case .account(let id): return "account:\(id)"
        case .provider(let provider): return "provider:\(provider.rawValue)"
        case .group(let group): return "group:\(group.rawValue)"
        }
    }

    public func includes(_ account: Account, group: PlanGroup) -> Bool {
        switch self {
        case .account(let id): return account.id == id
        case .provider(let provider): return account.provider == provider
        case .group(let selected): return group == selected
        }
    }
}
