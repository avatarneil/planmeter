import SwiftUI

@main
struct PlanMeterApp: App {
    @State private var model = AppModel()
    @StateObject private var updates = UpdateController()

    var body: some Scene {
        WindowGroup("PlanMeter", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 640)
                .task {
                    await model.start()
                    if let path = SnapshotMode.path { await SnapshotMode.capture(to: path) }
                    if let path = SnapshotMode.menuPath { await SnapshotMode.captureMenu(to: path, model: model) }
                    if let path = SnapshotMode.remotePath { await SnapshotMode.captureRemote(to: path, model: model) }
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updates.checkForUpdates() }
                    .disabled(!updates.canCheckForUpdates)
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh") { Task { await model.refresh() } }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Refresh Pricing") { Task { await model.refreshPricing() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environment(model)
                .task { await model.start() }
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)
    }
}
