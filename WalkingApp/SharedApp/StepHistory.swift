#if os(iOS)
import Foundation
import HealthKit
import Combine

enum StepHistoryRange: String, CaseIterable, Identifiable {
    case week = "W", month = "M", year = "Y"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .week: "Last 7 days"
        case .month: "Last 30 days"
        case .year: "Last 12 months · daily averages"
        }
    }
}

struct StepHistoryPoint: Identifiable, Sendable, Codable {
    let date: Date
    let count: Int?
    var id: Date { date }
}

struct StepHistorySummary {
    let points: [StepHistoryPoint]
    let average: Int?
    static func ceiling(for maximum: Int) -> Int {
        max(5000, Int((Double(maximum) / 5000).rounded(.up)) * 5000)
    }
    var ceiling: Int { Self.ceiling(for: points.compactMap(\.count).max() ?? 0) }
}

struct StepTrendSummary {
    let recent: [Int]
    let previous: [Int]
    let days: Int
    let bestDay: StepHistoryPoint?

    init(points: [StepHistoryPoint], now: Date = .now, calendar: Calendar = .current, days: Int = 7) {
        self.days = days
        let today = calendar.startOfDay(for: now)
        let recentStart = calendar.date(byAdding: .day, value: -days, to: today)!
        let previousStart = calendar.date(byAdding: .day, value: -(days * 2), to: today)!
        let recentPoints = points.filter { $0.date >= recentStart && $0.date < today }
        recent = recentPoints.compactMap(\.count)
        bestDay = recentPoints.filter { $0.count != nil }.sorted {
            if $0.count == $1.count { return $0.date > $1.date }
            return ($0.count ?? 0) > ($1.count ?? 0)
        }.first
        previous = points.filter { $0.date >= previousStart && $0.date < recentStart }.compactMap(\.count)
    }

    var average: Int? {
        recent.isEmpty ? nil : Int((Double(recent.reduce(0, +)) / Double(recent.count)).rounded())
    }

    var changePercent: Double? {
        guard recent.count == days, previous.count == days else { return nil }
        let prior = previous.reduce(0, +)
        guard prior > 0 else { return nil }
        return (Double(recent.reduce(0, +)) / Double(prior) - 1) * 100
    }

    func goalDays(for goal: Int) -> Int { recent.filter { $0 >= goal }.count }
}

struct WeeklyRecapSummary {
    let start: Date
    let end: Date
    let points: [StepHistoryPoint]
    init(points: [StepHistoryPoint], now: Date = .now, calendar: Calendar = .current) {
        let weekEnd = calendar.dateInterval(of: .weekOfYear, for: now)!.start
        let weekStart = calendar.date(byAdding: .weekOfYear, value: -1, to: weekEnd)!
        end = weekEnd
        start = weekStart
        self.points = points.filter { $0.date >= weekStart && $0.date < weekEnd }
    }
    var recorded: [Int] { points.compactMap(\.count) }
    var total: Int? { recorded.isEmpty ? nil : recorded.reduce(0, +) }
    var average: Int? { total.map { Int((Double($0) / Double(recorded.count)).rounded()) } }
    var bestDay: StepHistoryPoint? {
        points.filter { $0.count != nil }.max {
            if $0.count == $1.count { return $0.date < $1.date }
            return ($0.count ?? 0) < ($1.count ?? 0)
        }
    }
    func goalDays(_ goal: Int) -> Int { recorded.filter { $0 >= goal }.count }
}

/// Streaks use the current goal and consecutive completed calendar days.
struct GoalStreakSummary {
    let current: Int
    let longest: Int
    let missingYesterday: Bool

    init(points: [StepHistoryPoint], goal: Int, now: Date = .now, calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        let completed = points.filter { $0.date < today }.sorted { $0.date < $1.date }
        var run = 0
        var best = 0
        var previous: Date?
        for point in completed {
            let consecutive = previous.map { calendar.date(byAdding: .day, value: 1, to: $0) == point.date } ?? true
            if !consecutive { run = 0 }
            if goal > 0, let count = point.count, count >= goal { run += 1 } else { run = 0 }
            best = max(best, run)
            previous = point.date
        }
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        current = completed.last?.date == yesterday ? run : 0
        longest = best
        missingYesterday = completed.last?.date != yesterday || completed.last?.count == nil
    }
}

@MainActor
final class StepHistoryModel: ObservableObject {
    @Published private(set) var summary = StepHistorySummary(points: [], average: nil)
    @Published private(set) var isLoading = false
    @Published private(set) var message: String?
    private var requestID = UUID()
    private let store = HKHealthStore()
    private var cachedDaily: [StepHistoryPoint] = []
    private var cachedAt: Date?
    private var cachedDay: Date?

