import SwiftUI

@main
struct PlanMeterMobileApp: App {
    @State private var model = MobileModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onOpenURL { url in
                    guard url.host != "dashboard" else { return }
                    Task { await model.handle(url: url) }
                }
                .task { await model.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(phase)
        }
    }
}
