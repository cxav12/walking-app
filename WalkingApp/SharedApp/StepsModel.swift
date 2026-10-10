import Combine
import HealthKit
import WidgetKit

@MainActor
final class StepsModel: ObservableObject {
    @Published private(set) var snapshot = StepSnapshot.empty()
    @Published private(set) var isLoading = false
    @Published private(set) var message: String?
    private let store = StepStore()

    private var stepChanges: AnyCancellable?

    init() {
        snapshot = SharedStepSnapshot.read() ?? .empty()
        stepChanges = NotificationCenter.default.publisher(for: .walkingStepsChanged)
            .compactMap { $0.object as? StepSnapshot }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] updated in
                guard let self else { return }
                self.snapshot = StepSnapshotPolicy.newest(self.snapshot, updated, at: .now) ?? updated
                #if os(watchOS)
                self.snapshot = StepSnapshotPolicy.watch(local: self.snapshot, phone: SharedStepSnapshot.readPhone(), at: .now)
                #endif
                self.message = nil
            }
    }

    func connect() async {
        guard !isLoading else { return }
        guard HKHealthStore.isHealthDataAvailable() else {
            message = "Health data is unavailable on this device."
            return
        }
        isLoading = true
        do {
            try await store.requestAccess()
            isLoading = false
            await refresh()
            StepBackgroundUpdates.shared.start()
            #if os(iOS)
            Task { await WalkingReminders.shared.evaluate() }
            #endif
        } catch {
            isLoading = false
            message = "Couldn’t request Health access. \(error.localizedDescription)"
        }
    }

    func refresh(forceWidgetSync: Bool = false) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            snapshot = try await store.today()
            message = snapshot.unavailable ? "Health data is unavailable on this device." : nil
            snapshot = StepSnapshotPolicy.newest(snapshot, SharedStepSnapshot.read(), at: .now) ?? snapshot
            #if os(watchOS)
            snapshot = StepSnapshotPolicy.watch(local: snapshot, phone: SharedStepSnapshot.readPhone(), at: .now)
            #endif
            StepBackgroundUpdates.shared.publish(snapshot, forceWidgetSync: forceWidgetSync)
            StepBackgroundUpdates.shared.start()
            #if os(iOS)
            Task { await WalkingReminders.shared.evaluate() }
            #endif
        } catch {
            snapshot = SharedStepSnapshot.read() ?? .empty()
            #if os(watchOS)
            snapshot = StepSnapshotPolicy.watch(local: snapshot, phone: SharedStepSnapshot.readPhone(), at: .now)
            #endif
            message = "Steps are unavailable. Unlock your device and check Health permissions, then refresh."
        }
    }

}

#if os(iOS)
import UserNotifications
import SwiftUI

struct WalkingPace {
    enum Result { case behind, ahead, typical }
    static func classify(steps: Int, history: [Int]) -> Result? {
        guard history.count >= 7 else { return nil }
        let baseline = Double(history.reduce(0, +)) / Double(history.count)
        guard baseline >= 500 else { return nil }
        if Double(steps) <= baseline * 0.75, baseline - Double(steps) >= 500 { return .behind }
        if Double(steps) >= baseline * 1.5, Double(steps) - baseline >= 500 { return .ahead }
        return .typical
    }
}

