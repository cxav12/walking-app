import SwiftUI
import HealthKit
import Combine

struct SleepRecord {
    let start: Date
    let end: Date
    let asleep: Bool
    let source: String
    let detailed: Bool
}
struct SleepSession {
    let start: Date
    let end: Date
    let asleep: TimeInterval
    let awake: TimeInterval?
    var isNap: Bool { asleep < 3 * 3600 }
}
struct SleepScore {
    let total: Int
    let duration: Int
    let continuity: Int?
    let consistency: Int?
}
enum SleepAnalysis {
    static func merged(_ intervals: [DateInterval]) -> [DateInterval] {
        var result: [DateInterval] = []
        for interval in intervals.sorted(by: { $0.start < $1.start }) where interval.duration > 0 {
            if let last = result.last, interval.start <= last.end {
                result[result.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
            } else { result.append(interval) }
        }
        return result
    }
    static func sessions(_ records: [SleepRecord], now: Date) -> [SleepSession] {
        let valid = records.filter { $0.end <= now && $0.end > $0.start }
        let sleep = merged(valid.filter(\.asleep).map { DateInterval(start: $0.start, end: $0.end) })
        var windows: [DateInterval] = []
        for interval in sleep {
            if let last = windows.last, interval.start.timeIntervalSince(last.end) <= 90 * 60 {
                windows[windows.count - 1] = DateInterval(start: last.start, end: interval.end)
            } else { windows.append(interval) }
        }
        return windows.compactMap { window in
            // Select one source per session so overlapping apps don't double-count sleep.
            let candidates = Dictionary(grouping: valid.filter { $0.start < window.end && $0.end > window.start }, by: \.source)
            let source = candidates.values.filter { $0.contains(where: \.asleep) }.max { a, b in
                let ad = a.contains(where: \.detailed), bd = b.contains(where: \.detailed)
                if ad != bd { return !ad }
                return merged(a.filter(\.asleep).map { DateInterval(start: $0.start, end: $0.end) }).reduce(0) { $0 + $1.duration }
                    < merged(b.filter(\.asleep).map { DateInterval(start: $0.start, end: $0.end) }).reduce(0) { $0 + $1.duration }
            }
            guard let source else { return nil }
            let intervals = merged(source.filter(\.asleep).map { DateInterval(start: max($0.start, window.start), end: min($0.end, window.end)) })
            guard let first = intervals.first, let last = intervals.last else { return nil }
            let span = DateInterval(start: first.start, end: last.end)
            let asleep = intervals.reduce(0) { $0 + $1.duration }
            let awakeRecords = source.filter { !$0.asleep && $0.start < span.end && $0.end > span.start }
            // Exclude overlaps with sleep rather than treating contradictory samples as awake.
            let awake = merged(awakeRecords.map { DateInterval(start: max($0.start, span.start), end: min($0.end, span.end)) }).reduce(0.0) { sum, interval in
                sum + interval.duration - intervals.reduce(0.0) { $0 + ($1.intersection(with: interval)?.duration ?? 0) }
            }
            return SleepSession(start: first.start, end: last.end, asleep: asleep,
                                awake: awakeRecords.isEmpty ? nil : max(0, awake))
        }
    }
    static func score(_ session: SleepSession, history: [SleepSession], goalHours: Double, calendar: Calendar = .current) -> SleepScore? {
        guard !session.isNap else { return nil }
        let duration = Int((min(1, session.asleep / (max(4, min(12, goalHours)) * 3600)) * 100).rounded())
        let continuity = session.awake.map { Int((session.asleep / (session.asleep + $0) * 100).rounded()) }
        let previous = history.filter { !$0.isNap && $0.end < session.start }.suffix(7)
        func minute(_ date: Date) -> Double { Double(calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)) }
        let differences = previous.map { prior -> Double in
            let difference = abs(minute(prior.start) - minute(session.start))
            return min(difference, 1440 - difference)
        }
        let consistency = differences.count >= 3 ? Int((max(0, 1 - differences.reduce(0, +) / Double(differences.count) / 240) * 100).rounded()) : nil
        var weighted = Double(duration) * 70, weight = 70.0
        if let continuity { weighted += Double(continuity) * 20; weight += 20 }
        if let consistency { weighted += Double(consistency) * 10; weight += 10 }
        return SleepScore(total: Int((weighted / weight).rounded()), duration: duration, continuity: continuity, consistency: consistency)
    }
}

