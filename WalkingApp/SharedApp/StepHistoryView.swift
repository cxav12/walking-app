#if os(iOS)
import SwiftUI

struct StepHistoryView: View {
    @StateObject private var model = StepHistoryModel()
    @Namespace private var toggleHighlight
    @State private var range: StepHistoryRange = .week
    @State private var selectedDate: Date?
    @State private var revealBars = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    let refreshDate: Date

    private var selected: StepHistoryPoint? {
        model.summary.points.first { $0.date == selectedDate }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            WalkingCardTitle(title: "Step History", systemImage: "chart.bar.fill")
            HStack(spacing: 0) {
                ForEach(StepHistoryRange.allCases) { period in
                    Button { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { range = period } } label: {
                        Text(period == .week ? "Week" : period == .month ? "Month" : "Year")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(range == period ? Color(red: 0.02, green: 0.3, blue: 0.65) : .white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background {
                                if range == period {
                                    Capsule().fill(LinearGradient(colors: [WalkingStyle.accent, .cyan.opacity(0.65)], startPoint: .leading, endPoint: .trailing))
                                        .matchedGeometryEffect(id: "selection", in: toggleHighlight)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(period == .week ? "Week" : period == .month ? "Month" : "Year")
                    .accessibilityAddTraits(range == period ? [.isSelected] : [])
                }
            }
            .padding(2)
            .background(.white.opacity(0.1), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.2)))
            Text(range.title).font(.subheadline).foregroundStyle(.white.opacity(0.65))
            HStack(alignment: .center, spacing: 8) {
                Text(model.summary.average?.formatted() ?? "—")
                    .modifier(WalkingNumberMotion(value: model.summary.average?.formatted() ?? "—"))
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("avg steps / recorded day")
                    .font(.caption).foregroundStyle(.white.opacity(0.65))
            }
            if model.isLoading {
                ProgressView().tint(WalkingStyle.accent)
                    .frame(maxWidth: .infinity, minHeight: 210)
            } else if let message = model.message {
                Text(message).font(.footnote).foregroundStyle(.white.opacity(0.65))
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
            } else {
                graph
                    .onAppear { revealBars = true }
                if let selected {
                    Text("\(selected.date.formatted(date: .abbreviated, time: .omitted)): \(selected.count?.formatted() ?? (selected.date > Date.now ? "Upcoming" : "No data"))\(selected.count == nil ? "" : range == .year ? " avg steps/day" : " steps")")
                        .font(.caption).foregroundStyle(WalkingStyle.accent)
                }
                Text(range == .month ? "Tap a bar for its date and steps. Hollow dots mean no recorded data. Missing days are excluded from the average; today is in progress." : "Tap a bar for details. Missing data is excluded from the average. Today is still in progress.")
                    .font(.caption2).foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(20)
        .modifier(WalkingGlassCard(radius: 24))
        .privacySensitive()
        .task(id: range) {
            selectedDate = nil
            await model.load(range)
        }
        .task(id: refreshDate) {
            model.invalidateCache()
            await model.load(range)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.load(range) } }
        }
    }

    private var graph: some View {
        let ceiling = model.summary.ceiling
        let ticks = Array(stride(from: ceiling, through: 0, by: -5000))
        return HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 0) {
                ForEach(ticks, id: \.self) { tick in
                    Text(tick == 0 ? "0" : "\(tick / 1000)k")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                        .frame(height: 12)
                    if tick != 0 { Spacer(minLength: 0) }
                }
            }
            .frame(width: 27, height: 207)
            VStack(spacing: 8) {
                GeometryReader { geometry in
                    ZStack {
                        VStack(spacing: 0) {
                            ForEach(ticks, id: \.self) { tick in
                                Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                                if tick != 0 { Spacer(minLength: 0) }
                            }
                        }
                        HStack(alignment: .bottom, spacing: range == .month ? 3 : 6) {
                            ForEach(Array(model.summary.points.enumerated()), id: \.element.id) { index, point in
                                Button { selectedDate = point.date } label: {
                                    roundedColumn(point, ceiling: ceiling,
                                                  height: geometry.size.height, index: index)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(point.date.formatted(date: .abbreviated, time: .omitted))
                                .accessibilityValue(point.count.map { "\($0.formatted()) steps" } ?? (point.date > Date.now ? "Upcoming" : "No data"))
                            }
                        }
                    }
                }
                .frame(height: 195)
                if range == .month {
                    GeometryReader { axis in
                        let points = model.summary.points
                        let indices = [0, 7, 14, 21, 29].filter { $0 < points.count }
                        ForEach(Array(indices.enumerated()), id: \.element) { position, index in
                            Text(points[index].date.formatted(.dateTime.month(.abbreviated).day()))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(1)
                                .fixedSize()
                                .frame(width: 54, height: 18)
                                .position(x: 27 + max(0, axis.size.width - 54) * Double(position) / Double(max(1, indices.count - 1)), y: 9)
                        }
                    }
                    .frame(height: 18)
                } else {
                    GeometryReader { axis in
                        let count = max(1, model.summary.points.count)
                        let cellWidth = max(0, (axis.size.width - CGFloat(count - 1) * 6) / CGFloat(count))
                        ForEach(Array(model.summary.points.enumerated()), id: \.element.id) { index, point in
                            Text(axisLabel(point.date, index: index))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.75))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .frame(width: cellWidth, height: 18)
                                .position(x: cellWidth / 2 + CGFloat(index) * (cellWidth + 6), y: 9)
                        }
                    }
                    .frame(height: 18)
                }
            }
            .padding(.top, 6)
        }
    }

    private func roundedColumn(_ point: StepHistoryPoint, ceiling: Int, height: CGFloat, index: Int) -> some View {
        let fraction = min(1, max(0, Double(point.count ?? 0) / Double(ceiling)))
        let highlighted = selectedDate.map { $0 == point.date } ?? (range == .week ? Calendar.current.isDateInToday(point.date) : point.date == model.summary.points.last?.date)
        let position = Double(index) / Double(max(1, model.summary.points.count - 1))
        let barColor = Color(red: 0.3 + 0.65 * position, green: 0.92 - 0.3 * position, blue: 1 - 0.75 * position)
        return RoundedRectangle(cornerRadius: range == .month ? 5 : 12)
            .fill(LinearGradient(colors: [highlighted ? .white : barColor, barColor.opacity(0.65)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay {
                RoundedRectangle(cornerRadius: range == .month ? 5 : 12)
                    .strokeBorder(.white.opacity(highlighted ? 0.6 : 0.2), lineWidth: 1)
            }
            .frame(height: revealBars ? height * fraction : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.65).delay(Double(index) * 0.02), value: revealBars)
            .frame(maxWidth: .infinity)
            .frame(height: height, alignment: .bottom)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                if point.count == nil, point.date <= Date.now {
                    if range == .month {
                        Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1)
                            .frame(width: 4, height: 4)
                    } else {
                        Text("—").font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
                    }
                }
            }
    }

    private func axisLabel(_ date: Date, index: Int) -> String {
        switch range {
        case .week: return date.formatted(.dateTime.weekday(.abbreviated))
        case .month: return index % 5 == 0 ? date.formatted(.dateTime.day()) : ""
        case .year: return date.formatted(.dateTime.month(.narrow))
        }
    }
}
#endif

