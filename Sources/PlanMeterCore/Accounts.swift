import CryptoKit
import Foundation

/// A transcript directory to scan, already attributed where the directory alone
/// decides the account (Claude, Grok, Antigravity). Codex is attributed per record instead.
public struct ScanSource: Hashable, Sendable {
    public var provider: ProviderKind
    public var rootDir: String
    /// Restrict the walk to one basename (Grok's `updates.jsonl`).
    public var fileName: String?
    /// Fixed attribution for every record under this root, or nil to use the
    /// record's own plan type (Codex).
    public var fixedAccountId: String?

    public init(provider: ProviderKind, rootDir: String, fileName: String? = nil, fixedAccountId: String? = nil) {
        self.provider = provider
        self.rootDir = rootDir
        self.fileName = fileName
        self.fixedAccountId = fixedAccountId
    }
}

public struct UnsupportedInstance: Hashable, Sendable, Identifiable {
    public var id: String
    public var driver: String
    public var displayName: String
    public var reason: String
}

public struct Discovery: Sendable {
    public var accounts: [Account]
    public var sources: [ScanSource]
    public var openCodeDatabase: String?
    public var unsupported: [UnsupportedInstance]
    public var notes: [String]
    public var codexUsageTargets: [CodexUsageTarget] = []
    public var planLimitTargets: [PlanLimitTarget] = []

    public init(accounts: [Account] = [], sources: [ScanSource] = [], openCodeDatabase: String? = nil, unsupported: [UnsupportedInstance] = [], notes: [String] = []) {
        self.accounts = accounts
        self.sources = sources
        self.openCodeDatabase = openCodeDatabase
        self.unsupported = unsupported
        self.notes = notes
    }
}

