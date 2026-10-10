import SwiftUI
import WidgetKit
import OSLog
import HealthKit

struct WidgetStepDay: Identifiable {
    let date: Date
    let steps: Int?
    var id: Date { date }
}

struct StepsEntry: TimelineEntry {
    let date: Date
    let snapshot: StepSnapshot
    var goal: DailyGoal = .unset
    var history: [WidgetStepDay] = []
    var streak: Int? = nil
}

struct StepsProvider: TimelineProvider {
    func placeholder(in context: Context) -> StepsEntry {
        StepsEntry(date: .now, snapshot: StepSnapshot(date: .now, count: 6420, unavailable: false),
                   goal: DailyGoal(steps: 8000, revision: 0))
    }

    func getSnapshot(in context: Context, completion: @escaping (StepsEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
        } else {
            Task {
                #if os(iOS)
                completion(reconciled(await currentEntry(includeHistory: context.family == .systemMedium || context.family == .systemLarge)))
                #else
                completion(reconciled(await currentEntry(includeHistory: false)))
                #endif
            }
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StepsEntry>) -> Void) {
        Task {
            Logger(subsystem: "hjc.walking.app", category: "StepsTimeline")
                .info("Building a fresh steps timeline.")
            #if os(iOS)
            let entry = await currentEntry(includeHistory: context.family == .systemMedium || context.family == .systemLarge)
            #else
            let entry = await currentEntry(includeHistory: false)
            #endif
            let midnight = Calendar.current.date(byAdding: .day, value: 1,
                                                  to: Calendar.current.startOfDay(for: entry.date))!
            // Expire yesterday’s total while retaining the user's daily goal.
            let reset = StepsEntry(date: midnight, snapshot: .empty(at: midnight), goal: entry.goal)
            let refresh = min(entry.date.addingTimeInterval(15 * 60), midnight)
            // An app/phone update may have arrived while this provider queried Health
            // or history. Select again at completion, not at the query's start time.
            let finalEntry = reconciled(entry)
            SharedStepSnapshot.recordWidgetDisplay(finalEntry.snapshot)
            completion(Timeline(entries: [finalEntry, reset], policy: .after(refresh)))
        }
    }

    private func reconciled(_ entry: StepsEntry) -> StepsEntry {
        let now = Date.now
        var result = entry
        var snapshot = StepSnapshotPolicy.newest(entry.snapshot, SharedStepSnapshot.read(at: now), at: now) ?? .empty(at: now)
        #if os(watchOS)
        snapshot = StepSnapshotPolicy.watch(local: snapshot, phone: SharedStepSnapshot.readPhone(at: now), at: now)
        #endif
        result = StepsEntry(date: now, snapshot: snapshot, goal: GoalStore.read(), history: entry.history, streak: entry.streak)
        return result
    }

    private func currentEntry(includeHistory: Bool) async -> StepsEntry {
        let date = Date()
        let cached = SharedStepSnapshot.read(at: date)
        // The app just published this reading; don't block its reload on another Health query.
        let fresh: StepSnapshot?
        if let cached, date.timeIntervalSince(cached.date) <= 60 {
            fresh = cached
        } else {
            fresh = try? await StepStore().today(at: date, timeout: 3)
        }
        let snapshot: StepSnapshot
        if let latest = StepSnapshotPolicy.newest(fresh, SharedStepSnapshot.read(), at: .now) {
            snapshot = latest
            SharedStepSnapshot.write(latest)
        } else {
            snapshot = fresh ?? .empty(at: date)
        }
        #if os(watchOS)
        let displayed = StepSnapshotPolicy.watch(local: snapshot, phone: SharedStepSnapshot.readPhone(), at: .now)
        #else
        let displayed = snapshot
        #endif
        let goal = GoalStore.read()
        #if os(iOS)
        guard includeHistory else { return StepsEntry(date: date, snapshot: displayed, goal: goal) }
        do {
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: date)
            let start = calendar.date(byAdding: .day, value: -730, to: today)!
            let predicate = HKQuery.predicateForSamples(withStart: start, end: date, options: .strictStartDate)
            let store = HKHealthStore()
            let result: HKStatisticsCollection = try await withCheckedThrowingContinuation { continuation in
                let completion = HealthQueryCompletion<HKStatisticsCollection>(continuation)
                let query = HKStatisticsCollectionQuery(quantityType: HKQuantityType(.stepCount), quantitySamplePredicate: predicate,
                                                       options: .cumulativeSum, anchorDate: start, intervalComponents: DateComponents(day: 1))
                query.initialResultsHandler = { _, collection, error in
                    if let error { completion.finish(.failure(error)) }
                    else if let collection { completion.finish(.success(collection)) }
                    else { completion.finish(.failure(HealthQueryTimeout())) }
                }
                store.execute(query)
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                    if completion.finish(.failure(HealthQueryTimeout())) { store.stop(query) }
                }
            }
            var days: [WidgetStepDay] = []
            var cursor = start
            var streak = 0
            while cursor <= today {
                let count = result.statistics(for: cursor)?.sumQuantity().map { Int($0.doubleValue(for: .count()).rounded()) }
                days.append(WidgetStepDay(date: cursor, steps: count))
                if cursor < today, let target = goal.steps {
                    streak = (count ?? -1) >= target ? streak + 1 : 0
                }
                cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
            }
            return StepsEntry(date: date, snapshot: displayed, goal: goal,
                              history: Array(days.suffix(7)), streak: goal.steps == nil ? nil : streak)
        } catch { return StepsEntry(date: date, snapshot: displayed, goal: goal) }
        #else
        return StepsEntry(date: date, snapshot: displayed, goal: goal)
        #endif
    }
}

