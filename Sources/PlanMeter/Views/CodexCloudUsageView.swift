import SwiftUI
import PlanMeterCore

struct CodexCloudUsageView: View {
    @Environment(AppModel.self) private var model
    var snapshot: CodexCloudUsageSnapshot

    var body: some View {
        let window = Report.window(days: model.range.dayCount, calendar: UsageCoverage.utcCalendar)
        let turns = snapshot.turns.filter {
            let date = $0.completedAt ?? $0.startedAt
            return date >= window.from && date < window.to
        }.sorted { ($0.completedAt ?? $0.startedAt) > ($1.completedAt ?? $1.startedAt) }
        let measured = turns.filter { $0.totals != nil }
        DisclosureGroup("Cloud turns — \(measured.count) usage readings / \(turns.count) discovered") {
            if !turns.isEmpty {
                ScrollView(.horizontal) {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                        GridRow {
                            Text("Thread / turn")
                            Text("Completed / started")
                            Text("Model")
                            Text("Uncached input")
                            Text("Cached input")
                            Text("Output")
                            Text("Service estimate")
                        }.font(.caption.bold())
                        ForEach(turns) { turn in
                            GridRow {
                                VStack(alignment: .leading) {
                                    Text(turn.reference.title ?? String(turn.reference.id.prefix(8)))
                                    Text(String(turn.turnId.prefix(8))).foregroundStyle(.secondary)
                                }
                                Text((turn.completedAt ?? turn.startedAt).formatted(date: .abbreviated, time: .shortened))
                                Text(turn.model ?? "Unavailable")
                                Text(turn.totals?.uncachedInput.formatted() ?? "Unavailable")
                                Text(turn.totals?.cachedInput.formatted() ?? "Unavailable")
                                Text(turn.totals?.output.formatted() ?? "Unavailable")
                                Text(turn.serviceCostUsd.map(Format.usd) ?? "Unavailable")
                            }.font(.caption).monospacedDigit()
                        }
                    }.textSelection(.enabled)
                }
            }
            Text("Cloud usage uses ordinary Codex login. Turn totals enter charts at completion time (start time if incomplete); individual response times are unavailable. Local rollouts take precedence for matching thread IDs. Discovery is bounded and may be incomplete.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if let message = snapshot.message {
            Text(message).font(.caption).foregroundStyle(.secondary)
        }
        if !snapshot.quotas.isEmpty {
            DisclosureGroup("Current cloud thread allowance usage (\(snapshot.quotas.count))") {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    GridRow {
                        Text("Thread")
                        Text("Weekly allowance used")
                        Text("5-hour allowance used")
                        Text("Reported purchased credits used")
                        Text("Status / source")
                    }.font(.caption.bold())
                    ForEach(snapshot.quotas, id: \.threadId) { quota in
                        GridRow {
                            Text(snapshot.turns.first(where: { $0.reference.id == quota.threadId })?.reference.title ?? String(quota.threadId.prefix(8)))
                            Text(percent(quota.weeklyLimitPercent))
                            Text(percent(quota.fiveHourLimitPercent))
                            Text(reportedCredits(quota))
                            Text([quota.dataStatus, quota.usageSource].compactMap { $0 }.joined(separator: " / "))
                        }.font(.caption).monospacedDigit()
                    }
                }.textSelection(.enabled)
                Text("Allowance percentages and purchased-credit usage use separate units. Neither provides an input/output token count or dollar charge.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func percent(_ value: Double?) -> String {
        value.map { String(format: "%.4g%%", $0) } ?? "Unavailable"
    }

    private func reportedCredits(_ quota: CodexCloudThreadQuota) -> String {
        guard quota.dataStatus != "unavailable", let text = quota.balanceUsageCredits, let value = Double(text),
              value.isFinite, !(value == 0 && quota.usageSource == "unknown") else { return "Unavailable" }
        return value == 0 ? "0" : text
    }
}
