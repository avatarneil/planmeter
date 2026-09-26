import BackgroundTasks
import CloudKit
import PlanMeterRemote
import UIKit

/// One model serves foreground UI, push wakes, and scheduled refreshes.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    static let refreshIdentifier = "com.neilgoldader.planmeter.mobile.refresh"
    let model = MobileModel()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshIdentifier, using: .main) { [weak self] task in
            Task { @MainActor in self?.handle(task) }
        }
        application.registerForRemoteNotifications()
        return true
    }

    func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshIdentifier)
        request.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        do { try BGTaskScheduler.shared.submit(request) }
        catch { model.backgroundSyncStatus = "Background refresh scheduling unavailable: \(error.localizedDescription)" }
    }

    private func handle(_ task: BGTask) {
        scheduleRefresh()
        let completion = RefreshCompletion { success in task.setTaskCompleted(success: success) }
        let work = Task { completion.finish(await model.refreshInBackground()) }
        task.expirationHandler = {
            work.cancel()
            Task { @MainActor in completion.finish(false) }
        }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        model.pushRegistrationStatus = "Background push registration ready."
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        model.pushRegistrationStatus = "Push registration failed: \(error.localizedDescription)"
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any], fetchCompletionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo),
              notification.subscriptionID == CloudSnapshotStore.subscriptionIdentifier,
              model.usesCloud else {
            fetchCompletionHandler(.noData)
            return
        }
        let completion = RefreshCompletion { success in fetchCompletionHandler(success ? .newData : .failed) }
        let work = Task { completion.finish(await model.refreshInBackground()) }
        // Complete before iOS's background-push execution deadline, even offline.
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(25)) } catch { return }
            work.cancel()
            completion.finish(false)
        }
        Task {
            await work.value
            timeout.cancel()
        }
    }
}

/// Expiration and network completion can race; report completion only once.
@MainActor
private final class RefreshCompletion {
    private var callback: ((Bool) -> Void)?
    init(_ callback: @escaping (Bool) -> Void) { self.callback = callback }
    func finish(_ success: Bool) {
        let callback = callback
        self.callback = nil
        callback?(success)
    }
}
