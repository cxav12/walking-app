import SwiftUI
import WidgetKit

enum WalkingStyle {
    static let progressSegmentHeight: CGFloat = 15
    static let progressSegmentSpacing: CGFloat = 5
    static let progressSegmentCornerRadius: CGFloat = 3
    #if os(iOS)
    static let accent = Color(red: 0.35, green: 0.94, blue: 1)
    static let secondaryAccent = Color(red: 1, green: 0.62, blue: 0.25)
    static let background = LinearGradient(
        colors: [Color(red: 0.02, green: 0.24, blue: 0.65),
                 Color(red: 0.02, green: 0.48, blue: 1),
                 Color(red: 0.18, green: 0.25, blue: 0.95)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    #else
    static let accent = Color(red: 188.0 / 255, green: 242.0 / 255, blue: 107.0 / 255)
    static let background = LinearGradient(
        colors: [Color(red: 0.08, green: 0.11, blue: 0.13),
                 Color(red: 0.06, green: 0.18, blue: 0.15)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    #endif

}

struct SegmentedStepProgress: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let progress: Double
    var height: CGFloat = 12
    var spacing: CGFloat = 4
    var cornerRadius: CGFloat = 3

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(0..<10) { index in
                GeometryReader { segment in
                    let fill = min(1, max(0, progress * 10 - Double(index)))
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(.white.opacity(0.16))
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(WalkingStyle.accent)
                                .frame(width: segment.size.width * fill)
                                .widgetAccentable()
                        }
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                }
            }
        }
        .frame(height: height)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: progress)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Daily goal progress")
        .accessibilityValue("\(Int((min(1, max(0, progress)) * 100).rounded())) percent")
    }
}

#if os(iOS)
struct WalkingBackdrop: View {
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                WalkingStyle.background
                Ellipse()
                    .fill(Color.cyan.opacity(0.75))
                    .frame(width: geometry.size.width * 1.2, height: geometry.size.height * 0.5)
                    .blur(radius: 65)
                    .offset(x: 100, y: -geometry.size.height * 0.35)
                Ellipse()
                    .fill(WalkingStyle.secondaryAccent.opacity(0.85))
                    .frame(width: geometry.size.width * 0.85, height: geometry.size.height * 0.8)
                    .rotationEffect(.degrees(30))
                    .blur(radius: 45)
                    .offset(x: geometry.size.width * 0.55, y: 30)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

// Use this heading for every iPhone dashboard card to keep titles and icons consistent.
struct WalkingCardTitle: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.title3.bold())
            .foregroundStyle(.white)
    }
}

struct WalkingGlassCard: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var radius: CGFloat = 26
    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius)
                    .fill(.regularMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: radius)
                            .fill(Color(red: 0.035, green: 0.12, blue: 0.22).opacity(reduceTransparency ? 0.95 : 0.30))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: radius)
                            .fill(LinearGradient(colors: [.white.opacity(0.08), .white.opacity(0.02)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.12)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
            }
            .shadow(color: .blue.opacity(0.15), radius: 14, y: 8)
    }
}
#endif

#if os(iOS)
struct WalkingNumberMotion: ViewModifier {
    let value: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .contentTransition(reduceMotion ? .identity : .numericText())
            .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: value)
    }
}

struct GoalSparkles: View {
    @State private var expanded = false
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(0..<12) { index in
                    let angle = Double(index) * .pi / 6
                    Image(systemName: index.isMultiple(of: 3) ? "sparkle" : "circle.fill")
                        .font(.system(size: index.isMultiple(of: 3) ? 16 : 6))
                        .foregroundStyle(index.isMultiple(of: 2) ? WalkingStyle.accent : WalkingStyle.secondaryAccent)
                        .offset(x: expanded ? cos(angle) * 110 : 0,
                                y: expanded ? sin(angle) * 85 : 0)
                        .opacity(expanded ? 0 : 1)
                }
            }
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            .onAppear { withAnimation(.easeOut(duration: 1.1)) { expanded = true } }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
#endif