/// Discovers billable accounts and the on-disk places their usage lands.
/// T3 Code provider instances take precedence when available; otherwise the
/// conventional provider homes (and their environment overrides) are used.
public enum AccountDiscovery {
    public static func discover(settings: T3Settings?, environment: [String: String] = ProcessInfo.processInfo.environment) -> Discovery {
        var result = Discovery()
        let home = PlanMeterPaths.homeDirectory(environment: environment)
        let instances = settings?.instances ?? []
        let usesT3Configuration = !instances.isEmpty

        if usesT3Configuration, let path = settings?.settingsPath.path {
            result.notes.append("Using T3 Code provider instances from \(path).")
        } else {
            result.notes.append("Using standard provider homes; T3 Code is not required.")
        }

        // Codex ---------------------------------------------------------
        var codexAccountsByPlan: [String: Account] = [:]
        var codexSharedHomes: [String] = []
        let codexInstances = instances.filter { $0.driver == "codex" && $0.enabled }
        let codexCandidates: [T3ProviderInstance] = codexInstances.isEmpty && !usesT3Configuration
            ? [T3ProviderInstance(id: "codex", driver: "codex")]
            : codexInstances
        for instance in codexCandidates {
            // A process launched from inside a Codex provider can inherit that
            // provider's CODEX_HOME. It is only a valid fallback when there is
            // no T3 configuration; otherwise it makes every configured Codex
            // instance look like the account that launched PlanMeter.
            let environmentHome = !usesT3Configuration ? environment["CODEX_HOME"].flatMap(nonEmptyPath) : nil
            let shared = instance.homePath.map(PathUtil.expand) ?? environmentHome ?? "\(home)/.codex"
            let effective = URL(fileURLWithPath: instance.shadowHomePath.map(PathUtil.expand) ?? shared).standardizedFileURL.path
            let transcriptHome = URL(fileURLWithPath: shared).resolvingSymlinksInPath().path
            if !codexSharedHomes.contains(transcriptHome) { codexSharedHomes.append(transcriptHome) }

            let identity = CodexIdentity.read(homePath: effective)
            let plan = identity.planType ?? "unknown"
            let id = Account.codexId(planType: plan)
            let name = instance.displayName ?? (instance.isDefaultForDriver ? "Codex" : instance.id)
            if let email = identity.email, let serviceId = identity.accountId, plan != "api", plan != "unknown" {
                let targetId = "\(serviceId):\(email.lowercased())"
                if !result.codexUsageTargets.contains(where: { $0.id == targetId }) {
                    result.codexUsageTargets.append(CodexUsageTarget(id: targetId, name: name, home: effective,
                        email: email, plan: plan, serviceAccountId: serviceId, localAccountId: id))
                }
            }
            if var existing = codexAccountsByPlan[id] {
                // Two logins on the same plan type cannot be told apart in the
                // transcripts, so they share one account.
                existing.displayName += " / \(name)"
                existing.sourceDescription += "; \(effective)/auth.json"
                codexAccountsByPlan[id] = existing
                result.notes.append("Codex instances \(existing.displayName) share plan type \(plan) and are shown as one account.")
            } else {
                codexAccountsByPlan[id] = Account(
                    id: id,
                    provider: .codex,
                    displayName: name,
                    email: identity.email,
                    planLabel: CodexIdentity.planLabel(plan),
                    organization: nil,
                    accentColorHex: instance.accentColorHex,
                    suggestedGroup: GroupHeuristics.suggest(displayName: name, email: identity.email, plan: plan),
                    sourceDescription: "\(shared)/sessions, attributed by plan type \"\(plan)\" from \(effective)/auth.json"
                )
            }
        }
        result.accounts.append(contentsOf: codexAccountsByPlan.values.sorted { $0.displayName < $1.displayName })
        let ambiguousPlans = Dictionary(grouping: result.codexUsageTargets, by: \.plan).filter { $0.value.count > 1 }.keys
        for index in result.codexUsageTargets.indices where ambiguousPlans.contains(result.codexUsageTargets[index].plan) {
            result.codexUsageTargets[index].localAccountId = nil
        }
        var transcriptRoots: Set<String> = []
        for shared in codexSharedHomes {
            for directory in ["sessions", "archived_sessions"] {
                let root = URL(fileURLWithPath: "\(shared)/\(directory)").resolvingSymlinksInPath().path
                if transcriptRoots.insert(root).inserted {
                    result.sources.append(ScanSource(provider: .codex, rootDir: root))
                }
            }
        }

        // Claude Code ---------------------------------------------------
        let claudeInstances = instances.filter { $0.driver == "claudeAgent" && $0.enabled }
        let standaloneClaudeHome = environment["CLAUDE_CONFIG_DIR"].flatMap(nonEmptyPath)
        let claudeCandidates: [T3ProviderInstance] = claudeInstances.isEmpty && !usesT3Configuration
            ? [T3ProviderInstance(id: "claudeAgent", driver: "claudeAgent", homePath: standaloneClaudeHome)]
            : claudeInstances
        var seenClaudeDirs: Set<String> = []
        for instance in claudeCandidates {
            let claudeHome = instance.homePath.map(PathUtil.expand) ?? home
            // A custom home used as CLAUDE_CONFIG_DIR writes transcripts to
            // `<home>/projects`; one used as HOME nests them under `.claude`.
            // Both can exist for the same login, so scan whichever are present.
            // The default user home is unambiguous: never mistake a generic
            // `~/projects` directory for Claude's transcript store.
            let possibleDirs = instance.homePath == nil
                ? ["\(home)/.claude/projects"]
                : ["\(claudeHome)/projects", "\(claudeHome)/.claude/projects"]
            let candidates = possibleDirs
                .filter { PathUtil.isDirectory($0) && !seenClaudeDirs.contains($0) }
            let dirs = candidates.isEmpty ? [possibleDirs[0]] : candidates
            guard !dirs.allSatisfy(seenClaudeDirs.contains) else { continue }
            seenClaudeDirs.formUnion(dirs)

            let identity = ClaudeIdentity.read(homePath: claudeHome)
            let name = instance.displayName ?? (instance.isDefaultForDriver ? "Claude Code" : instance.id)
            let id = Account.claudeId(transcriptDir: dirs[0])
            result.accounts.append(Account(
                id: id,
                provider: .claude,
                displayName: name,
                email: identity.email,
                planLabel: identity.planLabel,
                organization: identity.organizationName,
                accentColorHex: instance.accentColorHex,
                suggestedGroup: GroupHeuristics.suggest(displayName: name, email: identity.email, plan: identity.organizationType),
                sourceDescription: dirs.joined(separator: "; ")
            ))
            for dir in dirs {
                result.sources.append(ScanSource(provider: .claude, rootDir: dir, fixedAccountId: id))
            }
            // T3's `homePath` is the instance's CLAUDE_CONFIG_DIR.
            result.planLimitTargets.append(PlanLimitTarget(
                accountId: id, provider: .claude, configDir: instance.homePath.map(PathUtil.expand), email: identity.email))
        }

        // Antigravity ---------------------------------------------------
        let antigravityInstances = instances.filter { $0.driver == "antigravity" && $0.enabled }
        var seenAntigravityDirs: Set<String> = []
        if usesT3Configuration {
            let stateDir = settings?.settingsPath.deletingLastPathComponent().path
                ?? T3Settings.defaultHome().appendingPathComponent("userdata").path
            for instance in antigravityInstances {
                let acpDir = instance.homePath.map(PathUtil.expand)
                    ?? "\(stateDir)/providers/antigravity/\(AntigravityIdentity.sha256Hex(instance.id))/antigravity-acp"
                let conversationsDir = AntigravityIdentity.resolveConversationsDir(root: acpDir)
                let normalizedDir = URL(fileURLWithPath: conversationsDir).standardizedFileURL.path
                guard seenAntigravityDirs.insert(normalizedDir).inserted else { continue }

                let profileDir = normalizedDir.hasSuffix("/conversations")
                    ? URL(fileURLWithPath: normalizedDir).deletingLastPathComponent().path
                    : acpDir
                let identity = AntigravityIdentity.read(
                    profileDir: profileDir,
                    fallbackAuthMethod: instance.authMethod,
                    fallbackGcpProject: instance.gcpProject,
                    includeGlobalGoogleAccounts: false
                )
                let name = instance.displayName ?? (instance.isDefaultForDriver ? "Antigravity" : instance.id)
                let id = Account.antigravityId(conversationsDir: normalizedDir)
                result.accounts.append(Account(
                    id: id,
                    provider: .antigravity,
                    displayName: name,
                    email: identity.email,
                    planLabel: identity.planLabel,
                    organization: identity.gcpProject,
                    accentColorHex: instance.accentColorHex,
                    suggestedGroup: GroupHeuristics.suggest(displayName: name, email: identity.email, plan: identity.authType),
                    sourceDescription: normalizedDir
                ))
                result.sources.append(ScanSource(provider: .antigravity, rootDir: normalizedDir, fixedAccountId: id))
                result.planLimitTargets.append(PlanLimitTarget(
                    accountId: id, provider: .antigravity, tokenPath: "\(profileDir)/acp_token.json", authMethod: identity.authType))
            }
        } else {
            let envDirs = (environment["ANTIGRAVITY_DATA_DIR"] ?? "")
                .split(separator: ",")
                .compactMap { nonEmptyPath(String($0)) }
            let dirs: [String]
            if !envDirs.isEmpty {
                dirs = envDirs.map { AntigravityIdentity.resolveConversationsDir(root: $0, preferDirectWhenNoSubdir: true) }
            } else {
                let candidateRoots = [
                    "\(home)/.gemini/antigravity",
                    "\(home)/.gemini/antigravity-cli",
                    "\(home)/.gemini/antigravity-ide",
                    "\(home)/.gemini/antigravity-backup",
                    "\(home)/.config/antigravity",
                ]
                let existing = candidateRoots
                    .map { "\($0)/conversations" }
                    .filter { PathUtil.isDirectory($0) }
                dirs = existing.isEmpty ? ["\(home)/.gemini/antigravity/conversations"] : existing
            }
            let uniqueDirs = dirs.filter { seenAntigravityDirs.insert(URL(fileURLWithPath: $0).standardizedFileURL.path).inserted }
            if let primaryDir = uniqueDirs.first {
                let profileDir = primaryDir.hasSuffix("/conversations")
                    ? URL(fileURLWithPath: primaryDir).deletingLastPathComponent().path
                    : primaryDir
                let identity = AntigravityIdentity.read(
                    profileDir: profileDir,
                    fallbackAuthMethod: nil,
                    fallbackGcpProject: nil,
                    includeGlobalGoogleAccounts: true,
                    home: home
                )
                let name = "Antigravity"
                let id = Account.antigravityId(conversationsDir: primaryDir)
                result.accounts.append(Account(
                    id: id,
                    provider: .antigravity,
                    displayName: name,
                    email: identity.email,
                    planLabel: identity.planLabel,
                    organization: identity.gcpProject,
                    accentColorHex: nil,
                    suggestedGroup: GroupHeuristics.suggest(displayName: name, email: identity.email, plan: identity.authType),
                    sourceDescription: uniqueDirs.joined(separator: "; ")
                ))
                for dir in uniqueDirs {
                    result.sources.append(ScanSource(provider: .antigravity, rootDir: dir, fixedAccountId: id))
                }
                result.planLimitTargets.append(PlanLimitTarget(
                    accountId: id, provider: .antigravity, tokenPath: "\(profileDir)/acp_token.json", authMethod: identity.authType))
            }
        }

        // Grok Build ----------------------------------------------------
        let grok = instances.first(where: { $0.driver == "grok" && $0.enabled })
            ?? (!usesT3Configuration ? T3ProviderInstance(id: "grok", driver: "grok") : nil)
        if let grok {
            let grokHome = environment["GROK_HOME"].flatMap(nonEmptyPath) ?? "\(home)/.grok"
            let name = grok.displayName ?? "Grok Build"
            result.accounts.append(Account(
                id: Account.grokDefaultId,
                provider: .grok,
                displayName: name,
                accentColorHex: grok.accentColorHex,
                suggestedGroup: GroupHeuristics.suggest(displayName: name, email: nil, plan: nil),
                sourceDescription: "\(grokHome)/sessions"
            ))
            result.sources.append(ScanSource(provider: .grok, rootDir: "\(grokHome)/sessions", fileName: "updates.jsonl", fixedAccountId: Account.grokDefaultId))
        }

        // OpenCode ------------------------------------------------------
        let opencode = instances.first(where: { $0.driver == "opencode" && $0.enabled })
            ?? (!usesT3Configuration ? T3ProviderInstance(id: "opencode", driver: "opencode") : nil)
        if let opencode {
            let dataHome = environment["XDG_DATA_HOME"].flatMap(nonEmptyPath) ?? "\(home)/.local/share"
            let db = "\(dataHome)/opencode/opencode.db"
            let name = opencode.displayName ?? "OpenCode"
            result.accounts.append(Account(
                id: Account.openCodeLocalId,
                provider: .opencode,
                displayName: name,
                planLabel: "local",
                accentColorHex: opencode.accentColorHex,
                suggestedGroup: GroupHeuristics.suggest(displayName: name, email: nil, plan: nil),
                sourceDescription: db
            ))
            result.openCodeDatabase = db
        }

        // Everything else -----------------------------------------------
        for instance in instances where !["codex", "claudeAgent", "antigravity", "grok", "opencode"].contains(instance.driver) {
            result.unsupported.append(UnsupportedInstance(
                id: instance.id,
                driver: instance.driver,
                displayName: instance.displayName ?? instance.id,
                reason: instance.enabled ? "No local usage data for this provider." : "Disabled in T3 Code."
            ))
        }
        return result
    }