struct StepsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StepsEntry
    private var count: String { entry.snapshot.count?.formatted() ?? "—" }
    private var progress: Double? { entry.goal.progress(for: entry.snapshot.count) }
    private var goalText: String {
        if let goal = entry.goal.steps { return "\(count) / \(goal.formatted()) steps" }
        return "\(count) steps"
    }

    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                Text(goalText)
            #if os(watchOS)
            case .accessoryCorner:
                Text(count)
                    .font(.system(.body, design: .rounded).bold())
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .widgetLabel {
                        if let progress {
                            Gauge(value: progress) { Text("Steps") }
                                .tint(.green)
                        } else {
                            Text("Steps")
                        }
                    }
            #endif
            case .accessoryCircular:
                StepsRing(count: entry.snapshot.count, progress: progress)
            case .accessoryRectangular:
                #if os(watchOS)
                WideStepsComplication(entry: entry)
                #else
                VStack(alignment: .leading, spacing: 3) {
                    Label("Steps walked", systemImage: "figure.walk").font(.caption)
                    if entry.goal.steps != nil, let count = entry.snapshot.count {
                        Text("\(count.formatted()) steps")
                            .font(.headline).minimumScaleFactor(0.6).lineLimit(1)
                        ProgressView(value: progress ?? 0).tint(WalkingStyle.accent)
                    } else {
                        Text(entry.snapshot.count == nil ? "Open app to update" : count + " steps")
                            .font(.headline).minimumScaleFactor(0.6).lineLimit(1)
                    }
                }
                #endif
            default:
                #if os(iOS)
                HomeStepsWidgetView(entry: entry)
                #else
                Text(count)
                #endif
            }
        }
        .privacySensitive()
        .containerBackground(for: .widget) {
            #if os(iOS)
            if family == .systemSmall || family == .systemMedium || family == .systemLarge {
                WalkingBackdrop()
            } else {
                WalkingStyle.accent.opacity(0.12)
            }
            #else
            WalkingStyle.accent.opacity(0.12)
            #endif
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Today: \(goalText). \(entry.snapshot.count == nil ? "Steps unavailable. Unlock iPhone and open the app." : "Updated " + entry.snapshot.date.formatted(date: .omitted, time: .shortened)). \(entry.streak.map { "Completed-day streak: \($0) days." } ?? "")")
        .accessibilityValue(progress.map { "\(Int(($0 * 100).rounded())) percent of goal" } ?? "")
    }
}

#if os(watchOS)
private struct WideStepsComplication: View {
    let entry: StepsEntry
    private let accent = WalkingStyle.accent
    private let iconColor = WalkingStyle.accent