    private struct SavedHistory: Codable {
        let points: [StepHistoryPoint]
        let timeZone: String
    }
    private var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("walking-step-history.json")
    }

    init() {
        if let data = try? Data(contentsOf: cacheURL),
           let saved = try? JSONDecoder().decode(SavedHistory.self, from: data),
           saved.timeZone == TimeZone.current.identifier {
            cachedDaily = saved.points
        }
    }

    private func saveCache() {
        guard let data = try? JSONEncoder().encode(SavedHistory(points: cachedDaily, timeZone: TimeZone.current.identifier)) else { return }
        try? data.write(to: cacheURL, options: [.atomic, .completeFileProtection])
    }

    func invalidateCache() { cachedAt = nil }

    func load(_ range: StepHistoryRange, at now: Date = .now, dailyDays: Int? = nil) async {
        let request = UUID()
        requestID = request
        isLoading = true
        message = nil
        defer { if requestID == request { isLoading = false } }
        guard HKHealthStore.isHealthDataAvailable() else {
            message = "Health data is unavailable on this device."
            return
        }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let start: Date
        if let dailyDays {
            start = calendar.date(byAdding: .day, value: -dailyDays, to: today)!
        } else {
        switch range {
        case .week: start = calendar.date(byAdding: .day, value: -6, to: today)!
        case .month: start = calendar.date(byAdding: .day, value: -29, to: today)!
        case .year:
            let month = calendar.dateInterval(of: .month, for: now)!.start
            start = calendar.date(byAdding: .month, value: -11, to: month)!
        }
        }
        if !cachedDaily.isEmpty {
            apply(cachedDaily, range: range, dailyDays: dailyDays, start: start, calendar: calendar)
            isLoading = false
        }
        let queryStart = calendar.date(byAdding: .day, value: -730, to: today)!
        let interval = DateComponents(day: 1)
        let predicate = HKQuery.predicateForSamples(withStart: queryStart, end: now, options: .strictStartDate)
        let query = HKStatisticsCollectionQueryDescriptor(
            predicate: HKSamplePredicate.quantitySample(type: HKQuantityType(.stepCount), predicate: predicate),
            options: .cumulativeSum, anchorDate: queryStart, intervalComponents: interval)
        do {
            let daily: [StepHistoryPoint]
            if let cachedAt, cachedDay == today, Date.now.timeIntervalSince(cachedAt) < 60 {
                daily = cachedDaily
            } else {
                let result = try await query.result(for: store)
                guard !Task.isCancelled, requestID == request else { return }
                var fetched: [StepHistoryPoint] = []
                var date = queryStart
                let end = calendar.date(byAdding: .day, value: 1, to: today)!
                while date < end {
                    let quantity = date <= now ? result.statistics(for: date)?.sumQuantity() : nil
                    let count = quantity.map { Int($0.doubleValue(for: .count()).rounded()) }
                    fetched.append(StepHistoryPoint(date: date, count: count))
                    date = calendar.date(byAdding: .day, value: 1, to: date)!
                }
                cachedDaily = fetched
                cachedAt = .now
                cachedDay = today
                saveCache()
                daily = fetched
            }
            apply(daily, range: range, dailyDays: dailyDays, start: start, calendar: calendar)
        } catch {
            guard requestID == request, !Task.isCancelled else { return }
            message = "Couldn’t load step history. Unlock your iPhone and refresh."
        }
    }
    private func apply(_ daily: [StepHistoryPoint], range: StepHistoryRange, dailyDays: Int?, start: Date, calendar: Calendar) {
            let raw = daily.filter { $0.date >= start }
            let recorded = raw.compactMap(\.count)
            let average = recorded.isEmpty ? nil : Int((Double(recorded.reduce(0, +)) / Double(recorded.count)).rounded())
            var points = raw
            if range == .year, dailyDays == nil {
                points = (0..<12).map { offset in
                    let month = calendar.date(byAdding: .month, value: offset, to: start)!
                    let values = raw.filter { calendar.isDate($0.date, equalTo: month, toGranularity: .month) }.compactMap(\.count)
                    let mean = values.isEmpty ? nil : Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
                    return StepHistoryPoint(date: month, count: mean)
                }
            }
            summary = StepHistorySummary(points: points, average: average)
            if recorded.isEmpty {
                message = "No steps available for this period. Check Health access or wait for your devices to record steps."
            }
    }

}
#endif

#if os(iOS)
import Security

struct WalkingFriend: Decodable, Identifiable {
    let user_id: UUID
    let display_name: String
    let steps: Int?
    let updated_at: String?
    let sharing_enabled: Bool
    var id: UUID { user_id }
}
struct WalkingFriendRequest: Decodable, Identifiable {
    let user_id: UUID
    let display_name: String
    let incoming: Bool
    var id: UUID { user_id }
}
struct WalkingFriendProfile: Decodable {
    let user_id: UUID
    let display_name: String
    let friend_code: String
    let sharing_enabled: Bool
}
private struct WalkingSession: Codable {
    let access_token: String
    let refresh_token: String
}

@MainActor
final class FriendsConnection: ObservableObject {
    static let shared = FriendsConnection()
    @Published private(set) var profile: WalkingFriendProfile?
    @Published private(set) var friends: [WalkingFriend] = []
    @Published private(set) var requests: [WalkingFriendRequest] = []
    @Published private(set) var signedIn = false
    @Published private(set) var busy = false
    @Published var message: String?
    private var session: WalkingSession?
    private let base = "https://rdkljwjosocgydapooqi.supabase.co"
    private let publishableKey = "sb_publishable_JZKx_3SCcF0N47KcB8ntQQ_F98J8X5h"
    private let keychainService = "hjc.walking.app.friends"