#if os(iOS)
enum StepTrendPeriod: String, CaseIterable, Identifiable {
    case week = "Week", month = "Month", year = "Year"
    var id: String { rawValue }
    var days: Int {
        switch self { case .week: 7; case .month: 30; case .year: 365 }
    }
}

struct StepTrendsView: View {
    @StateObject private var model = StepHistoryModel()
    @Namespace private var toggleHighlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var period: StepTrendPeriod = .week
    @Environment(\.scenePhase) private var scenePhase
    let refreshDate: Date

    private var trend: StepTrendSummary {
        StepTrendSummary(points: model.summary.points, days: period.days)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WalkingCardTitle(title: "Trends", systemImage: "chart.line.uptrend.xyaxis")
            HStack(spacing: 0) {
                ForEach(StepTrendPeriod.allCases) { option in
                    Button { period = option } label: {
                        Text(option.rawValue)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(period == option ? Color(red: 0.02, green: 0.3, blue: 0.65) : .white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background {
                                if period == option { Capsule().fill(WalkingStyle.accent).matchedGeometryEffect(id: "selection", in: toggleHighlight) }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(period == option ? [.isSelected] : [])
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: period)
            .padding(2)
            .background(.white.opacity(0.1), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.2)))
            Text("Last \(period.days) completed days")
                .font(.subheadline).foregroundStyle(.white.opacity(0.75))
                HStack(alignment: .center, spacing: 8) {
                    Text(trend.average?.formatted() ?? "—")
                        .modifier(WalkingNumberMotion(value: trend.average?.formatted() ?? "—"))
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("avg steps / recorded day")
                        .font(.caption).foregroundStyle(.white.opacity(0.8))
                }
                HStack(alignment: .top, spacing: 12) {
                    stat("Total steps", value: trend.recent.isEmpty ? "—" : trend.recent.reduce(0, +).formatted(), detail: "Last \(period.days) days")
                    stat("Best day", value: trend.bestDay?.count?.formatted() ?? "—", detail: trend.bestDay?.date.formatted(.dateTime.month(.abbreviated).day().year()))
                }
            ZStack(alignment: .topLeading) {
                // Reserve only the tallest comparison, rather than adding their heights.
                ZStack(alignment: .topLeading) {
                    Text("Comparison unavailable · Needs 730 recorded days and a nonzero previous total.")
                        .font(.footnote)
                    Label("100% more steps than the previous month", systemImage: "arrow.up.right")
                        .font(.subheadline.weight(.semibold))
                }
                .hidden()
                .accessibilityHidden(true)
                if let message = model.message {
                    Text(message).font(.footnote).foregroundStyle(.white.opacity(0.8))
                } else if let change = trend.changePercent {
                    let rounded = Int(change.rounded())
                    Label(rounded == 0 ? "About the same as the previous \(period.rawValue.lowercased())" : "\(abs(rounded))% \(rounded > 0 ? "more" : "fewer") steps than the previous \(period.rawValue.lowercased())",
                          systemImage: rounded == 0 ? "arrow.right" : rounded > 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(WalkingStyle.accent)
                } else {
                    Text(model.isLoading ? "Loading step history…" : "Comparison unavailable · Needs \(period.days * 2) recorded days and a nonzero previous total.")
                        .font(.footnote).foregroundStyle(.white.opacity(0.8))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .modifier(WalkingGlassCard(radius: 24))
        .privacySensitive()
        .task { await model.load(.month, dailyDays: 730) }
        .onChange(of: refreshDate) { _, _ in
            model.invalidateCache()
            Task { await model.load(.month, dailyDays: 730) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.load(.month, dailyDays: 730) } }
        }
    }

    private func stat(_ title: String, value: String, detail: String? = nil) -> some View {
        VStack(alignment: .center, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.8))
            Text(value)
                .modifier(WalkingNumberMotion(value: value))
                .font(.system(size: 25, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Text(detail ?? "—")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(12)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.12))
        }
    }
}
#endif

#if os(iOS)
enum FriendsStepPeriod: String, CaseIterable, Identifiable {
    case day = "D", week = "W", year = "Y"
    var id: String { rawValue }
    var title: String {
        switch self { case .day: "Today"; case .week: "This week"; case .year: "This year" }
    }

    func start(at now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .day: calendar.startOfDay(for: now)
        case .week: calendar.dateInterval(of: .weekOfYear, for: now)!.start
        case .year: calendar.dateInterval(of: .year, for: now)!.start
        }
    }
}


struct FriendsStepsView: View {
    let todaySteps: Int?
    let refreshDate: Date
    @StateObject private var history = StepHistoryModel()
    @ObservedObject private var connection = FriendsConnection.shared
    @Namespace private var toggleHighlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var period: FriendsStepPeriod = .day
    @State private var showingConnection = false
    @State private var lastHistoryRefresh: Date?
    @AppStorage("displayName") private var displayName = ""
    @Environment(\.scenePhase) private var scenePhase