@MainActor
final class WalkingReminders: ObservableObject {
    static let shared = WalkingReminders()
    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: "smartRemindersEnabled")
    @Published private(set) var message: String?
    private let center = UNUserNotificationCenter.current()
    private let health = HKHealthStore()
    private var checking = false
    private var lastCheck: Date?

    func setEnabled(_ value: Bool) async {
        if !value {
            enabled = false
            UserDefaults.standard.set(false, forKey: "smartRemindersEnabled")
            center.removePendingNotificationRequests(withIdentifiers: ["walking-pace-afternoon", "walking-pace-evening"])
            message = nil
            return
        }
        do {
            let allowed = try await center.requestAuthorization(options: [.alert, .sound])
            enabled = allowed
            UserDefaults.standard.set(allowed, forKey: "smartRemindersEnabled")
            message = allowed ? nil : "Allow notifications for WalkingApp in iPhone Settings to enable reminders."
            if allowed { await evaluate() }
        } catch { message = "Couldn’t enable notifications. Please try again." }
    }

    func sendTestReminder() async {
        do {
            let allowed = try await center.requestAuthorization(options: [.alert, .sound])
            guard allowed else {
                message = "Allow notifications for WalkingApp in iPhone Settings to send a test."
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "Your walking reminder · Test"
            content.body = "Every day has its own rhythm. If it feels right, take a little walking break—you’ve got this!"
            content.sound = .default
            try await center.add(UNNotificationRequest(identifier: "walking-reminder-test", content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)))
            message = "Test scheduled for 5 seconds from now. Leave the app or lock your phone to see it."
        } catch { message = "Couldn’t schedule the test. Please try again." }
    }

    func evaluate(at now: Date = .now) async {
        guard enabled, !checking, HKHealthStore.isHealthDataAvailable() else { return }
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)
        let window: String
        let startHour: Int
        let endHour: Int
        switch hour {
        case 13..<15: window = "afternoon"; startHour = 13; endHour = 15
        case 18..<21: window = "evening"; startHour = 18; endHour = 21
        default: return
        }
        let day = calendar.startOfDay(for: now)
        let defaults = UserDefaults.standard
        let key = "walkingReminder-\(window)-\(day.timeIntervalSince1970)-\(calendar.timeZone.identifier)"
        if defaults.string(forKey: "walkingReminderDay") != day.description {
            for stored in defaults.dictionaryRepresentation().keys where stored.hasPrefix("walkingReminder-") {
                defaults.removeObject(forKey: stored)
            }
            defaults.set(day.description, forKey: "walkingReminderDay")
        }
        guard !defaults.bool(forKey: key + "-sent") else { return }
        let target: Date
        if let saved = defaults.object(forKey: key + "-target") as? Date { target = saved }
        else {
            let start = calendar.date(bySettingHour: startHour, minute: 0, second: 0, of: now)!
            let end = calendar.date(bySettingHour: endHour, minute: 0, second: 0, of: now)!
            target = start.addingTimeInterval(Double.random(in: 0..<end.timeIntervalSince(start)))
            defaults.set(target, forKey: key + "-target")
        }
        guard now >= target, lastCheck.map({ now.timeIntervalSince($0) >= 900 }) ?? true else { return }
        checking = true
        lastCheck = now
        defer { checking = false }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        do {
            guard let current = try await count(from: day, to: now) else { return }
            var history: [Int] = []
            let clock = calendar.dateComponents([.hour, .minute, .second], from: now)
            for offset in 1...14 {
                let start = calendar.date(byAdding: .day, value: -offset, to: day)!
                guard let end = calendar.date(bySettingHour: clock.hour!, minute: clock.minute!, second: clock.second!, of: start) else { continue }
                if let value = try await count(from: start, to: end) { history.append(value) }
            }
            guard enabled, calendar.isDateInToday(now), calendar.component(.hour, from: Date.now) < endHour,
                  let pace = WalkingPace.classify(steps: current, history: history), pace != .typical else { return }
            let content = UNMutableNotificationContent()
            content.title = pace == .ahead ? "You’re making strides!" : "A little walk goes a long way"
            let messages = pace == .ahead
                ? ["You’re ahead of your usual pace today. Nice work—keep moving in a way that feels good!", "Look at you go! You’re walking more than usual today. Every step is worth celebrating."]
                : ["A few fresh-air steps could brighten your day. There’s still time to build a little momentum!", "Your usual pace is a little higher by now. A short, easy walk is a lovely way to get moving.", "Every day has its own rhythm. If it feels right, take a little walking break—you’ve got this!"]
            content.body = messages.randomElement()!
            content.sound = .default
            let request = UNNotificationRequest(identifier: "walking-pace-\(window)", content: content, trigger: nil)
            try await center.add(request)
            defaults.set(true, forKey: key + "-sent")
        } catch {
            // Locked or unavailable Health data must never generate a guessed pace reminder.
        }
    }

    private func count(from start: Date, to end: Date) async throws -> Int? {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let query = HKStatisticsQueryDescriptor(predicate: HKSamplePredicate.quantitySample(type: HKQuantityType(.stepCount), predicate: predicate), options: .cumulativeSum)
        let result = try await query.result(for: health)
        return result?.sumQuantity().map { Int($0.doubleValue(for: .count()).rounded()) }
    }
}

struct WalkingReminderSettings: View {
    @ObservedObject private var reminders = WalkingReminders.shared
    @State private var requesting = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: Binding(get: { reminders.enabled }, set: { value in
                requesting = true
                Task { await reminders.setEnabled(value); requesting = false }
            })) {
                Label("Smart walking reminders", systemImage: "bell.badge")
                    .font(.headline)
            }
            .disabled(requesting)
            Text("Positive nudges when behind your usual pace, and encouragement when well ahead. Random check times between 1–3 p.m. and 6–9 p.m.; at most two notifications per day.")
                .font(.subheadline).foregroundStyle(.white.opacity(0.75))
            Text("Uses at least 7 recorded days from the past 14, compared at the same time of day. Checks happen when iOS allows background updates or you open the app. Locked Health data or limited history may mean no reminder. Analysis stays on your iPhone.")
                .font(.caption).foregroundStyle(.white.opacity(0.65))
            Button {
                requesting = true
                Task { await reminders.sendTestReminder(); requesting = false }
            } label: {
                Label("Send test reminder", systemImage: "bell.and.waves.left.and.right")
                    .font(.subheadline.weight(.semibold))
            }
            .disabled(requesting)
            .foregroundStyle(WalkingStyle.accent)
            Text("The test arrives after 5 seconds and doesn’t count toward your daily reminders.")
                .font(.caption).foregroundStyle(.white.opacity(0.65))
            if let message = reminders.message { Text(message).font(.caption).foregroundStyle(WalkingStyle.accent) }
        }
        .padding(20)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 20))
    }
}
#endif
