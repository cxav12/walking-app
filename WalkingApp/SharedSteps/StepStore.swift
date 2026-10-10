import Foundation
import HealthKit
import OSLog

nonisolated struct StepSnapshot: Sendable, Codable {
    let date: Date
    let count: Int?
    let unavailable: Bool

    static func empty(at date: Date = .now) -> StepSnapshot {
        StepSnapshot(date: date, count: nil, unavailable: false)
    }
}

struct StepStore {
    let healthStore = HKHealthStore()

    func requestAccess() async throws {
        try await healthStore.requestAuthorization(toShare: [], read: [HKQuantityType(.stepCount)])
    }

    func today(at date: Date = .now, timeout: TimeInterval? = nil) async throws -> StepSnapshot {
        guard HKHealthStore.isHealthDataAvailable() else {
            return StepSnapshot(date: date, count: nil, unavailable: true)
        }
        let start = Calendar.current.startOfDay(for: date)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: date, options: .strictStartDate)
        // Statistics combine overlapping sources; do not add phone and watch samples by hand.
        let statistics: HKStatistics?
        if let timeout {
            statistics = try await withCheckedThrowingContinuation { continuation in
                let result = HealthQueryCompletion<HKStatistics?>(continuation)
                let query = HKStatisticsQuery(quantityType: HKQuantityType(.stepCount), quantitySamplePredicate: predicate, options: .cumulativeSum) { _, statistics, error in
                    if let error { result.finish(.failure(error)) } else { result.finish(.success(statistics)) }
                }
                healthStore.execute(query)
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if result.finish(.failure(HealthQueryTimeout())) { healthStore.stop(query) }
                }
            }
        } else {
            let query = HKStatisticsQueryDescriptor(
                predicate: HKSamplePredicate.quantitySample(type: HKQuantityType(.stepCount), predicate: predicate),
                options: .cumulativeSum
            )
            statistics = try await query.result(for: healthStore)
        }
        let count = statistics?.sumQuantity().map { Int($0.doubleValue(for: .count()).rounded()) }
        // HealthKit deliberately makes denied read access indistinguishable from missing data.
        let local = StepSnapshot(date: date, count: count, unavailable: false)
        #if os(watchOS)
        return StepSnapshotPolicy.watch(local: local, phone: SharedStepSnapshot.readPhone(at: date), at: date)
        #else
        return local
        #endif
    }
}

/// Validate dates before reusing a snapshot; never carry yesterday's steps into today.
nonisolated enum StepSnapshotPolicy {
    static func valid(_ snapshot: StepSnapshot?, at now: Date, calendar: Calendar = .current) -> StepSnapshot? {
        guard let snapshot, let count = snapshot.count, count >= 0, !snapshot.unavailable,
              snapshot.date <= now, calendar.isDate(snapshot.date, inSameDayAs: now) else { return nil }
        return snapshot
    }
    static func newest(_ first: StepSnapshot?, _ second: StepSnapshot?, at now: Date) -> StepSnapshot? {
        let a = valid(first, at: now), b = valid(second, at: now)
        guard let a else { return b }
        guard let b else { return a }
        return b.date > a.date ? b : a
    }
    static func watch(local: StepSnapshot, phone: StepSnapshot?, at now: Date) -> StepSnapshot {
        // Use the phone's merged total briefly, then fall back to the watch when disconnected.
        if let phone = valid(phone, at: now), now.timeIntervalSince(phone.date) <= 15 * 60 { return phone }
        return local
    }
}

extension Notification.Name {
    static let walkingStepsChanged = Notification.Name("walkingStepsChanged")
}

/// Shared by the app and its extensions on each device; app groups don't cross devices.
enum SharedStepSnapshot {
    private struct Saved: Codable {
        let snapshot: StepSnapshot
        let timeZone: String
    }
    private static func url(phone: Bool) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: GoalStore.group)?
            .appendingPathComponent(phone ? "phone-widget-steps.json" : "latest-widget-steps.json")
    }
    static func read(at now: Date = .now) -> StepSnapshot? { read(phone: false, at: now) }
    static func readPhone(at now: Date = .now) -> StepSnapshot? { read(phone: true, at: now) }
    private static func read(phone: Bool, at now: Date) -> StepSnapshot? {
        guard let url = url(phone: phone), let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode(Saved.self, from: data),
              saved.timeZone == TimeZone.current.identifier else { return nil }
        return StepSnapshotPolicy.valid(saved.snapshot, at: now)
    }
    // This records what a timeline supplied, not proof that WidgetKit rendered it.
    static func recordWidgetDisplay(_ snapshot: StepSnapshot) {
        guard let defaults = UserDefaults(suiteName: GoalStore.group),
              let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: "lastWidgetTimelineSnapshot")
        Logger(subsystem: "hjc.walking.app", category: "StepsTimeline").info("Returned timeline; steps: \(snapshot.count ?? -1, privacy: .public), reading time: \(snapshot.date.description, privacy: .public)")
    }

    static func write(_ snapshot: StepSnapshot) { write(snapshot, phone: false) }
    static func writePhone(_ snapshot: StepSnapshot) { write(snapshot, phone: true) }
    private static func write(_ snapshot: StepSnapshot, phone: Bool) {
        let now = Date.now
        guard StepSnapshotPolicy.valid(snapshot, at: now) != nil,
              let url = url(phone: phone),
              // A query started earlier may finish later; don't replace a newer reading.
              read(phone: phone, at: now).map({ $0.date <= snapshot.date }) ?? true,
              let data = try? JSONEncoder().encode(Saved(snapshot: snapshot, timeZone: TimeZone.current.identifier)) else { return }
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            Logger(subsystem: "hjc.walking.app", category: "StepsCache").error("Failed to save shared steps: \(error.localizedDescription, privacy: .public)")
            return
        }
        var file = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? file.setResourceValues(values)
    }
}

/// Preserve the complication transfer budget for actual changes, with manual retry support.
nonisolated enum StepComplicationDeliveryPolicy {
    static func shouldTransfer(current: StepSnapshot, previous: StepSnapshot?, force: Bool, at now: Date) -> Bool {
        guard let current = StepSnapshotPolicy.valid(current, at: now) else { return false }
        guard let previous = StepSnapshotPolicy.valid(previous, at: now) else { return true }
        let elapsed = now.timeIntervalSince(previous.date)
        if force { return elapsed >= 60 }
        return current.count != previous.count && elapsed >= 30 * 60
    }
}

/// A timed-out widget query must return its cached entry, even if Health never calls back.
struct HealthQueryTimeout: Error {}
final class HealthQueryCompletion<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }
    @discardableResult func finish(_ result: Result<Value, Error>) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return false }
        pending.resume(with: result)
        return true
    }
}

nonisolated enum StepWidgetReloadPolicy {
    static func shouldReload(current: StepSnapshot, previous: StepSnapshot?, force: Bool, at now: Date) -> Bool {
        guard let current = StepSnapshotPolicy.valid(current, at: now) else { return false }
        guard !force, let previous = StepSnapshotPolicy.valid(previous, at: now) else { return true }
        return current.count != previous.count || now.timeIntervalSince(previous.date) >= 15 * 60
    }
}