    private var total: Int? {
        if period == .day { return todaySteps }
        let values = history.summary.points.filter { $0.date >= period.start(at: .now) }.compactMap(\.count)
        return values.isEmpty ? nil : values.reduce(0, +)
    }
    private var largest: Int { max(1, max(total ?? 0, connection.friends.compactMap(\.steps).max() ?? 0)) }
    private var refreshKey: String { "\(period.rawValue)-\(refreshDate.timeIntervalSince1970)-\(connection.signedIn)-\(connection.profile?.sharing_enabled == true)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                WalkingCardTitle(title: "Friends", systemImage: "person.2.fill")
                Spacer()
                Button { showingConnection = true } label: {
                    Image(systemName: "person.badge.plus").font(.title3).frame(width: 44, height: 44)
                }
                .buttonStyle(.plain).accessibilityLabel("Manage friends")
            }
            HStack(spacing: 0) {
                ForEach(FriendsStepPeriod.allCases) { option in
                    Button { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { period = option } } label: {
                        Text(option.rawValue).font(.subheadline.weight(.semibold))
                            .foregroundStyle(period == option ? Color(red: 0.02, green: 0.3, blue: 0.65) : .white)
                            .frame(maxWidth: .infinity).padding(.vertical, 9)
                            .background { if period == option { Capsule().fill(WalkingStyle.accent).matchedGeometryEffect(id: "selection", in: toggleHighlight) } }
                    }
                    .buttonStyle(.plain).accessibilityLabel(option.title)
                    .accessibilityAddTraits(period == option ? [.isSelected] : [])
                }
            }
            .padding(2).background(.white.opacity(0.1), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.2)))
            Text(period.title).font(.subheadline).foregroundStyle(.white.opacity(0.8))
            if history.isLoading { ProgressView().frame(maxWidth: .infinity) }
            let participants = rows
            ForEach(participants) { person in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: person.isYou ? "person.crop.circle.fill" : "person.crop.circle")
                            .font(.title2).foregroundStyle(person.isYou ? WalkingStyle.accent : WalkingStyle.secondaryAccent)
                        Text(person.name).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(person.steps.map { "\($0.formatted()) steps" } ?? "Not shared yet")
                            .font(.subheadline.weight(.semibold)).monospacedDigit()
                    }
                    GeometryReader { geometry in
                        Capsule().fill(.white.opacity(0.15))
                            .overlay(alignment: .leading) {
                                if let steps = person.steps {
                                    Capsule().fill(person.isYou ? WalkingStyle.accent : WalkingStyle.secondaryAccent)
                                        .frame(width: geometry.size.width * Double(steps) / Double(largest))
                                }
                            }
                    }
                    .frame(height: 10)
                    .accessibilityLabel("\(person.name) steps")
                    .accessibilityValue(person.steps?.formatted() ?? "Unavailable")
                    if let date = person.updatedAt {
                        Text("Updated \(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2).foregroundStyle(.white.opacity(0.75))
                    }
                }
                .padding(14).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            }
            if connection.friends.isEmpty {
                Button(connection.signedIn ? "Invite a friend" : "Connect with friends") { showingConnection = true }
                    .font(.subheadline.weight(.semibold)).foregroundStyle(WalkingStyle.accent)
                Text("Compare steps with your walking circle. No challenges—just motivation.")
                    .font(.footnote).foregroundStyle(.white.opacity(0.8))
            }
            if let message = connection.message {
                Text(message).font(.caption).foregroundStyle(.white.opacity(0.85))
            }
        }
        .padding(20).modifier(WalkingGlassCard(radius: 24)).privacySensitive()
        .sheet(isPresented: $showingConnection, onDismiss: { Task { await refresh() } }) { FriendsConnectionView() }
        .task(id: refreshKey) { await refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await refresh() } } }
    }

    private struct PersonRow: Identifiable {
        let id: String
        let name: String
        let steps: Int?
        let isYou: Bool
        let updatedAt: Date?
    }
    private var rows: [PersonRow] {
        let formatter = ISO8601DateFormatter()
        let mine = PersonRow(id: "you", name: displayName.isEmpty ? "You" : "\(displayName) (you)", steps: total, isYou: true, updatedAt: nil)
        let friends = connection.friends.map { friend in
            PersonRow(id: friend.id.uuidString, name: friend.display_name, steps: friend.steps, isYou: false,
                      updatedAt: friend.updated_at.flatMap { value in
                          formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                          if let date = formatter.date(from: value) { return date }
                          formatter.formatOptions = [.withInternetDateTime]
                          return formatter.date(from: value)
                      })
        }
        return ([mine] + friends).sorted {
            if $0.steps == $1.steps { return $0.name < $1.name }
            return ($0.steps ?? -1) > ($1.steps ?? -1)
        }
    }

    private func dateKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    private func refresh() async {
        if lastHistoryRefresh != refreshDate {
            history.invalidateCache()
            lastHistoryRefresh = refreshDate
        }
        let needsHistory = period != .day || connection.profile?.sharing_enabled == true
        if needsHistory {
            let days = Calendar.current.dateComponents([.day], from: FriendsStepPeriod.year.start(at: .now), to: .now).day ?? 0
            await history.load(.month, dailyDays: days)
            guard !Task.isCancelled else { return }
        }
        if connection.profile?.sharing_enabled == true {
            for option in FriendsStepPeriod.allCases {
                let start = option.start(at: .now)
                let values = history.summary.points.filter { $0.date >= start }.compactMap(\.count)
                let count = option == .day ? todaySteps : values.isEmpty ? nil : values.reduce(0, +)
                if let count { await connection.sync(period: option.rawValue, start: dateKey(start), steps: count) }
            }
        }
        await connection.refresh(period: period.rawValue, start: dateKey(period.start(at: .now)))
    }
}