    private static func nonEmptyPath(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : PathUtil.expand(trimmed)
    }
}

public struct CodexIdentity: Sendable {
    public var email: String?
    public var planType: String?
    public var accountId: String?
    public var userId: String?

    public static func read(homePath: String) -> CodexIdentity {
        let url = URL(fileURLWithPath: "\(homePath)/auth.json")
        guard let data = try? Data(contentsOf: url), let root = JSON.object(data) else { return CodexIdentity() }
        return decode(root)
    }

    static func decode(_ root: [String: Any]) -> CodexIdentity {
        let authMode = JSON.string(root["auth_mode"])
        guard let tokens = JSON.object(root["tokens"]) else {
            if authMode == "apikey" || JSON.string(root["OPENAI_API_KEY"]) != nil {
                return CodexIdentity(email: nil, planType: "api", accountId: nil)
            }
            return CodexIdentity()
        }
        var identity = CodexIdentity()
        for key in ["id_token", "access_token"] {
            guard let token = JSON.string(tokens[key]), let claims = JWT.payload(token) else { continue }
            if identity.email == nil { identity.email = JSON.string(claims["email"]) }
            if let auth = JSON.object(claims["https://api.openai.com/auth"]) {
                if identity.planType == nil { identity.planType = JSON.string(auth["chatgpt_plan_type"]) }
                if identity.accountId == nil { identity.accountId = JSON.string(auth["chatgpt_account_id"]) }
                if identity.userId == nil { identity.userId = JSON.string(auth["chatgpt_user_id"]) }
            }
        }
        if identity.planType == nil, authMode == "apikey" { identity.planType = "api" }
        return identity
    }