@MainActor final class SleepModel: ObservableObject {
    @Published var sessions: [SleepSession] = []
    @Published var loading = false
    @Published var message: String?
    private let store = HKHealthStore()
    func connect() async {
        do {
            try await store.requestAuthorization(toShare: [], read: [HKCategoryType(.sleepAnalysis)])
            await refresh()
        } catch { message = "Couldn’t request sleep access. Try again." }
    }
    func refresh() async {
        guard !loading else { return }
        guard HKHealthStore.isHealthDataAvailable() else { message = "Health data is unavailable."; return }
        loading = true
        defer { loading = false }
        do {
            let now = Date.now
            let predicate = HKQuery.predicateForSamples(withStart: now.addingTimeInterval(-14 * 86400), end: now)
            let samples: [HKCategorySample] = try await withCheckedThrowingContinuation { continuation in
                let completion = HealthQueryCompletion<[HKCategorySample]>(continuation)
                let query = HKSampleQuery(sampleType: HKCategoryType(.sleepAnalysis), predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                    if let error { completion.finish(.failure(error)) }
                    else { completion.finish(.success(samples as? [HKCategorySample] ?? [])) }
                }
                store.execute(query)
                DispatchQueue.global().asyncAfter(deadline: .now() + 10) { [store] in
                    if completion.finish(.failure(HealthQueryTimeout())) { store.stop(query) }
                }
            }
            let records = samples.compactMap { sample -> SleepRecord? in
                guard let value = HKCategoryValueSleepAnalysis(rawValue: sample.value), value != .inBed else { return nil }
                let asleep = HKCategoryValueSleepAnalysis.allAsleepValues.contains(value)
                guard asleep || value == .awake else { return nil }
                return SleepRecord(start: sample.startDate, end: sample.endDate, asleep: asleep,
                                   source: sample.sourceRevision.source.bundleIdentifier,
                                   detailed: [.asleepCore, .asleepDeep, .asleepREM, .awake].contains(value))
            }
            sessions = SleepAnalysis.sessions(records, now: now)
            message = nil
        } catch { message = "Sleep data is unavailable. Unlock your iPhone and try refreshing." }
    }
}

struct SleepCard: View {
    let refreshDate: Date
    @StateObject private var model = SleepModel()
    @AppStorage("sleepGoalHours") private var goalHours = 8.0
    @AppStorage("sleepConsistencyEnabled") private var consistencyEnabled = true
    private var recent: [SleepSession] { model.sessions.filter { Date.now.timeIntervalSince($0.end) <= 48 * 3600 } }
    private var mainSleep: SleepSession? { recent.last(where: { !$0.isNap }) ?? recent.last }
    private func duration(_ value: TimeInterval) -> String { let minutes = Int(value / 60); return "\(minutes / 60)h \(minutes % 60)m" }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Label("Sleep", systemImage: "moon.zzz.fill").font(.headline); Spacer(); if model.loading { ProgressView() } }
            if let session = mainSleep {
                Text(session.isNap ? "Latest nap" : "Latest sleep").font(.subheadline).foregroundStyle(.white.opacity(0.65))
                Text("\(session.start.formatted(date: .abbreviated, time: .shortened)) – \(session.end.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.white.opacity(0.65))
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 16) {
                    metric("Sleep start", session.start.formatted(date: .omitted, time: .shortened))
                    metric("Wake-up", session.end.formatted(date: .omitted, time: .shortened))
                    metric("Time asleep", duration(session.asleep))
                    metric("Recorded awake", session.awake.map(duration) ?? "Unavailable")
                }
                if let score = SleepAnalysis.score(session, history: consistencyEnabled ? model.sessions : [], goalHours: goalHours) {
                    HStack(alignment: .firstTextBaseline) { Text("\(score.total)").font(.system(size: 42, weight: .bold, design: .rounded)); Text("/ 100").foregroundStyle(.white.opacity(0.6)) }
                    Text("Calculated sleep score").font(.subheadline.weight(.semibold))
                    Text("Duration \(score.duration)/100 · Continuity \(score.continuity.map { "\($0)/100" } ?? "unavailable") · Consistency \(score.consistency.map { "\($0)/100" } ?? (consistencyEnabled ? "needs 3 prior sleeps" : "off"))").font(.caption).foregroundStyle(.white.opacity(0.65))
                }
                let naps = recent.filter { $0.isNap && $0.start > session.end }
                if !naps.isEmpty { Text("Later naps: \(duration(naps.reduce(0) { $0 + $1.asleep }))").font(.caption) }
            } else { Text("No recent sleep records. Connect Sleep access to read your Apple Health data.").foregroundStyle(.white.opacity(0.65)) }
            if let message = model.message { Text(message).font(.caption) }
            Button("Connect Sleep access") { Task { await model.connect() } }.disabled(model.loading)
            DisclosureGroup("Sleep goal and score") {
                VStack(alignment: .leading, spacing: 12) {
                    Stepper("Sleep goal: \(goalHours, specifier: "%.1f") hours", value: $goalHours, in: 4...12, step: 0.5)
                    Toggle("Include schedule consistency", isOn: $consistencyEnabled)
                    Text("Duration contributes 70%, continuity 20%, and schedule consistency 10%. Missing factors are excluded and the remaining weights are adjusted. Turn consistency off for changing shifts. Naps aren’t scored. This is Walking’s score, not Apple’s.").font(.caption).foregroundStyle(.white.opacity(0.65))
                }.padding(.top, 10)
            }
        }
        .padding(20).modifier(WalkingGlassCard())
        .tint(WalkingStyle.accent)
        .task(id: refreshDate) { await model.refresh() }
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(title).font(.caption).foregroundStyle(.white.opacity(0.65)); Text(value).font(.headline) }
    }
}
