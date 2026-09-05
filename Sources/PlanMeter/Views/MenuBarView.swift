import AppKit
import SwiftUI
import PlanMeterCore

/// Compact popover shown from the menu bar item.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var detail: UsageScope?

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

            SpendThresholdCard()

            if let detail {
                Button { self.detail = nil } label: {
                    Label("All usage", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                ScrollView {
                    UsageDetailView(scope: detail, compact: true)
                }
                .frame(height: 340)
            } else {
                let summaries = model.groupSummaries
                let grand = model.total
                ForEach(summaries) { summary in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline) {
                            Circle().fill(Palette.color(for: summary.group)).frame(width: 8, height: 8)
                            Button { detail = .group(summary.group) } label: {
                                Text(summary.group.displayName).font(.subheadline.weight(.semibold))
                            }
                            .buttonStyle(.plain)
                            .help("Explore \(summary.group.displayName)")
                            Spacer()
                            Text(Format.usd(summary.aggregate.costUsd)).font(.subheadline.weight(.semibold)).monospacedDigit()
                            Text(Format.tokens(summary.aggregate.totals.total)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                .frame(width: 52, alignment: .trailing)
                        }
                        ShareBar(fraction: grand.costUsd > 0 ? summary.aggregate.costUsd / grand.costUsd : 0, color: Palette.color(for: summary.group))
                        ForEach(summary.accounts, id: \.account.id) { row in
                            HStack(spacing: 6) {
                                Circle().fill(model.color(for: row.account)).frame(width: 6, height: 6)
                                Button { detail = .account(row.account.id) } label: {
                                    HStack(spacing: 3) {
                                        Text(row.account.displayName).font(.caption).lineLimit(1)
                                        Image(systemName: "chevron.right").font(.system(size: 8))
                                    }
                                }
                                .buttonStyle(.plain)
                                .help("Explore \(row.account.displayName)")
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

            }

            Divider()
            HStack {
                Button("Open PlanMeter") {
                    if let detail { model.usageDetail = detail }
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

/// Render the amount and its colorful underline together: MenuBarExtra labels
/// reliably support images, while arbitrary stacked SwiftUI layouts may flatten.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let spend = model.menuBarTotal.costUsd
        Group {
            if let threshold = model.menuBarSpendThreshold {
                let fraction = threshold.fraction(spend: spend)
                Image(nsImage: spendLabelImage(amount: Format.usd(spend), fraction: fraction,
                                              status: threshold.status(spend: spend), dark: colorScheme == .dark))
                    .renderingMode(.original)
                    .accessibilityLabel("\(Format.usd(spend)), \(Format.percent(fraction)) of spend limit used")
            } else {
                Label(Format.usd(spend), systemImage: "chart.bar.fill")
                    .monospacedDigit()
                    .font(.system(size: 12, weight: .medium))
            }
        }
        .help("\(model.menuBarSpendRange.displayName) · \(model.menuBarSpendGroups.map(\.displayName).sorted().joined(separator: ", "))")
    }
}

private func spendLabelImage(amount: String, fraction: Double, status: SpendThreshold.Status, dark: Bool) -> NSImage {
    let foreground: NSColor = dark ? .white : .black
    let amountText = NSAttributedString(string: amount, attributes: [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
        .foregroundColor: foreground,
    ])
    let percentText = NSAttributedString(string: Format.percent(fraction), attributes: [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
        .foregroundColor: foreground.withAlphaComponent(0.65),
    ])
    let width = ceil(amountText.size().width + percentText.size().width + 6)
    let fill = fraction.isFinite ? min(1, max(0, fraction)) : 0
    let image = NSImage(size: NSSize(width: width, height: 22), flipped: false) { _ in
        amountText.draw(at: NSPoint(x: 0, y: 6))
        percentText.draw(at: NSPoint(x: width - percentText.size().width, y: 7))

        // A borderless runway under the text, with a bright leading tip.
        let track = NSRect(x: 0, y: 1, width: width, height: 3)
        foreground.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()
        if fill > 0 {
            let accent = spendTint(status)
            let filled = NSRect(x: 0, y: 1, width: max(3, width * fill), height: 3)
            let path = NSBezierPath(roundedRect: filled, xRadius: 1.5, yRadius: 1.5)
            NSGradient(starting: accent.withAlphaComponent(0.65), ending: accent)?.draw(in: path, angle: 0)
            accent.setFill()
            NSBezierPath(ovalIn: NSRect(x: filled.maxX - 3, y: 1, width: 3, height: 3)).fill()
        }
        return true
    }
    image.isTemplate = false // Preserve the status colors in the menu bar.
    return image
}
