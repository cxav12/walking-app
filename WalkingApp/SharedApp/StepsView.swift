import SwiftUI
import WidgetKit

struct StepsView: View {
    @StateObject private var model = StepsModel()
    @ObservedObject private var goals = GoalSync.shared
    @State private var showingSettings = false
    #if os(iOS)
    @AppStorage("lastGoalCelebrationDay") private var lastGoalCelebrationDay = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var celebration = false
    @State private var celebrationFeedback = 0
    #endif
    @AppStorage("displayName") private var displayName = ""
    @Environment(\.scenePhase) private var scenePhase

    private var isWatch: Bool {
        #if os(watchOS)
        true
        #else
        false
        #endif
    }

    var body: some View {
        ZStack {
            #if os(iOS)
            WalkingBackdrop()
            #else
            WalkingStyle.background.ignoresSafeArea()
            #endif
            ScrollView {
                VStack(alignment: .leading, spacing: isWatch ? 16 : 18) {
                    HStack {
                        Label("Walking", systemImage: "figure.walk")
                            .font(isWatch ? .headline : .title2.bold())
                            .foregroundStyle(isWatch ? WalkingStyle.accent : .white)
                        Spacer()
                        #if os(iOS)
                        Text(Date.now, format: .dateTime.month(.abbreviated).day())
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.6))
                        #endif
                        Button { showingSettings = true } label: {
                            Image(systemName: "gearshape")
                                .font(.title3)
                                .foregroundStyle(isWatch ? WalkingStyle.accent : .white)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Settings")
                        .accessibilityIdentifier("openSettings")
                    }
                    #if os(iOS)
                    Text(displayName.isEmpty ? "Welcome back" : "Welcome back, \(displayName)")
                        .font(.title2.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    #endif
                    #if os(iOS)
                    WeeklyRecapView(goal: goals.goal.steps, refreshDate: model.snapshot.date)
                    #endif
                    stepCard
                    #if os(iOS)
                    SleepCard(refreshDate: model.snapshot.date)
                    StepTrendsView(refreshDate: model.snapshot.date)
                    GoalStreaksView(goal: goals.goal.steps, refreshDate: model.snapshot.date)
                    StepHistoryView(refreshDate: model.snapshot.date)
                    FriendsStepsView(todaySteps: model.snapshot.count, refreshDate: model.snapshot.date)
                    if model.snapshot.count != nil {
                        Text("Steps updated \(model.snapshot.date.formatted(date: .omitted, time: .shortened)) · Pull down to refresh")
                            .font(.caption).foregroundStyle(.white.opacity(0.65))
                            .frame(maxWidth: .infinity)
                    }
                    #endif

                }
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
                .padding(isWatch ? 12 : 14)
            }
            #if os(iOS)
            .refreshable { await model.refresh(forceWidgetSync: true) }
            #endif
        }
        #if os(iOS)
        .onChange(of: model.snapshot.count) { _, _ in celebrateGoalIfNeeded() }
        .onChange(of: goals.goal.steps) { _, _ in celebrateGoalIfNeeded() }
        .sensoryFeedback(.success, trigger: celebrationFeedback)
        #endif
        .foregroundStyle(.white)
        .tint(WalkingStyle.accent)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingSettings) { StepsSettingsView(model: model, goals: goals) }
        .task {
            goals.start()
            await model.refresh()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { goals.start(); Task { await model.refresh() } }
            if phase == .background { WidgetCenter.shared.reloadTimelines(ofKind: "TodaySteps") }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                await model.refresh()
            }
        }
    }
    #if os(iOS)
    private func celebrateGoalIfNeeded() {
        guard let count = model.snapshot.count, let goal = goals.goal.steps,
              count >= goal, Calendar.current.isDateInToday(model.snapshot.date) else { return }
        let day = Calendar.current.startOfDay(for: model.snapshot.date).timeIntervalSince1970.description
        guard lastGoalCelebrationDay != day else { return }
        lastGoalCelebrationDay = day
        celebrationFeedback += 1
        guard !reduceMotion else { return }
        celebration = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            celebration = false
        }
    }
    #endif
    private var stepCard: some View {
        VStack(alignment: .leading, spacing: isWatch ? 12 : 14) {
            #if os(iOS)
            WalkingCardTitle(title: "Today’s steps", systemImage: "shoeprints.fill")
            #else
            Label("TODAY’S STEPS", systemImage: "shoeprints.fill")
                .font(.caption.weight(.semibold))
                .tracking(1.4)
                .foregroundStyle(.white.opacity(0.65))
            #endif
            Text(model.snapshot.count?.formatted() ?? "—")
                .font(.system(size: isWatch ? 48 : 68, weight: .bold, design: .rounded))
                .monospacedDigit()
                #if os(iOS)
                .modifier(WalkingNumberMotion(value: model.snapshot.count?.formatted() ?? "—"))
                #endif
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .privacySensitive()
                .frame(maxWidth: .infinity, alignment: .leading)
            if let goal = goals.goal.steps {
                SegmentedStepProgress(progress: goals.goal.progress(for: model.snapshot.count) ?? 0,
                                      height: isWatch ? 9 : WalkingStyle.progressSegmentHeight,
                                      spacing: isWatch ? 3 : WalkingStyle.progressSegmentSpacing)
                HStack(alignment: .firstTextBaseline) {
                    if let count = model.snapshot.count {
                        if count >= goal {
                            Label("Goal reached!", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(WalkingStyle.accent)
                        } else {
                            Text("\(max(0, goal - count).formatted()) remaining")
                        }
                    } else {
                        Text("Steps unavailable")
                    }
                    Spacer(minLength: 4)
                    Text(goal.formatted())
                        .foregroundStyle(.white.opacity(0.6))
                        .accessibilityLabel("Daily goal: \(goal.formatted()) steps")
                }
                .font(isWatch ? .caption : .subheadline)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            } else {
                Text("Every step counts. Set your daily goal in Settings.")
                    .font(isWatch ? .caption : .subheadline)
                    .foregroundStyle(.white.opacity(0.65))
            }

        }
        .padding(isWatch ? 14 : 24)
        #if os(iOS)
        .modifier(WalkingGlassCard())
        .overlay { if celebration && !reduceMotion { GoalSparkles() } }
        #else
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: isWatch ? 20 : 28))
        .overlay {
            RoundedRectangle(cornerRadius: isWatch ? 20 : 28)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        }
        #endif
    }


}

#Preview { StepsView() }

#if os(iOS)
struct ProfileNameEditor: View {
    @AppStorage("displayName") private var displayName = ""
    @State private var input = ""
    @Environment(\.dismiss) private var dismiss

    private var name: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Your name", text: $input)
                        .textContentType(.givenName)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { save() }
                } header: {
                    Text("What should we call you?")
                } footer: {
                    Text("Your name is saved on this iPhone. Open Settings to change it anytime.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(WalkingStyle.background)
            .navigationTitle("Your Name")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(name.isEmpty)
                }
            }
            .onAppear { input = displayName }
        }
        .tint(WalkingStyle.accent)
        .preferredColorScheme(.dark)
    }

    private func save() {
        guard !name.isEmpty else { return }
        displayName = name
        dismiss()
    }
}
#endif