    private var remaining: Int? {
        guard let goal = entry.goal.steps, let count = entry.snapshot.count else { return nil }
        return max(0, goal - count)
    }

    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.height / 64, geometry.size.width / 150)
            VStack(spacing: 4 * scale) {
                HStack(alignment: .center, spacing: 5 * scale) {
                    Image(systemName: "figure.walk")
                        .font(.system(size: 22 * scale, weight: .semibold))
                        .foregroundStyle(iconColor)
                        .widgetAccentable()
                        .fixedSize()
                    (Text(entry.snapshot.count?.formatted() ?? "—")
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                     + Text(" steps")
                        .fontWeight(.regular)
                        .foregroundColor(.white.opacity(0.7)))
                        .font(.system(size: 30 * scale, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 3 * scale) {
                    ForEach(0..<10) { index in
                        GeometryReader { segment in
                            let progress = entry.goal.progress(for: entry.snapshot.count) ?? 0
                            let fill = min(1, max(0, progress * 10 - Double(index)))
                            RoundedRectangle(cornerRadius: 2 * scale)
                                .fill(.white.opacity(0.18))
                                .overlay(alignment: .leading) {
                                    Rectangle()
                                        .fill(accent)
                                        .frame(width: segment.size.width * fill)
                                        .widgetAccentable()
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 2 * scale))
                        }
                    }
                }
                .frame(height: 7 * scale)
                HStack(alignment: .center, spacing: 6 * scale) {
                    Group {
                        if remaining == 0 {
                            Text("Goal reached!")
                                .fontWeight(.semibold)
                        } else if let remaining {
                            (Text(remaining.formatted()).fontWeight(.semibold)
                             + Text(" remaining").fontWeight(.regular))
                        } else if entry.snapshot.count == nil {
                            Text("Open app for Health access")
                        } else {
                            Text("Set a daily goal")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let goal = entry.goal.steps {
                        Text(goal.formatted())
                            .fontWeight(.semibold)
                            .monospacedDigit()
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .font(.system(size: 12 * scale))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
        }
    }
}

#Preview(as: .accessoryRectangular) {
    StepsWidget()
} timeline: {
    StepsEntry(date: .now, snapshot: StepSnapshot(date: .now, count: 3271, unavailable: false), goal: DailyGoal(steps: 10000, revision: 0))
    StepsEntry(date: .now, snapshot: StepSnapshot(date: .now, count: 12345, unavailable: false), goal: DailyGoal(steps: 10000, revision: 0))
    StepsEntry(date: .now, snapshot: .empty(at: .now), goal: .unset)
}
#endif

#if os(iOS)
private struct HomeStepsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StepsEntry
    private var remaining: String {
        guard let count = entry.snapshot.count else { return "Open app to update" }
        guard let goal = entry.goal.steps else { return "Set a goal in the app" }
        return count >= goal ? "Goal reached!" : "\(max(0, goal - count).formatted()) remaining"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemLarge ? 16 : 8) {
            Label("Today’s Steps", systemImage: "shoeprints.fill")
                .font(.headline).foregroundStyle(.white)
            if family == .systemMedium {
                HStack(alignment: .center, spacing: 18) {
                    total.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 8) {
                        streakLabel
                        Text(remaining).font(.subheadline.weight(.semibold))
                            .foregroundStyle(WalkingStyle.accent)
                            .lineLimit(2).minimumScaleFactor(0.8)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else { total }
            if entry.goal.steps != nil {
                SegmentedStepProgress(progress: entry.goal.progress(for: entry.snapshot.count) ?? 0,
                                      height: family == .systemSmall ? 8 : 10, spacing: 4)
            }
            if family != .systemMedium {
                Text(remaining).font(.caption.weight(.semibold)).foregroundStyle(WalkingStyle.accent)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            if family == .systemLarge {
                HStack {
                    Text("Last 7 days").font(.subheadline.bold())
                    Spacer()
                    streakLabel
                }
                chart
                Text("Today is in progress · Streak counts completed days")
                    .font(.caption2).foregroundStyle(.white.opacity(0.7))
            }
            Spacer(minLength: 0)
            if entry.snapshot.count != nil {
                Text("Updated \(entry.snapshot.date.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2).foregroundStyle(.white.opacity(0.7))
            } else {
                Text("Unlock iPhone and open WalkingApp to check Health access.")
                    .font(.caption2).foregroundStyle(.white.opacity(0.75)).lineLimit(2)
            }
        }
    }
    private var total: some View {
        Text(entry.snapshot.count?.formatted() ?? "—")
            .font(.system(size: family == .systemLarge ? 48 : 38, weight: .bold, design: .rounded))
            .monospacedDigit().foregroundStyle(.white)
            .lineLimit(1).minimumScaleFactor(0.5)
    }
    private var streakLabel: some View {
        Label(entry.streak.map { "\($0) day streak" } ?? "Streak unavailable", systemImage: "flame.fill")
            .font(.caption.weight(.semibold)).foregroundStyle(WalkingStyle.secondaryAccent)
            .lineLimit(1).minimumScaleFactor(0.75)
    }
    private var chart: some View {
        GeometryReader { geometry in
            let maximum = max(1, entry.history.compactMap(\.steps).max() ?? 1)
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(entry.history) { day in
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Calendar.current.isDateInToday(day.date) ? WalkingStyle.secondaryAccent : WalkingStyle.accent)
                            .frame(height: max(day.steps == nil ? 0 : 3, (geometry.size.height - 22) * Double(day.steps ?? 0) / Double(maximum)))
                            .frame(maxWidth: .infinity)
                            .frame(height: max(0, geometry.size.height - 22), alignment: .bottom)
                            .overlay(alignment: .bottom) {
                                if day.steps == nil { Text("—").font(.caption2).foregroundStyle(.white.opacity(0.6)) }
                            }
                        Text(day.date.formatted(.dateTime.weekday(.narrow)))
                            .font(.caption2).foregroundStyle(.white.opacity(0.8))
                    }
                }
            }
            if entry.history.isEmpty {
                Text("Chart unavailable · Open the app to update")
                    .font(.caption).foregroundStyle(.white.opacity(0.75))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(minHeight: 70)
    }
}
#endif

/// Keeps the exact total available to VoiceOver while fitting a small watch slot.
private struct StepsRing: View {
    let count: Int?
    let progress: Double?
    private let accent = WalkingStyle.accent

    private var compactCount: String {
        guard let count else { return "—" }
        guard count >= 1000 else { return String(count) }
        // Truncate to a tenth of a thousand, rather than rounding up steps.
        let tenths = count / 100
        return "\(tenths / 10).\(tenths % 10)k"
    }

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let thickness = size * 0.085
            ZStack {
                if let progress {
                    Circle()
                        .stroke(.white.opacity(0.18), lineWidth: thickness)
                    if progress > 0 {
                        Circle()
                            .trim(from: 0, to: min(1, max(0, progress)))
                            .stroke(accent, style: StrokeStyle(lineWidth: thickness, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .widgetAccentable()
                    }
                }
                VStack(spacing: size * 0.025) {
                    Image(systemName: "figure.walk")
                        .font(.system(size: size * 0.30, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(height: size * 0.32)
                    Text(compactCount)
                        .font(.system(size: size * 0.29, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .frame(width: size * 0.73)
            }
            .frame(width: size - thickness, height: size - thickness)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

@main
struct StepsWidget: Widget {
    let kind = "TodaySteps"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StepsProvider()) { entry in
            StepsWidgetView(entry: entry)
        }
        .configurationDisplayName("Today’s Steps")
        .description("Steps, goal progress, streaks, and a seven-day chart.")
        #if os(watchOS)
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
        #else
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline])
        #endif
    }
}

#Preview(as: .accessoryCircular) {
    StepsWidget()
} timeline: {
    StepsEntry(date: .now, snapshot: StepSnapshot(date: .now, count: 2245, unavailable: false), goal: DailyGoal(steps: 6000, revision: 0))
    StepsEntry(date: .now, snapshot: StepSnapshot(date: .now, count: 7200, unavailable: false), goal: DailyGoal(steps: 6000, revision: 0))
}

#if os(iOS)
#Preview(as: .systemSmall) {
    StepsWidget()
} timeline: {
    StepsEntry(date: .now, snapshot: StepSnapshot(date: .now, count: 3271, unavailable: false), goal: DailyGoal(steps: 10000, revision: 0))
    StepsEntry(date: .now, snapshot: StepSnapshot(date: .now, count: 12345, unavailable: false), goal: DailyGoal(steps: 10000, revision: 0))
    StepsEntry(date: .now, snapshot: .empty(at: .now), goal: .unset)
}
#endif
