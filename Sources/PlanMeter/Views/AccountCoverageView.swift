import AppKit
import SwiftUI
import PlanMeterCore

struct AccountCoverageCard: View {
    @Environment(AppModel.self) private var model
    var scope: UsageScope?

    static let about = "Account readings come from each Codex login. Workspace USD estimates use the provider's credit conversion and include Work, Codex, and Chat. The token comparison uses a separate account feed whose tokens can't be priced without model details; known thread cost covers local transcripts and dated cloud estimates. Generic account tokens and lifetime thread totals never enter the spend chart. A difference may include undiscovered threads or reporting delays."

    var body: some View {
        let ids = scope.map { Set(model.accounts(in: $0).map(\.id)) }
        let rows = model.coverage.filter { ids == nil || $0.snapshot.target.localAccountId.map { ids!.contains($0) } == true }
        if !rows.isEmpty {
            Card(title: "Codex account readings", info: Self.about) {
                ForEach(rows, id: \.snapshot.id) { row in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.snapshot.target.name).font(.subheadline.bold())
                            Text(row.snapshot.target.email).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if let fetched = row.snapshot.fetchedAt {
                                Text("Fetched \(Format.relative(fetched))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        ForEach(model.readingWarnings(targetId: row.snapshot.target.id), id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        if let daily = model.dailyUsage.first(where: { $0.id == row.snapshot.id }) {
                            CodexDailyUsageView(snapshot: daily)
                        }
                        if let cloud = model.cloudUsage.first(where: { $0.target.id == row.snapshot.id }) {
                            CodexCloudUsageView(snapshot: cloud)
                        }
                        DisclosureGroup {
                            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                                GridRow {
                                    Stat(label: row.missingDays.isEmpty ? "Account tokens" : "Reported account tokens", value: row.accountTokens.map(Format.tokens) ?? "Unavailable")
                                    Stat(label: "Known thread tokens", value: row.knownThreadTokens.map(Format.tokens) ?? "Ambiguous account")
                                    Stat(label: "Difference", value: row.differenceTokens.map { $0 < 0 ? "−" + Format.tokens(-$0) : Format.tokens($0) } ?? "Unavailable")
                                    Stat(label: "Known thread cost", value: row.knownThreadCostUsd.map(Format.usd) ?? "Unavailable")
                                }
                            }
                            .padding(.top, 4)
                            let notes = [
                                row.knownThreads == 0 ? "No threads with dated usage matched this account in these dates." : nil,
                                row.missingDays.isEmpty ? nil : "\(row.missingDays.count) days have no account reading.",
                                row.snapshot.threadUsageMessage, row.snapshot.message,
                            ].compactMap { $0 }
                            if !notes.isEmpty {
                                Text(notes.joined(separator: " ")).font(.caption).foregroundStyle(.secondary)
                            }
                            if let id = row.snapshot.target.localAccountId, (row.knownThreads ?? 0) > 0 {
                                ThreadSpendList(rows: model.coverageThreads(accountId: id), limit: 5)
                            }
                        } label: {
                            Text("Token comparison · last \(model.range.dayCount) UTC \(model.range.dayCount == 1 ? "day" : "days")")
                        }
                        if !row.snapshot.serviceThreads.isEmpty {
                            CodexServiceThreadsView(snapshot: row.snapshot)
                        }
                    }
                    if row.snapshot.id != rows.last?.snapshot.id { Divider() }
                }
            }
        }
    }
}

