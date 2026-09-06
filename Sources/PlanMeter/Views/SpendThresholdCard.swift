import AppKit
import SwiftUI
import PlanMeterCore

func thresholdSymbol(_ status: SpendThreshold.Status) -> String {
    switch status {
    case .comfortable: return "checkmark.circle"
    case .approaching: return "exclamationmark.circle"
    case .reached: return "exclamationmark.triangle.fill"
    }
}

func spendTint(_ status: SpendThreshold.Status) -> NSColor {
    switch status {
    case .comfortable: return NSColor(srgbRed: 0.10, green: 0.72, blue: 0.63, alpha: 1)
    case .approaching: return NSColor(srgbRed: 0.96, green: 0.63, blue: 0.16, alpha: 1)
    case .reached: return NSColor(srgbRed: 0.96, green: 0.34, blue: 0.40, alpha: 1)
    }
}

struct SpendThresholdCard: View {
    @Environment(AppModel.self) private var model
    @State private var isEditing = false

    private var scope: String {
        model.menuBarSpendGroups.map(\.displayName).sorted().joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Personal spend limit").font(.subheadline.weight(.semibold))
                Spacer()
                Button(model.menuBarSpendThreshold == nil ? "Set limit" : "Edit") {
                    isEditing.toggle()
                }
                .buttonStyle(.borderless)
            }
            Text("\(model.range.displayName) · \(scope)")
                .font(.caption).foregroundStyle(.secondary)
            let spend = model.menuBarTotal.costUsd
            HStack(alignment: .firstTextBaseline) {
                Text(Format.usd(spend)).font(.title2.weight(.semibold)).monospacedDigit()
                if let threshold = model.menuBarSpendThreshold {
                    Text("of \(Format.usd(threshold.limit))").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(Format.percent(threshold.fraction(spend: spend)))
                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                }
            }
            if let threshold = model.menuBarSpendThreshold {
                let status = threshold.status(spend: spend)
                let color = Color(nsColor: spendTint(status))
                ProgressView(value: min(1, threshold.fraction(spend: spend))).tint(color)
                    .accessibilityLabel("Personal spend limit used")
                    .accessibilityValue(Format.percent(threshold.fraction(spend: spend)))
                Label {
                    Text(spend >= threshold.limit
                         ? (spend == threshold.limit ? "Limit reached" : "\(Format.usd(spend - threshold.limit)) over limit")
                         : "\(Format.usd(threshold.limit - spend)) left\(status == .approaching ? " · Getting close" : "")")
                } icon: {
                    Image(systemName: thresholdSymbol(status))
                }
                .font(.caption.weight(.medium)).foregroundStyle(color)
            } else {
                Text("Give your selected tools a shared spending target.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Estimated usage cost · A personal target, not a billing cap.")
                .font(.caption2).foregroundStyle(.secondary)
            if isEditing {
                Divider()
                SpendThresholdEditor(range: model.range, threshold: model.menuBarSpendThreshold) { value in
                    model.menuBarSpendThresholds[model.range.id] = value
                    isEditing = false
                } cancel: {
                    isEditing = false
                }
                .id(model.range)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct SpendThresholdEditor: View {
    var range: TimeRange
    var threshold: SpendThreshold?
    var save: (SpendThreshold?) -> Void
    var cancel: () -> Void
    @State private var amount: String
    @State private var warningPercent: Double

    init(range: TimeRange, threshold: SpendThreshold?, save: @escaping (SpendThreshold?) -> Void, cancel: @escaping () -> Void) {
        self.range = range
        self.threshold = threshold
        self.save = save
        self.cancel = cancel
        _amount = State(initialValue: threshold.map { $0.limit.formatted(.number.grouping(.never)) } ?? "")
        _warningPercent = State(initialValue: threshold?.warningPercent ?? 80)
    }

    private var proposed: SpendThreshold? {
        guard let value = try? Double(amount, format: .number) else { return nil }
        let threshold = SpendThreshold(limit: value, warningPercent: warningPercent)
        return threshold.isValid ? threshold : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Limit (USD)").font(.caption)
                TextField("e.g. 100", text: $amount)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Spend limit in US dollars")
                    .onSubmit { if let proposed { save(proposed) } }
            }
            if !amount.isEmpty && proposed == nil {
                Text("Enter an amount from 0.01 to 1,000,000,000.")
                    .font(.caption2).foregroundStyle(.red)
            }
            HStack {
                Text("Warn at").font(.caption)
                Slider(value: $warningPercent, in: 1...99, step: 1)
                    .accessibilityLabel("Warning threshold percent")
                Text("\(Int(warningPercent))%").font(.caption).monospacedDigit().frame(width: 32)
            }
            Text("Saved for \(range.displayName). Applies to whichever plan groups you select.")
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                if threshold != nil {
                    Button("Remove limit", role: .destructive) { save(nil) }
                }
                Spacer()
                Button("Cancel", action: cancel)
                Button("Save") { if let proposed { save(proposed) } }
                    .disabled(proposed == nil)
            }
            .controlSize(.small)
        }
    }
}