    private init() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService, kSecAttrAccount as String: "session",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           let saved = try? JSONDecoder().decode(WalkingSession.self, from: data) {
            session = saved
            signedIn = true
        }
    }

    private func save(_ value: WalkingSession?) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService, kSecAttrAccount as String: "session"]
        if let value {
            let data = try JSONEncoder().encode(value)
            let attributes: [String: Any] = [kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
            let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                var item = query
                attributes.forEach { item[$0.key] = $0.value }
                guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                    throw NSError(domain: "Walking", code: 1, userInfo: [NSLocalizedDescriptionKey: "Couldn’t save your sign-in securely."])
                }
            } else if status != errSecSuccess {
                throw NSError(domain: "Walking", code: 1, userInfo: [NSLocalizedDescriptionKey: "Couldn’t update your sign-in securely."])
            }
        } else {
            SecItemDelete(query as CFDictionary)
        }
        session = value
        signedIn = value != nil
    }

    private func request(_ path: String, body: [String: Any], authenticated: Bool = true, retry: Bool = true) async throws -> Data {
        var request = URLRequest(url: URL(string: base + path)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authenticated {
            guard let session else { throw NSError(domain: "Walking", code: 1, userInfo: [NSLocalizedDescriptionKey: "Sign in to connect friends."]) }
            request.setValue("Bearer " + session.access_token, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if response.statusCode == 401, authenticated, retry, let session {
            let refreshed = try await self.request("/auth/v1/token?grant_type=refresh_token",
                body: ["refresh_token": session.refresh_token], authenticated: false, retry: false)
            try save(JSONDecoder().decode(WalkingSession.self, from: refreshed))
            return try await self.request(path, body: body, retry: false)
        }
        guard (200..<300).contains(response.statusCode) else {
            let details = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let description = details?["msg"] as? String ?? details?["message"] as? String ?? "Couldn’t connect. Please try again."
            throw NSError(domain: "Walking", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: description])
        }
        return data
    }

    private func perform(_ action: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        message = nil
        defer { busy = false }
        do { try await action() } catch { message = error.localizedDescription }
    }

    func createDeviceProfile(name: String) async {
        await perform {
            if session == nil {
                let data = try await request("/auth/v1/signup", body: [:], authenticated: false)
                try save(JSONDecoder().decode(WalkingSession.self, from: data))
            }
            try await loadProfile(name: name)
        }
    }

    private func loadProfile(name: String? = nil) async throws {
        let body: [String: Any] = name.map { ["p_name": $0] } ?? [:]
        let data = try await request("/rest/v1/rpc/walking_profile", body: body)
        profile = try JSONDecoder().decode(WalkingFriendProfile?.self, from: data)
        if profile == nil, name == nil {
            let localName = UserDefaults.standard.string(forKey: "displayName") ?? "Walker"
            try await loadProfile(name: localName.isEmpty ? "Walker" : localName)
        }
    }

    func refresh(period: String, start: String) async {
        guard signedIn else { return }
        await perform {
            try await loadProfile()
            let data = try await request("/rest/v1/rpc/walking_friends", body: ["p_period": period, "p_start": start])
            friends = try JSONDecoder().decode([WalkingFriend].self, from: data)
            let pending = try await request("/rest/v1/rpc/walking_friend_requests", body: [:])
            requests = try JSONDecoder().decode([WalkingFriendRequest].self, from: pending)
        }
    }

    func setSharing(_ enabled: Bool) async {
        await perform {
            _ = try await request("/rest/v1/rpc/walking_set_sharing", body: ["p_enabled": enabled])
            try await loadProfile()
        }
    }

    func invite(code: String) async {
        await perform {
            _ = try await request("/rest/v1/rpc/walking_request_friend", body: ["p_code": code])
            message = "Friend request sent. They’ll need to accept it in WalkingApp."
        }
    }

    func respond(user: UUID, accept: Bool) async {
        await perform {
            _ = try await request("/rest/v1/rpc/walking_respond_friend", body: ["p_requester": user.uuidString, "p_accept": accept])
            requests.removeAll { $0.user_id == user }
        }
    }

    func remove(user: UUID) async {
        await perform {
            _ = try await request("/rest/v1/rpc/walking_remove_friend", body: ["p_user": user.uuidString])
            friends.removeAll { $0.user_id == user }
            requests.removeAll { $0.user_id == user }
        }
    }

    func sync(period: String, start: String, steps: Int) async {
        guard signedIn, profile?.sharing_enabled == true else { return }
        await perform {
            _ = try await request("/rest/v1/rpc/walking_sync_steps", body: ["p_period": period, "p_start": start, "p_steps": steps])
        }
    }

    func signOut() async {
        await perform {
            _ = try await request("/auth/v1/logout", body: [:])
            try save(nil)
            profile = nil
            friends = []
            requests = []
        }
    }
}
#endif
