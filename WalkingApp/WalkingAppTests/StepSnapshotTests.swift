import Foundation
import Testing
@testable import WalkingApp

struct StepSnapshotTests {
    private let now = Date(timeIntervalSince1970: 1_791_129_600)
    private func reading(_ count: Int?, secondsAgo: Double = 0, unavailable: Bool = false) -> StepSnapshot {
        StepSnapshot(date: now.addingTimeInterval(-secondsAgo), count: count, unavailable: unavailable)
    }
    @Test func ignoresOlderQueryEvenWhenItsCountIsHigher() {
        let chosen = StepSnapshotPolicy.newest(reading(2333), reading(2400, secondsAgo: 60), at: now)
        #expect(chosen?.count == 2333)
    }
    @Test func acceptsHealthCorrectionsInsteadOfTakingMaximum() {
        let chosen = StepSnapshotPolicy.newest(reading(2333, secondsAgo: 60), reading(2200), at: now)
        #expect(chosen?.count == 2200)
    }
    @Test func rejectsPreviousDayFutureAndUnavailableSnapshots() {
        #expect(StepSnapshotPolicy.valid(reading(1000, secondsAgo: 86400), at: now) == nil)
        #expect(StepSnapshotPolicy.valid(reading(1000, secondsAgo: -1), at: now) == nil)
        #expect(StepSnapshotPolicy.valid(reading(nil), at: now) == nil)
        #expect(StepSnapshotPolicy.valid(reading(-1), at: now) == nil)
        #expect(StepSnapshotPolicy.valid(reading(1000, unavailable: true), at: now) == nil)
        #expect(StepSnapshotPolicy.valid(reading(0), at: now)?.count == 0)
    }
    @Test func retainsSuccessfulReadingWhenFreshQueryIsUnavailable() {
        let cached = reading(1848, secondsAgo: 60)
        #expect(StepSnapshotPolicy.newest(reading(nil), cached, at: now)?.count == 1848)
    }
    @Test func watchUsesRecentPhoneAndFallsBackAfterFifteenMinutes() {
        let local = reading(2261)
        #expect(StepSnapshotPolicy.watch(local: local, phone: reading(2333, secondsAgo: 60), at: now).count == 2333)
        #expect(StepSnapshotPolicy.watch(local: local, phone: reading(2333, secondsAgo: 901), at: now).count == 2261)
        #expect(StepSnapshotPolicy.watch(local: local, phone: reading(3533, secondsAgo: 86400), at: now).count == 2261)
        #expect(StepSnapshotPolicy.watch(local: local, phone: nil, at: now).count == 2261)
    }
    @Test func widgetCompletionUsesReadingThatArrivesDuringQuery() {
        let started = now.addingTimeInterval(-10)
        let query = StepSnapshot(date: started, count: 3506, unavailable: false)
        let appWrite = StepSnapshot(date: now.addingTimeInterval(-2), count: 3949, unavailable: false)
        // A start-time cutoff used to reject this newer app write.
        #expect(StepSnapshotPolicy.valid(appWrite, at: started) == nil)
        #expect(StepSnapshotPolicy.newest(query, appWrite, at: now)?.count == 3949)
    }
    @Test func priorityComplicationDeliveryThrottlesAutomaticUpdatesAndSupportsRetries() {
        let current = reading(3949)
        #expect(StepComplicationDeliveryPolicy.shouldTransfer(current: current, previous: nil, force: false, at: now))
        #expect(!StepComplicationDeliveryPolicy.shouldTransfer(current: current, previous: reading(3805, secondsAgo: 60), force: false, at: now))
        #expect(StepComplicationDeliveryPolicy.shouldTransfer(current: current, previous: reading(3805, secondsAgo: 1800), force: false, at: now))
        #expect(!StepComplicationDeliveryPolicy.shouldTransfer(current: current, previous: reading(3949, secondsAgo: 1800), force: false, at: now))
        #expect(StepComplicationDeliveryPolicy.shouldTransfer(current: current, previous: reading(3949, secondsAgo: 60), force: true, at: now))
        #expect(!StepComplicationDeliveryPolicy.shouldTransfer(current: current, previous: reading(3805, secondsAgo: 10), force: true, at: now))
        #expect(!StepComplicationDeliveryPolicy.shouldTransfer(current: reading(nil), previous: nil, force: true, at: now))
    }

    @Test func widgetReloadSkipsRepeatedTotalsButAllowsChangesAndManualRetry() {
        #expect(!StepWidgetReloadPolicy.shouldReload(current: reading(2513), previous: reading(2513, secondsAgo: 60), force: false, at: now))
        #expect(StepWidgetReloadPolicy.shouldReload(current: reading(2513), previous: reading(1000, secondsAgo: 60), force: false, at: now))
        #expect(StepWidgetReloadPolicy.shouldReload(current: reading(2513), previous: reading(2513, secondsAgo: 60), force: true, at: now))
        #expect(StepWidgetReloadPolicy.shouldReload(current: reading(2513), previous: reading(2513, secondsAgo: 900), force: false, at: now))
        #expect(StepWidgetReloadPolicy.shouldReload(current: reading(2200), previous: reading(2513, secondsAgo: 60), force: false, at: now))
    }

}
