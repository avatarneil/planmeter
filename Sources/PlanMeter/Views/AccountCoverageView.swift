import SwiftUI
import PlanMeterCore

struct AccountCoverageCard: View {
    @Environment(AppModel.self) private var model
    var scope: UsageScope?

    var body: some View {
        let ids = scope.map { Set(model.accounts(in: $0).map(\.id)) }
        let rows = model.coverage.filter { ids == nil || $0.snapshot.target.localAccountId.map { ids!.contains($0) } == true }
        if !rows.isEmpty {
            Card(title: "Account-wide Codex usage") {
                Text("Latest \(model.range.dayCount) calendar \(model.range.dayCount == 1 ? "day" : "days") · API dates compared with UTC transcript days")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(rows, id: \.snapshot.id) { row in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(row.snapshot.target.name).font(.subheadline.bold())
                            Text(row.snapshot.target.email).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if let fetched = row.snapshot.fetchedAt {
                                Text("Fetched \(Format.relative(fetched))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                            GridRow {
                                Stat(label: row.missingDays.isEmpty ? "Account tokens" : "Reported account tokens", value: row.accountTokens.map(Format.tokens) ?? "Unavailable")
                                Stat(label: "Known thread tokens", value: row.knownThreadTokens.map(Format.tokens) ?? "Ambiguous account")
                            }
                            GridRow {
                                Stat(label: "Difference", value: row.differenceTokens.map { $0 < 0 ? "−" + Format.tokens(-$0) : Format.tokens($0) } ?? "Unavailable")
                                Stat(label: "Known thread cost", value: row.knownThreadCostUsd.map(Format.usd) ?? "Unavailable")
                            }
                        }
                        if let id = row.snapshot.target.localAccountId {
                            DisclosureGroup("Known threads in this comparison (\(row.knownThreads ?? 0))") {
                                ThreadSpendList(rows: model.coverageThreads(accountId: id))
                            }
                        }
                        if let message = row.snapshot.message {
                            Text(message).font(.caption).foregroundStyle(.secondary)
                        }
                        if !row.missingDays.isEmpty {
                            Text("\(row.missingDays.count) days have no account reading; difference unavailable.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                }
                Text("Account totals are separate from the spend chart. The difference may include other devices, cloud activity, or reporting delays; dots coverage is unverified. Missing activity has no cost estimate.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct ThreadSpendList: View {
    @Environment(AppModel.self) private var model
    var rows: [ThreadSpend]
    @State private var showAll = false

    var body: some View {
        if rows.isEmpty {
            Text("No known threads in this range.").foregroundStyle(.secondary)
        } else {
            ForEach(showAll ? rows : Array(rows.prefix(20))) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(row.title ?? row.sessionId).font(.callout).textSelection(.enabled).lineLimit(1)
                        Spacer()
                        Text(Format.usd(row.costUsd)).monospacedDigit()
                        Text("\(Format.tokens(row.tokens)) tokens").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("\(row.provider.displayName) · \(model.account(for: row.accountId).displayName)")
                        Text(row.models.joined(separator: ", ")).lineLimit(1)
                        Spacer()
                        if row.unpricedTokens > 0 { Text("Includes unpriced tokens") }
                        if let chatURL = row.chatURL, let url = URL(string: chatURL) {
                            Link("Open chat", destination: url)
                        }
                        ForEach(row.sourcePaths, id: \.self) { path in
                            Link("Source", destination: URL(fileURLWithPath: path)).help(path)
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    Text(row.chatId.map { "Chat \($0) · Session \(row.sessionId)" } ?? "Session \(row.sessionId)")
                        .font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Divider()
            }
            if rows.count > 20 {
                Button(showAll ? "Show top 20" : "Show all \(rows.count) threads") { showAll.toggle() }
            }
        }
    }
}
