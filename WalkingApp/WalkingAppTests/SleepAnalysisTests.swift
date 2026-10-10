import Foundation
import Testing
@testable import WalkingApp

struct SleepAnalysisTests {
    let start = Date(timeIntervalSince1970: 1_791_129_600)
    func record(_ from: Double, _ to: Double, asleep: Bool = true, source: String = "watch", detailed: Bool = true) -> SleepRecord {
        SleepRecord(start: start.addingTimeInterval(from * 3600), end: start.addingTimeInterval(to * 3600), asleep: asleep, source: source, detailed: detailed)
    }
    @Test func overlappingSourcesDoNotInflateSleepAndAwakeIsRecorded() {
        let sessions = SleepAnalysis.sessions([
            record(0, 4), record(4.5, 8), record(4, 4.5, asleep: false),
            record(0, 8, source: "other", detailed: false)
        ], now: start.addingTimeInterval(10 * 3600))
        #expect(sessions.count == 1)
        #expect(sessions.first?.asleep == 7.5 * 3600)
        #expect(sessions.first?.awake == 0.5 * 3600)
    }
    @Test func duplicateSleepIsMergedAndMissingAwakeIsNotZero() {
        let session = SleepAnalysis.sessions([record(0, 8), record(1, 7)], now: start.addingTimeInterval(10 * 3600)).first!
        #expect(session.asleep == 8 * 3600)
        #expect(session.awake == nil)
        let score = SleepAnalysis.score(session, history: [], goalHours: 8)!
        #expect(score.total == 100)
        #expect(score.continuity == nil)
        #expect(score.consistency == nil)
    }
    @Test func daytimeSleepAndLaterNapAreSeparate() {
        let sessions = SleepAnalysis.sessions([record(8, 16), record(19, 20)], now: start.addingTimeInterval(24 * 3600))
        #expect(sessions.count == 2)
        #expect(!sessions[0].isNap)
        #expect(sessions[1].isNap)
        #expect(SleepAnalysis.score(sessions[1], history: sessions, goalHours: 8) == nil)
    }
    @Test func scoreUsesGoalAndExcludesMissingFactors() {
        let session = SleepSession(start: start, end: start.addingTimeInterval(6 * 3600), asleep: 6 * 3600, awake: nil)
        #expect(SleepAnalysis.score(session, history: [], goalHours: 8)?.total == 75)
        #expect(SleepAnalysis.score(session, history: [], goalHours: 6)?.total == 100)
    }
    @Test func scheduleConsistencyHandlesMidnight() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = calendar.startOfDay(for: start)
        let session = SleepSession(start: today.addingTimeInterval(10 * 60), end: today.addingTimeInterval(8 * 3600 + 10 * 60), asleep: 8 * 3600, awake: nil)
        let history = (1...3).map { day in
            let previous = today.addingTimeInterval(-Double(day) * 86400 - 10 * 60)
            return SleepSession(start: previous, end: previous.addingTimeInterval(8 * 3600), asleep: 8 * 3600, awake: nil)
        }
        #expect(SleepAnalysis.score(session, history: history, goalHours: 8, calendar: calendar)?.consistency == 92)
    }
    @Test func invalidAndFutureIntervalsAreIgnored() {
        #expect(SleepAnalysis.sessions([record(3, 1), record(10, 12)], now: start.addingTimeInterval(8 * 3600)).isEmpty)
    }
}
