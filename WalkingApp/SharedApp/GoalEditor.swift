#if os(iOS)
import SwiftUI

struct GoalEditor: View {
    @ObservedObject var settings: GoalSync
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Steps per day", text: $input)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("dailyGoalInput")
                } header: {
                    Text("What’s your daily step goal?")
                } footer: {
                    Text("Choose a positive whole number, without commas. You can change or remove your goal anytime.")
                }
                if !input.isEmpty, DailyGoal.parse(input) == nil {
                    Text("Enter a positive whole number.").foregroundStyle(.red)
                }
                if let message = settings.message {
                    Text(message).foregroundStyle(.secondary)
                }
                if settings.goal.steps != nil {
                    Button("Remove Goal", role: .destructive) {
                        if settings.save(steps: nil) { dismiss() }
                    }
                }
                Section {
                    Text("Your goal also appears on your Watch when it connects. Open WalkingWatch once after installing the update.")
                        .foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(WalkingStyle.background)
            .navigationTitle("Daily Step Goal")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let steps = DailyGoal.parse(input), settings.save(steps: steps) { dismiss() }
                    }
                    .disabled(DailyGoal.parse(input) == nil)
                }
            }
            .onAppear { input = settings.goal.steps.map(String.init) ?? "" }
        }
        .tint(WalkingStyle.accent)
        .preferredColorScheme(.dark)
    }
}
#endif
