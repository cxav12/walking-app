import Combine
import Foundation
import OSLog
import WatchConnectivity
import WidgetKit
#if os(watchOS)
import WatchKit
#endif

@MainActor
final class GoalSync: NSObject, ObservableObject {
    static let shared = GoalSync()
    @Published private(set) var goal = GoalStore.read()
    @Published private(set) var message: String?
    #if os(watchOS)
    private var backgroundTasks: [WKWatchConnectivityRefreshBackgroundTask] = []
    private var pendingObservation: NSKeyValueObservation?
    private var activationObservation: NSKeyValueObservation?

    func handle(_ task: WKWatchConnectivityRefreshBackgroundTask) {
        backgroundTasks.append(task)
        start()
        completeBackgroundTasksIfReady()
    }

    private func completeBackgroundTasksIfReady() {
        guard WCSession.default.activationState == .activated,
              !WCSession.default.hasContentPending else { return }
        backgroundTasks.forEach { $0.setTaskCompletedWithSnapshot(false) }
        backgroundTasks.removeAll()
    }
    #endif

    private let logger = Logger(subsystem: "hjc.walking.app", category: "GoalSync")

    func start() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        if session.delegate == nil { session.delegate = self }
        #if os(watchOS)
        if pendingObservation == nil {
            pendingObservation = session.observe(\.hasContentPending, options: [.new]) { _, _ in
                Task { @MainActor in self.completeBackgroundTasksIfReady() }
            }
            activationObservation = session.observe(\.activationState, options: [.new]) { _, _ in
                Task { @MainActor in self.completeBackgroundTasksIfReady() }
            }
        }
        #endif
        if session.activationState == .activated {
            synchronize()
        } else {
            session.activate()
        }
    }

    #if os(iOS)
    @discardableResult
    func save(steps: Int?) -> Bool {
        guard steps == nil || steps! > 0 else { return false }
        let updated = DailyGoal(steps: steps, revision: max(Date().timeIntervalSince1970, goal.revision + 0.001))
        do {
            try GoalStore.write(updated)
            goal = updated
            message = nil
            WidgetCenter.shared.reloadTimelines(ofKind: "TodaySteps")
            start()
            return true
        } catch {
            message = "Couldn’t save your goal. Please try again."
            return false
        }
    }
    #endif

    #if os(iOS)
    func publishSteps(_ snapshot: StepSnapshot, force: Bool = false) {
        // Goal and steps share one context, so neither replaces the other payload.
        start()
        transferComplicationIfNeeded(snapshot, force: force)
    }

    private func transferComplicationIfNeeded(_ snapshot: StepSnapshot, force: Bool = false) {
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled,
              session.isComplicationEnabled, session.remainingComplicationUserInfoTransfers > 0 else { return }
        let defaults = UserDefaults.standard
        let previous = defaults.data(forKey: "lastPriorityStepTransfer").flatMap { try? JSONDecoder().decode(StepSnapshot.self, from: $0) }
        guard StepComplicationDeliveryPolicy.shouldTransfer(current: snapshot, previous: previous, force: force, at: .now) else { return }
        // A newer total supersedes a queued old total; don't deliver a stale backlog.
        for transfer in session.outstandingUserInfoTransfers where transfer.isCurrentComplicationInfo { transfer.cancel() }
        session.transferCurrentComplicationUserInfo(payload)
        let sent = StepSnapshot(date: .now, count: snapshot.count, unavailable: false)
        defaults.set(try? JSONEncoder().encode(sent), forKey: "lastPriorityStepTransfer")
        logger.info("Queued priority complication update; transfers left: \(session.remainingComplicationUserInfoTransfers)")
    }
    #endif

    private func synchronize() {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        #if os(iOS)
        guard session.isPaired, session.isWatchAppInstalled else { return }
        do {
            // The latest goal is delivered even when the Watch isn't currently reachable.
            try session.updateApplicationContext(payload)
            if session.isReachable {
                session.sendMessage(payload, replyHandler: { _ in
                    Logger(subsystem: "hjc.walking.app", category: "GoalSync").info("Watch acknowledged the latest step payload.")
                }, errorHandler: { error in
                    Logger(subsystem: "hjc.walking.app", category: "GoalSync").info("Immediate Watch delivery deferred: \(error.localizedDescription, privacy: .public)")
                })
            }
            if let snapshot = SharedStepSnapshot.read() { transferComplicationIfNeeded(snapshot) }
            message = nil
        } catch {
            message = "Goal saved on iPhone. Open the app again to retry Watch sync."
            logger.error("Goal sync failed: \(error.localizedDescription, privacy: .public)")
        }
        #else
        receive(session.receivedApplicationContext)
        if session.isReachable {
            session.sendMessage(["requestGoal": true], replyHandler: { response in
                Task { @MainActor in self.receive(response) }
            }, errorHandler: { _ in })
        }
        #endif
    }

    private var payload: [String: Any] {
        var result: [String: Any] = ["goalSteps": goal.steps ?? 0, "goalRevision": goal.revision]
        #if os(iOS)
        if let snapshot = SharedStepSnapshot.read(), let data = try? JSONEncoder().encode(snapshot) {
            result["stepSnapshot"] = data
            result["stepTimeZone"] = TimeZone.current.identifier
        }
        #endif
        return result
    }

    private func receive(_ payload: [String: Any]) {
        #if os(watchOS)
        if payload["stepTimeZone"] as? String == TimeZone.current.identifier,
           let data = payload["stepSnapshot"] as? Data,
           let phone = try? JSONDecoder().decode(StepSnapshot.self, from: data),
           StepSnapshotPolicy.valid(phone, at: .now) != nil {
            SharedStepSnapshot.writePhone(phone)
            if let saved = SharedStepSnapshot.readPhone(), Date.now.timeIntervalSince(saved.date) <= 15 * 60 {
                NotificationCenter.default.post(name: .walkingStepsChanged, object: saved)
            }
            WidgetCenter.shared.reloadTimelines(ofKind: "TodaySteps")
        }
        guard let steps = payload["goalSteps"] as? Int, steps >= 0,
              let revision = payload["goalRevision"] as? Double, revision.isFinite,
              revision > goal.revision else { return }
        let updated = DailyGoal(steps: steps == 0 ? nil : steps, revision: revision)
        do {
            try GoalStore.write(updated)
            goal = updated
            message = nil
            WidgetCenter.shared.reloadTimelines(ofKind: "TodaySteps")
        } catch {
            message = "Couldn’t save the goal from your iPhone. Open both apps to retry."
            logger.error("Could not store received goal: \(error.localizedDescription, privacy: .public)")
        }
        #endif
    }
}

extension GoalSync: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            guard error == nil else {
                self.message = "Watch sync is unavailable. Open both apps to retry."
                return
            }
            self.synchronize()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.synchronize() }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in self.receive(applicationContext) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        Task { @MainActor in
            self.receive(userInfo)
            #if os(watchOS)
            self.completeBackgroundTasksIfReady()
            #endif
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in self.receive(message) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        Task { @MainActor in
            #if os(iOS)
            await StepBackgroundUpdates.shared.refreshSnapshot()
            replyHandler(self.payload)
            #else
            self.receive(message)
            replyHandler([:])
            #endif
        }
    }

    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.synchronize() }
    }
    #endif
}
