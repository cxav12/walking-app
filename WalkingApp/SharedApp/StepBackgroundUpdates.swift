import HealthKit
import OSLog
import WidgetKit
#if os(watchOS)
import WatchKit
#endif

@MainActor
final class StepBackgroundUpdates {
    static let shared = StepBackgroundUpdates()
    private let store = HKHealthStore()
    private let logger = Logger(subsystem: "hjc.walking.app", category: "StepBackgroundUpdates")
    private var observer: HKObserverQuery?
    private var enablingDelivery = false
    private var deliveryEnabled = false
    private var lastWidgetReload: StepSnapshot?

    func publish(_ snapshot: StepSnapshot, forceWidgetSync: Bool = false) {
        guard snapshot.count != nil, !snapshot.unavailable else { return }
        SharedStepSnapshot.write(snapshot)
        var latest = StepSnapshotPolicy.newest(snapshot, SharedStepSnapshot.read(), at: .now) ?? snapshot
        #if os(watchOS)
        latest = StepSnapshotPolicy.watch(local: latest, phone: SharedStepSnapshot.readPhone(), at: .now)
        #endif
        NotificationCenter.default.post(name: .walkingStepsChanged, object: latest)
        if StepWidgetReloadPolicy.shouldReload(current: latest, previous: lastWidgetReload, force: forceWidgetSync, at: .now) {
            lastWidgetReload = latest
            WidgetCenter.shared.reloadTimelines(ofKind: "TodaySteps")
        }
        #if os(iOS)
        GoalSync.shared.publishSteps(latest, force: forceWidgetSync)
        #endif
    }

    func refreshSnapshot() async {
        do { publish(try await StepStore().today()) }
        catch { logger.info("Health unavailable; retaining last successful steps snapshot.") }
    }

    #if os(watchOS)
    private var nextWatchRefresh: Date?
    func scheduleWatchRefresh() {
        let now = Date.now
        guard nextWatchRefresh.map({ $0 > now }) != true else { return }
        let next = now.addingTimeInterval(15 * 60)
        nextWatchRefresh = next
        WKApplication.shared().scheduleBackgroundRefresh(withPreferredDate: next, userInfo: nil) { error in
            if let error {
                Task { @MainActor in self.nextWatchRefresh = nil }
                Logger(subsystem: "hjc.walking.app", category: "StepBackgroundUpdates").error("Watch refresh scheduling failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    func handleWatchRefresh() async {
        nextWatchRefresh = nil
        await refreshSnapshot()
        GoalSync.shared.start()
        scheduleWatchRefresh()
    }
    #endif

    func start() {
        #if os(watchOS)
        scheduleWatchRefresh()
        #endif
        guard HKHealthStore.isHealthDataAvailable() else { return }
        if observer == nil {
            let query = HKObserverQuery(sampleType: HKQuantityType(.stepCount), predicate: nil) { _, completion, error in
                Task { @MainActor in
                    guard error == nil else {
                        completion()
                        Logger(subsystem: "hjc.walking.app", category: "StepBackgroundUpdates")
                            .error("Step observer failed: \(error!.localizedDescription, privacy: .public)")
                        return
                    }
                    // Cache the total before requesting a reload: HealthKit may lock again
                    // before the widget extension gets its turn to run.
                    await StepBackgroundUpdates.shared.refreshSnapshot()
                    completion()
                    #if os(iOS)
                    Task { await WalkingReminders.shared.evaluate() }
                    #endif
                }
            }
            observer = query
            store.execute(query)
        }
        guard !enablingDelivery, !deliveryEnabled else { return }
        enablingDelivery = true
        Task {
            defer { enablingDelivery = false }
            do {
                // Steps have an hourly background-delivery limit; WidgetKit also polls independently.
                try await store.enableBackgroundDelivery(for: HKQuantityType(.stepCount), frequency: .hourly)
                deliveryEnabled = true
                logger.info("Step background delivery enabled.")
            } catch {
                logger.error("Could not enable step background delivery: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