struct CodexDailyUsageView: View {
    @Environment(AppModel.self) private var model
    var snapshot: CodexDailyUsageSnapshot
    @State private var selectedDate: String?
    @State private var detail: CodexDailyUsageSnapshot?
    @State private var expanded = false
    static let about = "Daily credits include Work, Codex, and Chat. Text tokens cover Work and Codex, with product, reasoning, speed, and surface where available; voice, image, and Chat can add credits without tokens. Provider dates are UTC days. Charts use these readings for the hours the provider has reported, instead of overlapping local estimates. The provider may group smaller models as Other."

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
            let inspection = detail?.fromDay == date && detail?.target == snapshot.target ? detail! : snapshot
            DisclosureGroup(isExpanded: $expanded) {
                if let day = inspection.days.first(where: { $0.date == date }) {
                    HStack {
                        Picker("Inspect day", selection: Binding(get: { date ?? "" }, set: { selectedDate = $0 })) {
                            ForEach(snapshot.days.reversed()) { day in Text(day.date).tag(day.date) }
                        }
                        .frame(maxWidth: 280)
                        Spacer()
                        Text(day.credits.map { "\(credits($0)) credits" } ?? "Credits unavailable").monospacedDigit()
                        Text(day.credits.flatMap { inspection.estimatedCost(credits: $0) }.map { "Est. \(Format.usd($0))" } ?? "USD unavailable")
                            .font(.headline).monospacedDigit()
                    }
                    if let products = day.products {
                        HStack(spacing: 24) {
                            ForEach(products) { product in
                                Stat(label: product.label, value: "\(credits(product.credits)) cr · \(inspection.estimatedCost(credits: product.credits).map(Format.usd) ?? "USD unavailable")")
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
                                    Text("Product")
                                    Text("Model / speed")
                                    Text("Reasoning")
                                    Text("Surface")
                                    Text("Uncached input")
                                    Text("Cached input")
                                    Text("Output")
                                    Text("Credits")
                                }.font(.caption.bold())
                                ForEach(active) { item in
                                    GridRow {
                                        Text(item.product.map { $0 == "work" ? "Work" : ($0 == "codex" ? "Codex" : $0) } ?? "Work / Codex")
                                        Text("\(item.model) · \(item.speed)")
                                        Text(item.reasoningEffort ?? "Unavailable")
                                        Text(item.surface ?? "Unavailable")
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
                                    Text(inspection.estimatedCost(credits: item.credits).map(Format.usd) ?? "USD unavailable")
                                }.font(.caption).monospacedDigit()
                            }
                        }
                    }
                }
                if let message = inspection.message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } label: {
                HStack(spacing: 6) {
                    Text("Workspace usage")
                    InfoButton(text: Self.about, topic: "workspace usage")
                    Spacer()
                    Text(selected.estimatedCostUsd.map(Format.usd) ?? "USD unavailable").monospacedDigit()
                    if let total = selected.credits {
                        Text("\(credits(total)) credits").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    if let freshness = snapshot.dataFreshness.flatMap(Self.freshness) {
                        Text("· through \(freshness)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .task(id: "\(date ?? ""):\(snapshot.fetchedAt?.timeIntervalSince1970 ?? 0)") {
                guard let date else { return }
                detail = await model.inspectWorkspaceDay(target: snapshot.target, date: date)
            }
        }
    }

    private func credits(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...3))) }

    private static func freshness(_ value: String) -> String? {
        guard let date = ISO8601DateFormatter().date(from: value) else { return nil }
        return date.formatted(date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated, time: .shortened)
    }
}

struct CodexServiceThreadsView: View {
    @Environment(AppModel.self) private var model
    var snapshot: AccountUsageSnapshot
    @State private var expanded = false
    @State private var showAll = false
    static let about = "Each total covers a whole thread across all dates, so these never enter daily spend. Service estimates follow billing rules; token-rate estimates value input, cached input, and output at current model rates, excluding speed premiums."

    private var rows: [CodexServiceThreadUsage] {
        snapshot.serviceThreads.sorted {
            if ($0.totalTokens ?? 0) != ($1.totalTokens ?? 0) { return ($0.totalTokens ?? 0) > ($1.totalTokens ?? 0) }
            return $0.id < $1.id
        }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
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
        } label: {
            HStack(spacing: 6) {
                Text("Lifetime thread totals (\(rows.count))")
                InfoButton(text: Self.about, topic: "lifetime thread totals")
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
    var limit = 20
    @State private var showAll = false

    var body: some View {
        if rows.isEmpty {
            Text("No known threads in this range.").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(showAll ? rows : Array(rows.prefix(limit))) { row in
                    ThreadSpendRow(row: row)
                    if row.id != (showAll ? rows : Array(rows.prefix(limit))).last?.id { Divider() }
                }
            }
            if rows.count > limit {
                Button(showAll ? "Show fewer" : "Show all \(rows.count)") { showAll.toggle() }
                    .buttonStyle(.link)
            }
        }
    }
}

/// One line per thread; identifiers and source files are in the context menu.
struct ThreadSpendRow: View {
    @Environment(AppModel.self) private var model
    var row: ThreadSpend

    var body: some View {
        let account = model.account(for: row.accountId)
        HStack(spacing: 10) {
            Circle().fill(model.color(for: account)).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title ?? "\(row.provider.displayName) session \(row.sessionId.prefix(8))").lineLimit(1)
                Text(([account.displayName] + row.models).joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            if row.unpricedTokens > 0 {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
                    .help("Includes tokens without a known price")
            }
            Text(Format.tokens(row.tokens)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                .frame(width: 56, alignment: .trailing)
            Text(Format.usd(row.costUsd)).monospacedDigit().frame(width: 72, alignment: .trailing)
            if let chatURL = row.chatURL, let url = URL(string: chatURL) {
                Link(destination: url) { Image(systemName: "arrow.up.forward.square") }
                    .help("Open chat")
                    .accessibilityLabel("Open chat")
            } else {
                Image(systemName: "arrow.up.forward.square").hidden()
            }
        }
        .font(.callout)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .help(row.chatId.map { "Chat \($0) · Session \(row.sessionId)" } ?? "Session \(row.sessionId)")
        .contextMenu {
            Button("Copy Session ID") { copy(row.sessionId) }
            if let chat = row.chatId { Button("Copy Chat ID") { copy(chat) } }
            ForEach(row.sourcePaths, id: \.self) { path in
                if path.hasPrefix("codex://"), let url = URL(string: path) {
                    Button("Open in Codex") { NSWorkspace.shared.open(url) }
                } else {
                    Button("Show \(URL(fileURLWithPath: path).lastPathComponent) in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                }
            }
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