struct FriendsConnectionView: View {
    @ObservedObject private var connection = FriendsConnection.shared
    @AppStorage("displayName") private var displayName = ""
    @State private var profileName = ""
    @State private var friendCode = ""
    @State private var confirmSharing = false
    @State private var removing: WalkingFriend?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if !connection.signedIn {
                    Section("Your walking profile") {
                        TextField("Your name", text: $profileName)
                            .textContentType(.givenName).textInputAutocapitalization(.words)
                        Button("Create my friend code") {
                            Task { await connection.createDeviceProfile(name: profileName.trimmingCharacters(in: .whitespacesAndNewlines)) }
                        }
                        .disabled(profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || connection.busy)
                    }
                    Section {
                        Text("No email or password needed. Your profile is saved on this iPhone. Your friend code lets people request to connect; it cannot restore your profile if you lose access to this device.")
                        Text("Your steps stay on your phone until you enable sharing.")
                    }
                } else if let profile = connection.profile {
                    Section("Your friend code") {
                        Text(profile.friend_code).font(.headline.monospaced()).textSelection(.enabled)
                        ShareLink(item: "Add me in WalkingApp with friend code: \(profile.friend_code)") { Label("Share friend code", systemImage: "square.and.arrow.up") }
                    }
                    Section {
                        Toggle("Share my step totals", isOn: Binding(get: { connection.profile?.sharing_enabled == true }, set: { enabled in
                            if enabled { confirmSharing = true } else { Task { await connection.setSharing(false) } }
                        }))
                        .disabled(connection.busy)
                    } footer: {
                        Text("Only accepted friends can see your shared totals. Turning sharing off removes your uploaded totals.")
                    }
                    Section("Add a friend") {
                        TextField("Friend code", text: $friendCode).textInputAutocapitalization(.characters).autocorrectionDisabled()
                        Button("Send friend request") { Task { await connection.invite(code: friendCode) } }
                            .disabled(friendCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || connection.busy)
                    }
                    if !connection.requests.isEmpty {
                        Section("Friend requests") {
                            ForEach(connection.requests) { request in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(request.display_name).font(.headline)
                                    if request.incoming {
                                        HStack {
                                            Button("Accept") { Task { await connection.respond(user: request.user_id, accept: true) } }
                                            Spacer()
                                            Button("Decline", role: .destructive) { Task { await connection.respond(user: request.user_id, accept: false) } }
                                        }
                                        .buttonStyle(.borderless)
                                    } else {
                                        HStack {
                                            Text("Waiting for acceptance").font(.caption)
                                            Spacer()
                                            Button("Cancel") { Task { await connection.remove(user: request.user_id) } }
                                                .buttonStyle(.borderless)
                                        }
                                    }
                                }
                            }
                        }
                        .disabled(connection.busy)
                    }
                    if !connection.friends.isEmpty {
                        Section("Friends") {
                            ForEach(connection.friends) { friend in
                                HStack {
                                    Text(friend.display_name)
                                    Spacer()
                                    Button("Remove", role: .destructive) { removing = friend }.buttonStyle(.borderless)
                                }
                            }
                        }
                    }

                } else {
                    ProgressView("Loading your profile…")
                }
                if connection.busy { ProgressView() }
                if let message = connection.message { Section { Text(message).font(.footnote) } }
            }
            .scrollContentBackground(.hidden).background(WalkingBackdrop())
            .navigationTitle("Friends").navigationBarTitleDisplayMode(.inline)
            .onAppear { if profileName.isEmpty { profileName = displayName } }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .alert("Share steps with friends?", isPresented: $confirmSharing) {
                Button("Enable sharing") { Task { await connection.setSharing(true) } }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Your daily, weekly, and yearly step totals and update times will be uploaded to WalkingApp’s Supabase service and visible to accepted friends. You can stop sharing anytime.")
            }
            .alert("Remove friend?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
                Button("Remove", role: .destructive) {
                    if let friend = removing { Task { await connection.remove(user: friend.user_id) } }
                    removing = nil
                }
                Button("Cancel", role: .cancel) { removing = nil }
            } message: { Text("You will no longer be able to view each other’s step totals.") }
        }
        .tint(WalkingStyle.accent).preferredColorScheme(.dark)
    }
}
#endif

