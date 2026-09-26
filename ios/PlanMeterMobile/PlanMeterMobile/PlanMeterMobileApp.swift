import SwiftUI

@main
struct PlanMeterMobileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private var model: MobileModel { delegate.model }
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
            if phase == .background { delegate.scheduleRefresh() }
        }
    }
}
