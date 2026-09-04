import SwiftUI

struct RootView: View {
    @Environment(MobileModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.isLocked {
                LockView()
            } else if model.server == nil {
                PairingView()
            } else {
                NavigationStack {
                    DashboardView()
                        .navigationTitle("PlanMeter")
                        .navigationBarTitleDisplayMode(.large)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button { model.showSettings = true } label: { Image(systemName: "gearshape") }
                            }
                            ToolbarItem(placement: .topBarLeading) {
                                if model.isLoading { ProgressView() }
                            }
                        }
                        .sheet(isPresented: $model.showSettings) {
                            SettingsView().environment(model)
                        }
                }
            }
        }
        .animation(.default, value: model.isLocked)
    }
}

struct LockView: View {
    @Environment(MobileModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("PlanMeter is locked").font(.title3.weight(.semibold))
            Button("Unlock") { Task { await model.unlock() } }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}