    public static func planLabel(_ plan: String) -> String {
        switch plan {
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        case "pro": return "Pro"
        case "plus": return "Plus"
        case "team": return "Team"
        case "edu": return "Edu"
        case "free": return "Free"
        case "api": return "API key"
        case "unknown": return "Unknown plan"
        default: return plan.capitalized
        }
    }
}

public struct ClaudeIdentity: Sendable {
    public var email: String?
    public var organizationType: String?
    public var organizationName: String?

    public var planLabel: String? {
        guard let type = organizationType else { return nil }
        switch type {
        case "claude_enterprise": return "Enterprise"
        case "claude_team": return "Team"
        case "claude_max": return "Max"
        case "claude_pro": return "Pro"
        case "claude_free": return "Free"
        default: return type.replacingOccurrences(of: "claude_", with: "").capitalized
        }
    }

    public static func read(homePath: String) -> ClaudeIdentity {
        let url = URL(fileURLWithPath: "\(homePath)/.claude.json")
        guard let data = try? Data(contentsOf: url), let root = JSON.object(data), let account = JSON.object(root["oauthAccount"]) else {
            return ClaudeIdentity()
        }
        return ClaudeIdentity(
            email: JSON.string(account["emailAddress"]),
            organizationType: JSON.string(account["organizationType"]),
            organizationName: JSON.string(account["organizationName"])
        )
    }
}

