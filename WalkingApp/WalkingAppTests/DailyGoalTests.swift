import Foundation
import Testing
@testable import WalkingApp

struct DailyGoalTests {
    @MainActor @Test func persistsAndRemovesGoalInSharedContainer() throws {
        let original = GoalStore.read()
        defer { try? GoalStore.write(original) }
        let saved = DailyGoal(steps: 6000, revision: 10)
        try GoalStore.write(saved)
        #expect(GoalStore.read() == saved)
        let removed = DailyGoal(steps: nil, revision: 11)
        try GoalStore.write(removed)
        #expect(GoalStore.read() == removed)
    }

    @Test func validatesUserInput() {
        #expect(DailyGoal.parse("6000") == 6000)
        #expect(DailyGoal.parse(" 1 ") == 1)
        for input in ["", "0", "-1", "1.5", "6,000", "abc", String(repeating: "9", count: 40)] {
            #expect(DailyGoal.parse(input) == nil)
        }
    }

    @Test func progressHandlesMissingDataAndClampsAtGoal() {
        let goal = DailyGoal(steps: 6000, revision: 1)
        #expect(goal.progress(for: nil) == nil)
        #expect(DailyGoal.unset.progress(for: 509) == nil)
        #expect(goal.progress(for: 0) == 0)
        #expect(goal.progress(for: 3000) == 0.5)
        #expect(goal.progress(for: 6000) == 1)
        #expect(goal.progress(for: 7200) == 1)
        #expect(goal.progress(for: -1) == 0)
    }

    @Test func clearedGoalKeepsRevisionForSynchronization() throws {
        let removed = DailyGoal(steps: nil, revision: 20)
        let restored = try JSONDecoder().decode(DailyGoal.self, from: JSONEncoder().encode(removed))
        #expect(restored == removed)
        #expect(restored.revision > DailyGoal(steps: 6000, revision: 10).revision)
    }
}
