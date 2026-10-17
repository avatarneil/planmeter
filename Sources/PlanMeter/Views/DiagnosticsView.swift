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