public struct AntigravityIdentity: Sendable {
    public var email: String?
    public var authType: String?
    public var gcpProject: String?

    public var planLabel: String? {
        guard let authType else { return nil }
        switch authType {
        case "oauth-personal": return nil
        case "oauth-business": return "Enterprise"
        case "gemini-api-key": return "API key"
        case "agent-platform": return "Vertex AI"
        default: return authType
        }
    }

    public static func sha256Hex(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func resolveConversationsDir(root: String, preferDirectWhenNoSubdir: Bool = false) -> String {
        if root.hasSuffix("/conversations") { return root }
        let sub = "\(root)/conversations"
        if PathUtil.isDirectory(sub) { return sub }
        if preferDirectWhenNoSubdir && PathUtil.isDirectory(root) { return root }
        return sub
    }

    public static func read(
        profileDir: String,
        fallbackAuthMethod: String?,
        fallbackGcpProject: String?,
        includeGlobalGoogleAccounts: Bool,
        home: String = NSHomeDirectory()
    ) -> AntigravityIdentity {
        var authType = fallbackAuthMethod
        var gcpProject = fallbackGcpProject
        var email: String?

        let settingsURL = URL(fileURLWithPath: "\(profileDir)/settings.json")
        if let data = try? Data(contentsOf: settingsURL), let root = JSON.object(data) {
            if let auth = JSON.object(root["auth"]), let type = JSON.string(auth["type"]) {
                authType = type
            }
            if let gcp = JSON.object(root["gcp"]), let project = JSON.string(gcp["project"]) {
                gcpProject = project
            }
        }

        var accountPaths = ["\(profileDir)/google_accounts.json"]
        if includeGlobalGoogleAccounts {
            accountPaths.append("\(home)/.gemini/google_accounts.json")
        }
        for path in accountPaths where email == nil {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               let root = JSON.object(data),
               let active = JSON.string(root["active"]) {
                email = active
            }
        }

        return AntigravityIdentity(email: email, authType: authType, gcpProject: gcpProject)
    }
}

public enum GroupHeuristics {
    static let personalDomains: Set<String> = [
        "gmail.com", "googlemail.com", "icloud.com", "me.com", "mac.com", "outlook.com", "hotmail.com",
        "live.com", "yahoo.com", "proton.me", "protonmail.com", "hey.com", "fastmail.com", "pm.me",
    ]

    public static func suggest(displayName: String, email: String?, plan: String?) -> PlanGroup {
        let lower = displayName.lowercased()
        if lower.contains("personal") || lower.contains("home") || lower.contains("hobby") { return .personal }
        if lower.contains("work") || lower.contains("corp") || lower.contains("company") { return .work }
        if let email, let at = email.lastIndex(of: "@") {
            let domain = String(email[email.index(after: at)...]).lowercased()
            return personalDomains.contains(domain) ? .personal : .work
        }
        switch plan?.lowercased() {
        case "business", "enterprise", "team", "claude_enterprise", "claude_team", "oauth-business", "agent-platform": return .work
        case "pro", "plus", "free", "claude_max", "claude_pro", "claude_free", "oauth-personal": return .personal
        default: return .other
        }
    }
}
