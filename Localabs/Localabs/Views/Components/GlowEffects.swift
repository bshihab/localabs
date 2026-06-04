import SwiftUI

/// Shared "Localabs is working" visual language, factored out of the scan
/// hero so loading/thinking moments across the app read the same way:
/// a glowing circular ring, dots orbiting inside, pulsing glowing icons.
///
/// Use these ONLY on transient working/loading states — never on persistent
/// content the user reads or browses, where the motion becomes noise.

// MARK: - GlowRing

/// A circular progress ring with a glowing tint, optional dots orbiting
/// inside, and a custom center. Determinate when `progress` is non-nil
/// (fills the arc); otherwise an indeterminate arc sweeps around. Mirrors
/// the scan hero's ring so "working" looks consistent everywhere.
struct GlowRing<Center: View>: View {
    var progress: Double?
    var tint: Color = .blue
    var size: CGFloat = 132
    var lineWidth: CGFloat = 6
    var showsOrbitingDots: Bool = true
    @ViewBuilder var center: () -> Center

    init(
        progress: Double? = nil,
        tint: Color = .blue,
        size: CGFloat = 132,
        lineWidth: CGFloat = 6,
        showsOrbitingDots: Bool = true,
        @ViewBuilder center: @escaping () -> Center
    ) {
        self.progress = progress
        self.tint = tint
        self.size = size
        self.lineWidth = lineWidth
        self.showsOrbitingDots = showsOrbitingDots
        self.center = center
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.15), lineWidth: lineWidth)

            if let progress {
                Circle()
                    .trim(from: 0, to: max(0.001, min(progress, 1)))
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: [tint, tint.opacity(0.5), tint]),
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .shadow(color: tint.opacity(0.5), radius: 5)
                    .animation(.easeOut(duration: 0.35), value: progress)
            } else {
                // Indeterminate — a short arc sweeping around the ring.
                TimelineView(.animation) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    Circle()
                        .trim(from: 0, to: 0.28)
                        .stroke(
                            AngularGradient(
                                gradient: Gradient(colors: [tint.opacity(0), tint]),
                                center: .center
                            ),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                        )
                        .rotationEffect(.degrees((t * 150).truncatingRemainder(dividingBy: 360)))
                        .shadow(color: tint.opacity(0.5), radius: 5)
                }
            }

            if showsOrbitingDots {
                GlowOrbitDots(radius: size / 2 - 22, tint: tint)
            }

            center()
        }
        .frame(width: size, height: size)
    }
}

/// Three small glowing dots orbiting the center, rotating on the display
/// clock. Used inside `GlowRing`.
private struct GlowOrbitDots: View {
    let radius: CGFloat
    let tint: Color

    var body: some View {
        TimelineView(.animation) { timeline in
            let base = timeline.date.timeIntervalSinceReferenceDate * 0.5
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    let a = base + Double(i) * (2 * .pi / 3)
                    Circle()
                        .fill(tint.opacity(0.5))
                        .frame(width: 6, height: 6)
                        .shadow(color: tint.opacity(0.6), radius: 3)
                        .offset(x: radius * cos(a), y: radius * sin(a))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - GlowingPulseIcon

/// An SF Symbol with a glow. Pulses on the display clock when `animated`
/// (for "Localabs is thinking" moments); a steady soft glow when not (for
/// empty-state hero icons, where idle screens shouldn't move).
struct GlowingPulseIcon: View {
    let systemName: String
    var tint: Color = .blue
    var size: CGFloat = 26
    var weight: Font.Weight = .semibold
    var animated: Bool = true

    var body: some View {
        if animated {
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let p = 0.5 + 0.5 * sin(t * 3.0)
                icon
                    .scaleEffect(1.0 + 0.10 * p)
                    .shadow(color: tint.opacity(0.35 + 0.4 * p), radius: 4 + 6 * p)
            }
        } else {
            icon.shadow(color: tint.opacity(0.45), radius: 14)
        }
    }

    private var icon: some View {
        Image(systemName: systemName)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(tint)
    }
}

// MARK: - glowPulse modifier

extension View {
    /// A gentle pulsing glow around the view while `active`. Used to draw a
    /// little attention (e.g. a medication dose that's due right now)
    /// without an alarming animation.
    func glowPulse(active: Bool, tint: Color = .blue) -> some View {
        modifier(GlowPulseModifier(active: active, tint: tint))
    }
}

private struct GlowPulseModifier: ViewModifier {
    let active: Bool
    let tint: Color

    func body(content: Content) -> some View {
        if active {
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let p = 0.5 + 0.5 * sin(t * 3.0)
                content.shadow(color: tint.opacity(0.4 + 0.4 * p), radius: 3 + 5 * p)
            }
        } else {
            content
        }
    }
}