#if os(iOS)
struct GoalStreaksView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let goal: Int?
    let refreshDate: Date
    @StateObject private var model = StepHistoryModel()
    @Environment(\.scenePhase) private var scenePhase

    private var streak: GoalStreakSummary {
        GoalStreakSummary(points: model.summary.points, goal: goal ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WalkingCardTitle(title: "Goal Streaks", systemImage: "flame.fill")
                .symbolEffect(.pulse, options: .nonRepeating, value: reduceMotion ? 0 : streak.current)
            if let goal {
                HStack(spacing: 12) {
                    tile("Current streak", days: streak.current)
                    tile("Longest streak", days: streak.longest)
                }
                Text(model.isLoading && model.summary.points.isEmpty ? "Loading your streaks…" : streak.missingYesterday ? "Yesterday’s steps are unavailable, so your current streak can’t be confirmed." : streak.current > 0 ? "Keep it going! Reach your goal today to continue your streak." : "Reach your goal today to start a new streak.")
                    .font(.subheadline).foregroundStyle(WalkingStyle.accent)
                if let message = model.message {
                    Text(message).font(.caption).foregroundStyle(.white.opacity(0.75))
                }
                Text("Based on completed days in the last 2 years and your current \(goal.formatted())-step goal. Missing days interrupt a streak; today is still in progress.")
                    .font(.caption).foregroundStyle(.white.opacity(0.65))
            } else {
                Text("Set a daily step goal in Settings to start tracking streaks.")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.75))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .modifier(WalkingGlassCard(radius: 24))
        .privacySensitive()
        .task(id: refreshDate) {
            model.invalidateCache()
            await model.load(.month, dailyDays: 730)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.load(.month, dailyDays: 730) } }
        }
    }

    private func tile(_ title: String, days: Int) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.8))
            Text(model.summary.points.isEmpty ? "—" : days.formatted())
                .modifier(WalkingNumberMotion(value: days.formatted()))
                .font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
            Text(days == 1 ? "day" : "days").font(.caption).foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.12)))
    }
}
#endif

