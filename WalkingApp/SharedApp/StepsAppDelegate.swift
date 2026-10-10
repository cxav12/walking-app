import Foundation

#if os(watchOS)
import WatchKit

final class StepsAppDelegate: NSObject, WKApplicationDelegate {
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let connectivityTask = task as? WKWatchConnectivityRefreshBackgroundTask {
                GoalSync.shared.handle(connectivityTask)
            } else if let refreshTask = task as? WKApplicationRefreshBackgroundTask {
                Task { @MainActor in
                    await StepBackgroundUpdates.shared.handleWatchRefresh()
                    refreshTask.setTaskCompletedWithSnapshot(false)
                }
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }

    func applicationDidFinishLaunching() {
        StepBackgroundUpdates.shared.start()
        GoalSync.shared.start()
    }
}
#else
import UIKit

final class StepsAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        StepBackgroundUpdates.shared.start()
        GoalSync.shared.start()
        return true
    }
}
#endif
