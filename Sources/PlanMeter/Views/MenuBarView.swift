import SwiftUI
import PlanMeterCore

/// Compact popover shown from the menu bar item.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("PlanMeter").font(.headline)
                Spacer()
                Picker("Range", selection: $model.range) {
                    ForEach(TimeRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(width: 96)
                Button {
                    Task { await model.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(model.isScanning)
                .help("Rescan")
                Menu {
                    Section("Plan Groups") {
                        ForEach(PlanGroup.allCases) { group in
                            Toggle(group.displayName, isOn: Binding(
                                get: { model.menuBarSpendGroups.contains(group) },
                                set: { isSelected in
                                    if isSelected {
                                        model.menuBarSpendGroups.insert(group)
                                    } else if model.menuBarSpendGroups.count > 1 {
                                        model.menuBarSpendGroups.remove(group)
                                    }
                                }
                            ))
                        }
                    }
                    Section("Time Period") {
                        Picker("Time Period", selection: $model.menuBarSpendRange) {
                            ForEach(MenuBarSpendRange.allCases) { range in
                                Text(range.displayName).tag(range)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Customize the menu bar total")
            }

            let summaries = model.groupSummaries
            let grand = model.total
            ForEach(summaries) { summary in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Circle().fill(Palette.color(for: summary.group)).frame(width: 8, height: 8)
                        Text(summary.group.displayName).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(Format.usd(summary.aggregate.costUsd)).font(.subheadline.weight(.semibold)).monospacedDigit()
                        Text(Format.tokens(summary.aggregate.totals.total)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                    }
                    ShareBar(fraction: grand.costUsd > 0 ? summary.aggregate.costUsd / grand.costUsd : 0, color: Palette.color(for: summary.group))
                    ForEach(summary.accounts, id: \.account.id) { row in
                        HStack(spacing: 6) {
                            Circle().fill(model.color(for: row.account)).frame(width: 6, height: 6)
                            Text(row.account.displayName).font(.caption).lineLimit(1)
                            Spacer()
                            Text(Format.usd(row.aggregate.costUsd)).font(.caption).monospacedDigit()
                                .foregroundStyle(row.aggregate.totals.total == 0 ? .secondary : .primary)
                            Text(Format.tokens(row.aggregate.totals.total)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                .frame(width: 52, alignment: .trailing)
                        }
                        .padding(.leading, 14)
                    }
                }
            }
            if summaries.isEmpty {
                Text(model.isScanning ? "Scanning…" : "No usage found.").font(.caption).foregroundStyle(.secondary)
            }

            let codexLimits = model.accounts.filter { $0.provider == .codex }.compactMap { account -> (Account, RateLimitWindow)? in
                let plan = account.id.replacingOccurrences(of: "codex:plan:", with: "")
                guard let w = model.rateLimits[plan]?.primary else { return nil }
                return (account, w)
            }
            if !codexLimits.isEmpty {
                Divider()
                ForEach(codexLimits, id: \.0.id) { account, window in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("\(account.displayName) · \(Format.windowName(minutes: window.windowMinutes))").font(.caption)
                            Spacer()
                            Text("\(Int(window.usedPercent.rounded()))% · resets \(Format.relative(window.resetDate))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        ShareBar(fraction: window.usedPercent / 100, color: window.usedPercent > 90 ? .red : window.usedPercent > 70 ? .orange : .accentColor)
                    }
                }
            }

            Divider()
            HStack {
                Button("Open PlanMeter") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                if let last = model.lastScan {
                    Text(Date().timeIntervalSince(last) < 60 ? "just now" : Format.relative(last))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 340)
    }
}

/// Menu bar label: icon plus the configured total cost so the number is visible
/// without opening anything.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "chart.bar.fill")
            Text(Format.usd(model.menuBarTotal.costUsd))
                .monospacedDigit()
                .font(.system(size: 12, weight: .medium))
        }
        .help("\(model.menuBarSpendRange.displayName) · \(model.menuBarSpendGroups.map(\.displayName).sorted().joined(separator: ", "))")
    }
}