#if os(iOS)
struct WeeklyRecapView: View {
    let goal: Int?
    let refreshDate: Date
    @StateObject private var model = StepHistoryModel()
    private var recap: WeeklyRecapSummary { WeeklyRecapSummary(points: model.summary.points) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WalkingCardTitle(title: "Weekly Recap", systemImage: "calendar.badge.checkmark")
            Text("\(recap.start.formatted(.dateTime.month(.abbreviated).day())) – \(Calendar.current.date(byAdding: .day, value: -1, to: recap.end)!.formatted(.dateTime.month(.abbreviated).day())) · Last week")
                .font(.subheadline).foregroundStyle(.white.opacity(0.75))
            HStack(alignment: .center, spacing: 8) {
                Text(recap.average?.formatted() ?? "—")
                    .modifier(WalkingNumberMotion(value: recap.average?.formatted() ?? "—"))
                    .font(.system(size: 36, weight: .bold, design: .rounded)).monospacedDigit()
                Text("avg steps / recorded day")
                    .font(.caption).foregroundStyle(.white.opacity(0.8))
            }
            HStack(spacing: 12) {
                tile("Total steps", value: recap.total?.formatted() ?? "—", detail: "\(recap.recorded.count) of 7 days recorded")
                tile("Goal days", value: goal.map { recap.recorded.isEmpty ? "—" : recap.goalDays($0).formatted() } ?? "—",
                     detail: goal.map { "At \($0.formatted()) steps" } ?? "Set a goal in Settings")
            }
            if let best = recap.bestDay {
                Label("Best day: \(best.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) · \(best.count!.formatted()) steps", systemImage: "star.fill")
                    .font(.subheadline).foregroundStyle(WalkingStyle.accent)
            } else {
                Text(model.isLoading ? "Loading last week’s steps…" : "Last week’s steps aren’t available yet.")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.75))
            }
            Text("Missing days are excluded from the average. Goal days use your current daily goal.")
                .font(.caption).foregroundStyle(.white.opacity(0.65))
            if let message = model.message { Text(message).font(.caption).foregroundStyle(.white.opacity(0.75)) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .modifier(WalkingGlassCard(radius: 24))
        .privacySensitive()
        .task(id: refreshDate) {
            model.invalidateCache()
            await model.load(.month, dailyDays: 14)
        }
    }

    private func tile(_ title: String, value: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.8))
            Text(value).modifier(WalkingNumberMotion(value: value))
                .font(.system(size: 25, weight: .bold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.65)
            Text(detail).font(.caption2).foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.12)))
    }
}
#endif
