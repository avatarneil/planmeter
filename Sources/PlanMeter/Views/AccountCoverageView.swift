import SwiftUI
import PlanMeterCore

struct AccountCoverageCard: View {
    @Environment(AppModel.self) private var model
    var scope: UsageScope?

    var body: some View {
        let ids = scope.map { Set(model.accounts(in: $0).map(\.id)) }
        let rows = model.coverage.filter { ids == nil || $0.snapshot.target.localAccountId.map { ids!.contains($0) } == true }
        if !rows.isEmpty {
            Card(title: "Codex and workspace usage") {
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
                        if let daily = model.dailyUsage.first(where: { $0.id == row.snapshot.id }) {
                            CodexDailyUsageView(snapshot: daily)
                            Divider()
                        }
                        Text("Codex token comparison").font(.caption.bold())
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
                        if row.knownThreads == 0 {
                            Text("No local threads matched this account in the comparison dates; known thread cost is unavailable.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if !row.snapshot.serviceThreads.isEmpty {
                            CodexServiceThreadsView(snapshot: row.snapshot)
                        }
                        if let message = row.snapshot.threadUsageMessage {
                            Text(message).font(.caption).foregroundStyle(.secondary)
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
                Text("Workspace USD estimates use the provider's credit conversion. The Codex token comparison uses a separate account feed; those tokens cannot be priced without model details. Known thread cost covers matched local transcripts in the comparison dates.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Account totals are separate from the spend chart. The difference may include other devices, cloud activity, or reporting delays. Thread readings are never added to daily transcript spend.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct CodexDailyUsageView: View {
    @Environment(AppModel.self) private var model
    var snapshot: CodexDailyUsageSnapshot
    @State private var selectedDate: String?
    @State private var expanded = true

    private var date: String? {
        if let selectedDate, snapshot.days.contains(where: { $0.date == selectedDate }) { return selectedDate }
        let today = snapshot.selected(days: 1).fromDay
        return snapshot.days.last(where: { $0.date < today && $0.products != nil })?.date ?? snapshot.days.last?.date
    }

    var body: some View {
        if snapshot.fetchedAt == nil {
            Text(snapshot.message ?? "Dated workspace analytics unavailable.").font(.caption).foregroundStyle(.secondary)
        } else {
            let selected = snapshot.selected(days: model.range.dayCount)
            DisclosureGroup("Dated workspace usage — Work, Codex, Chat", isExpanded: $expanded) {
                HStack(spacing: 24) {
                    Stat(label: "Reported range credits", value: selected.credits.map(credits) ?? "Unavailable")
                    Stat(label: "Range service estimate", value: selected.estimatedCostUsd.map(Format.usd) ?? "Unavailable")
                    Spacer()
                }
                Text("\(selected.fromDay) through \(selected.toDay) · Provider calendar dates · \(selected.missingCreditDays.count) dates without credit readings")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let day = snapshot.days.first(where: { $0.date == date }) {
                    HStack {
                        Picker("Inspect day", selection: Binding(get: { date ?? "" }, set: { selectedDate = $0 })) {
                            ForEach(snapshot.days.reversed()) { day in Text(day.date).tag(day.date) }
                        }
                        .frame(maxWidth: 280)
                        Spacer()
                        Text(day.credits.map { "\(credits($0)) credits" } ?? "Credits unavailable").monospacedDigit()
                        Text(day.credits.flatMap { snapshot.estimatedCost(credits: $0) }.map { "Est. \(Format.usd($0))" } ?? "USD unavailable")
                            .font(.headline).monospacedDigit()
                    }
                    if let products = day.products {
                        HStack(spacing: 24) {
                            ForEach(products) { product in
                                Stat(label: product.label, value: "\(credits(product.credits)) cr · \(snapshot.estimatedCost(credits: product.credits).map(Format.usd) ?? "USD unavailable")")
                            }
                            Spacer()
                        }
                    }
                    if let tokens = day.textModels {
                        let active = tokens.filter { $0.totalTokens > 0 || $0.credits > 0 }.sorted { $0.credits > $1.credits }
                        Text("Work and Codex text tokens — \(day.date)").font(.caption.bold())
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ScrollView(.horizontal) {
                            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                                GridRow {
                                    Text("Model / speed")
                                    Text("Uncached input")
                                    Text("Cached input")
                                    Text("Output")
                                    Text("Credits")
                                }.font(.caption.bold())
                                ForEach(active) { item in
                                    GridRow {
                                        Text("\(item.model) · \(item.speed)")
                                        Text(item.uncachedInputTokens.formatted())
                                        Text(item.cachedInputTokens.formatted())
                                        Text(item.outputTokens.formatted())
                                        Text(credits(item.credits))
                                    }.font(.caption).monospacedDigit()
                                }
                            }.textSelection(.enabled)
                        }
                        if active.isEmpty { Text("No text-model usage reported.").font(.caption).foregroundStyle(.secondary) }
                    } else {
                        Text("Text-model I/O unavailable for this day.").font(.caption).foregroundStyle(.secondary)
                    }
                    if let models = day.modelCredits {
                        let active = models.filter { $0.credits > 0 }.sorted { $0.credits > $1.credits }
                        DisclosureGroup("All model credits, including voice and image (\(active.count))") {
                            ForEach(active) { item in
                                HStack {
                                    Text(item.label)
                                    Spacer()
                                    Text("\(credits(item.credits)) credits")
                                    Text(snapshot.estimatedCost(credits: item.credits).map(Format.usd) ?? "USD unavailable")
                                }.font(.caption).monospacedDigit()
                            }
                        }
                    }
                }
                Text("Daily credit totals include all three products. The text-token feed covers Work and Codex; voice, image, and Chat can add credits without text-token counts. These readings are separate from local API-equivalent spend and lifetime thread totals.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let freshness = snapshot.dataFreshness {
                    Text("Provider data through \(freshness)").font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let message = snapshot.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private func credits(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...3))) }
}

struct CodexServiceThreadsView: View {
    @Environment(AppModel.self) private var model
    var snapshot: AccountUsageSnapshot
    @State private var expanded = true
    @State private var showAll = false

    private var rows: [CodexServiceThreadUsage] {
        snapshot.serviceThreads.sorted {
            if ($0.totalTokens ?? 0) != ($1.totalTokens ?? 0) { return ($0.totalTokens ?? 0) > ($1.totalTokens ?? 0) }
            return $0.id < $1.id
        }
    }

    var body: some View {
        DisclosureGroup("Cloud and billed thread details — lifetime (\(rows.count))", isExpanded: $expanded) {
            Text("These totals cover each whole thread, across all dates. Service estimates reflect billing rules; standard token-rate estimates value input, cached input, and output at the current model rates, excluding speed premiums.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(showAll ? rows : Array(rows.prefix(5))) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(row.reference.title ?? row.id).font(.callout.bold()).lineLimit(1).textSelection(.enabled)
                        Spacer()
                        Text(row.totalTokens.map { "\(Format.tokens($0)) tokens" } ?? "Tokens unavailable")
                            .font(.callout).monospacedDigit()
                        if let url = URL(string: "codex://threads/\(row.id)") {
                            Link("Open chat", destination: url)
                        }
                    }
                    HStack {
                        Text(threadKind(row.reference))
                        Text("Service estimate \(row.serviceCostUsd.map(Format.usd) ?? "unavailable")")
                        Text("\((Double(row.estimatedUsageCreditsMicros) / 1_000_000).formatted(.number.precision(.fractionLength(0...2)))) credits")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    Text("Standard token-rate estimate \(row.tokenRateCost(rates: model.rates).map(Format.usd) ?? "unavailable")")
                        .font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("Model and token breakdown (\(row.groups.count))") {
                        ForEach(Array(row.groups.enumerated()), id: \.offset) { _, group in
                            VStack(alignment: .leading, spacing: 3) {
                                Text([group.model ?? "Unknown model", group.reasoningEffort, group.speed].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption.bold())
                                Text("Input \(count(group.inputTokens)) · Cached input \(count(group.cachedInputTokens)) · Output \(count(group.outputTokens))")
                                    .font(.caption).textSelection(.enabled)
                                Text("Standard token-rate estimate \(group.tokenRateCost(rates: model.rates).map(Format.usd) ?? "unavailable")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if let parent = row.reference.parentThreadId, let url = URL(string: "codex://threads/\(parent)") {
                            let name = snapshot.serviceThreads.first { $0.id == parent }?.reference.title ?? parent
                            Link("Parent dot: \(name)", destination: url)
                                .font(.caption).lineLimit(1)
                        }
                        Text("Thread \(row.id)").font(.caption2.monospaced()).textSelection(.enabled)
                    }
                }
                Divider()
            }
            if rows.count > 5 {
                Button(showAll ? "Show top 5" : "Show all \(rows.count) detailed threads") { showAll.toggle() }
            }
        }
    }

    private func count(_ value: Int?) -> String { value.map { $0.formatted() } ?? "unavailable" }
    private func threadKind(_ ref: CodexThreadReference) -> String {
        switch ref.kind {
        case "aeon": return "Cloud dot"
        case "aeon_child": return "Cloud task"
        case "dreaming": return "Cloud background thread"
        default: return ref.origin == "cloud" ? "Cloud thread" : "Local thread"
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
