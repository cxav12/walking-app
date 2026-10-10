import SwiftUI

struct StepsSettingsView: View {
    @ObservedObject var model: StepsModel
    @ObservedObject var goals: GoalSync
    @AppStorage("displayName") private var displayName = ""
    @Environment(\.dismiss) private var dismiss
    @State private var editingName = false
    @State private var editingGoal = false

    var body: some View {
        NavigationStack {
            ZStack {
                WalkingStyle.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        #if os(iOS)
                        VStack(spacing: 0) {
                            Button { editingName = true } label: {
                                settingsRow("Your name", value: displayName.isEmpty ? "Add your name" : displayName,
                                            icon: "person.crop.circle")
                            }
                            Divider().overlay(.white.opacity(0.08))
                            Button { editingGoal = true } label: {
                                settingsRow("Daily goal", value: goals.goal.steps.map { "\($0.formatted()) steps" } ?? "Set a goal",
                                            icon: "target")
                            }
                            .accessibilityIdentifier("editDailyGoal")
                        }
                        .buttonStyle(.plain)
                        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 20))
                        #else
                        Text("Set your name and daily goal in Settings on iPhone.")
                            .font(.caption).foregroundStyle(.white.opacity(0.65))
                        #endif
                        #if os(iOS)
                        WalkingReminderSettings()
                        #endif
                        StepsHealthSection(model: model, goals: goals)
                    }
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity)
                    .padding()
                }
            }
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $editingName) { ProfileNameEditor() }
            .sheet(isPresented: $editingGoal) { GoalEditor(settings: goals) }
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .foregroundStyle(.white)
        .tint(WalkingStyle.accent)
        .preferredColorScheme(.dark)
    }

    private func settingsRow(_ title: String, value: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(WalkingStyle.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(value).font(.subheadline).foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.white.opacity(0.5))
        }
        .padding(18)
        .contentShape(Rectangle())
    }
}

private struct StepsHealthSection: View {
    @ObservedObject var model: StepsModel
    @ObservedObject var goals: GoalSync
    private var isWatch: Bool {
        #if os(watchOS)
        true
        #else
        false
        #endif
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Apple Health", systemImage: "heart.fill")
                .font(.headline)
                .foregroundStyle(WalkingStyle.accent)
            if let message = goals.message { Text(message).font(.footnote) }
            if let message = model.message { Text(message).font(.footnote) }
            Text(model.snapshot.count == nil
                 ? "Connect Health to see your steps. If access was denied, enable Steps in Health permissions."
                 : "Your daily steps come from Apple Health.")
                .font(isWatch ? .caption : .subheadline)
                .foregroundStyle(.white.opacity(0.65))
            Button { Task { await model.connect() } } label: {
                Text("Connect Apple Health")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(red: 0.08, green: 0.13, blue: 0.10))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(WalkingStyle.accent, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .disabled(model.isLoading)
            Button { Task { await model.refresh(forceWidgetSync: true) } } label: {
                HStack {
                    if model.isLoading { ProgressView().tint(WalkingStyle.accent) }
                    Label("Refresh steps", systemImage: "arrow.clockwise")
                }
                .font(.subheadline)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .foregroundStyle(WalkingStyle.accent)
            .disabled(model.isLoading)
        }
        .padding(isWatch ? 14 : 20)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 20))
    }

}
