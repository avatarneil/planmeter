import SwiftUI
import PlanMeterCore

/// Provider readings, sources, and pricing: detail for checking the numbers,
/// kept out of the main dashboard.
struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(model.usageNote).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                AccountCoverageCard()
                SourcesCard()
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        // Window restoration can open Diagnostics alone; start is idempotent.
        .task { await model.start() }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Range", selection: $model.range) {
                    ForEach(TimeRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 380)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.refresh(forceAccountUsage: true) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.isScanning)
            }
        }
    }
}

extension AppModel {
    /// Account readings that failed or fell back to stale data. These need attention,
    /// unlike partial readings that simply lack optional detail.
    func readingWarnings(targetId: String? = nil) -> [String] {
        func flagged(_ status: SourceStatus, _ message: String?) -> String? {
            guard status == .failed || message?.hasPrefix("Stale") == true else { return nil }
            return message ?? "Reading unavailable."
        }
        var warnings: [String] = []
        for target in discovery.codexUsageTargets where targetId == nil || target.id == targetId {
            let messages = [
                accountUsage.first { $0.target.id == target.id }.flatMap { flagged($0.status, $0.message) },
                dailyUsage.first { $0.target.id == target.id }.flatMap { flagged($0.status, $0.message) },
                cloudUsage.first { $0.target.id == target.id }.flatMap { flagged($0.status, $0.message) },
            ].compactMap { $0 }
            warnings += Set(messages).sorted().map { targetId == nil ? "\(target.name): \($0)" : $0 }
        }
        return warnings
    }
}
