import Foundation
import Testing
@testable import WalkingApp

struct StepHistoryTests {
    @Test func scaleRoundsUpInFiveThousandStepIncrements() {
        for (maximum, expected) in [(0, 5000), (4999, 5000), (5000, 5000), (6700, 10000), (10000, 10000), (19300, 20000), (20001, 25000)] {
            #expect(StepHistorySummary.ceiling(for: maximum) == expected)
        }
    }

    @Test func scaleIgnoresMissingDays() {
        let summary = StepHistorySummary(points: [
            StepHistoryPoint(date: .now, count: nil),
            StepHistoryPoint(date: .now.addingTimeInterval(-86400), count: 19300)
        ], average: 19300)
        #expect(summary.ceiling == 20000)
    }
}

struct StepTrendTests {
    private let calendar = Calendar(identifier: .gregorian)

    @Test func comparesCompletedWeeksAndExcludesToday() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let today = calendar.startOfDay(for: now)
        let points = (0...14).map { offset in
            StepHistoryPoint(date: calendar.date(byAdding: .day, value: -offset, to: today)!,
                             count: offset == 0 ? 99999 : offset <= 7 ? 6000 : 4000)
        }
        let trend = StepTrendSummary(points: points, now: now, calendar: calendar)
        #expect(trend.average == 6000)
        #expect(trend.changePercent == 50)
        #expect(trend.goalDays(for: 5000) == 7)
        #expect(trend.bestDay?.date == calendar.date(byAdding: .day, value: -1, to: today))
        #expect(trend.bestDay?.count == 6000)
    }

    @Test func missingDaysPreventComparisonAndDoNotCountAsZero() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let today = calendar.startOfDay(for: now)
        let points = (1...14).map { offset in
            StepHistoryPoint(date: calendar.date(byAdding: .day, value: -offset, to: today)!,
                             count: offset == 2 ? nil : 5000)
        }
        let trend = StepTrendSummary(points: points, now: now, calendar: calendar)
        #expect(trend.average == 5000)
        #expect(trend.recent.count == 6)
        #expect(trend.changePercent == nil)
    }
}

struct ExtendedStepTrendTests {
    @Test func monthAndYearUseTheirFullCompletedPeriods() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let today = calendar.startOfDay(for: now)
        for days in [30, 365] {
            let points = (0...(days * 2)).map { offset in
                StepHistoryPoint(date: calendar.date(byAdding: .day, value: -offset, to: today)!,
                                 count: offset == 0 ? 99999 : offset <= days ? 6000 : 4000)
            }
            let trend = StepTrendSummary(points: points, now: now, calendar: calendar, days: days)
            #expect(trend.recent.count == days)
            #expect(trend.average == 6000)
            #expect(trend.changePercent == 50)
            #expect(trend.recent.reduce(0, +) == days * 6000)
        }
    }
}

struct GoalStreakTests {
    @Test func ignoresTodayAndRequiresConsecutiveRecordedDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let today = calendar.startOfDay(for: now)
        func point(_ offset: Int, _ count: Int?) -> StepHistoryPoint {
            StepHistoryPoint(date: calendar.date(byAdding: .day, value: -offset, to: today)!, count: count)
        }
        let result = GoalStreakSummary(points: [point(0, 0), point(1, 5000), point(2, nil), point(3, 6000), point(4, 5000)], goal: 5000, now: now, calendar: calendar)
        #expect(result.current == 1)
        #expect(result.longest == 2)
        #expect(!result.missingYesterday)
        let missing = GoalStreakSummary(points: [point(1, nil), point(2, 6000)], goal: 5000, now: now, calendar: calendar)
        #expect(missing.current == 0)
        #expect(missing.missingYesterday)
    }
}

struct WalkingPaceTests {
    @Test func requiresHistoryAndMeaningfulDifference() {
        #expect(WalkingPace.classify(steps: 2000, history: Array(repeating: 4000, count: 7)) == .behind)
        #expect(WalkingPace.classify(steps: 6000, history: Array(repeating: 4000, count: 14)) == .ahead)
        #expect(WalkingPace.classify(steps: 4000, history: Array(repeating: 4000, count: 7)) == .typical)
        #expect(WalkingPace.classify(steps: 0, history: Array(repeating: 4000, count: 6)) == nil)
        #expect(WalkingPace.classify(steps: 0, history: Array(repeating: 100, count: 14)) == nil)
        #expect(WalkingPace.classify(steps: 400, history: Array(repeating: 500, count: 14)) == .typical)
    }
}
