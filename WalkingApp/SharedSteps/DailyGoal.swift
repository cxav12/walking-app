import Foundation

nonisolated struct DailyGoal: Codable, Equatable, Sendable {
    var steps: Int?
    var revision: Double

    static let unset = DailyGoal(steps: nil, revision: 0)

    static func parse(_ text: String) -> Int? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(text), value > 0 else { return nil }
        return value
    }

    func progress(for count: Int?) -> Double? {
        guard let steps, steps > 0, let count else { return nil }
        return min(1, max(0, Double(count) / Double(steps)))
    }
}

enum GoalStore {
    static let group = "group.hjc.walking.app"
    private static let key = "dailyStepGoal"

    static func read() -> DailyGoal {
        guard let data = UserDefaults(suiteName: group)?.data(forKey: key),
              let goal = try? JSONDecoder().decode(DailyGoal.self, from: data),
              goal.steps == nil || goal.steps! > 0 else { return .unset }
        return goal
    }

    static func write(_ goal: DailyGoal) throws {
        guard FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) != nil,
              let defaults = UserDefaults(suiteName: group) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        defaults.set(try JSONEncoder().encode(goal), forKey: key)
    }
}
