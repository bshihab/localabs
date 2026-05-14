import SwiftUI
import UIKit

/// Animated splash screen shown briefly when the app launches. Plays
/// a subtle pulse on the heart logo, then zooms into the heart while
/// fading to white before handing off to ContentView. Mirrors what
/// the iOS launch screen renders statically so the transition from
/// system-level launch to app-level splash is visually seamless.
struct SplashView: View {
    /// Called when the zoom animation completes. The parent should
    /// flip its state to dismiss the splash and reveal ContentView.
    var onComplete: () -> Void

    // Start everything visible at full size so the user sees the
    // logo immediately. The fade-in version of this view depended on
    // onAppear running animations during first render, which on iOS
    // sometimes gets dropped (the system optimizes away animations
    // for the very first frame, so opacity 0 → 1 sticks at 0).
    @State private var zoomScale: CGFloat = 1.0
    @State private var contentOpacity: Double = 1.0
    @State private var pulseScale: CGFloat = 1.0
    @State private var wordmarkOpacity: Double = 1.0

    var body: some View {
        ZStack {
            // Background respects the user's theme — light mode
            // gets the brand-spec white, dark mode gets the system
            // dark background. The chip + white heart read well on
            // both.
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            // Logo lives at the *exact* screen center via ZStack
            // layout — the wordmark below is positioned with
            // .offset, NOT as a VStack sibling. Old layout used a
            // VStack which centered the (logo + wordmark) pair, so
            // the logo's center sat ABOVE screen center — and the
            // zoom scaled from that off-center anchor, making the
            // zoom feel slightly to the side of the heart.
            LocalabsLogo(heartScale: pulseScale)
                .scaleEffect(zoomScale, anchor: .center)
                .shadow(color: Color.blue.opacity(0.18), radius: 24, y: 10)
                .opacity(contentOpacity)

            Text("Localabs")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .opacity(wordmarkOpacity)
                .offset(y: 140)
        }
        .onAppear { runSequence() }
    }

    /// Accelerating heartbeat → zoom sequence. Each pulse is shorter
    /// than the last, so the user perceives the heart speeding up
    /// just before the camera flies into it. The final beats overlap
    /// the start of the zoom for a single-motion feel.
    private func runSequence() {
        // Discrete pulses with shrinking cycle times. Format:
        // (startSec, peakScale, halfCycleSec). The pulse cycles up
        // to peakScale then back to 1.0 over 2 × halfCycleSec.
        // Pulse peaks tuned for HEART-only scaling (chip + pins stay
        // still). At the same numerical scales the visible pulse is
        // smaller than when the whole logo scaled together, so the
        // peaks ramp higher here for the same perceived effect.
        let beats: [(start: Double, peak: CGFloat, half: Double)] = [
            (0.05, 1.10, 0.30),  // ~60bpm
            (0.65, 1.13, 0.22),  // ~85bpm
            (1.09, 1.17, 0.16),  // ~120bpm
            (1.41, 1.22, 0.11),  // ~170bpm
            (1.63, 1.28, 0.08)   // ~250bpm — racing
        ]
        for beat in beats {
            DispatchQueue.main.asyncAfter(deadline: .now() + beat.start) {
                withAnimation(.easeOut(duration: beat.half)) {
                    pulseScale = beat.peak
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + beat.half) {
                    withAnimation(.easeIn(duration: beat.half)) {
                        pulseScale = 1.0
                    }
                }
            }
        }

        // Wordmark out at the moment the racing pulse hits, so the
        // wordmark doesn't visually scale alongside the logo.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.55) {
            withAnimation(.easeOut(duration: 0.2)) {
                wordmarkOpacity = 0
            }
        }

        // Zoom flies in right as the last pulse peaks — the rising
        // pulse seamlessly hands off to the scale-up so it reads as
        // one continuous motion (faster + faster + WHOOSH).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.79) {
            withAnimation(.easeIn(duration: 0.6)) {
                zoomScale = 22.0
            }
        }

        // Opacity fade kicks in only after the zoom has nearly
        // completed — at that point the white heart fills the
        // screen, so fading reveals ContentView underneath cleanly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.24) {
            withAnimation(.easeOut(duration: 0.18)) {
                contentOpacity = 0
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.42) {
            onComplete()
        }
    }
}

/// Localabs · Option C logo, drawn entirely in SwiftUI so it stays
/// crisp through the 12× zoom animation. Layout matches the brand
/// spec: blue-gradient rounded-square "chip", a clean white heart
/// centered inside, 5 rectangular pins on each of the four sides
/// extending outward, and faint horizontal/vertical trace strokes
/// inside the chip that feed in from each pin.
struct LocalabsLogo: View {
    var size: CGFloat = 140
    /// Scale applied to just the heart, so the splash can pulse the
    /// heart by itself while the chip + pins stay still. Default 1.0
    /// (no pulse) for non-animated use.
    var heartScale: CGFloat = 1.0

    // Colors picked to match the PDF: a slightly cool, saturated
    // blue gradient running TL → BR, with a darker shade for pins
    // and traces.
    private let chipGradient = LinearGradient(
        colors: [
            Color(red: 0.32, green: 0.60, blue: 1.00),
            Color(red: 0.07, green: 0.36, blue: 0.92)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    private let pinColor = Color(red: 0.10, green: 0.38, blue: 0.92)
    private let traceColor = Color.white.opacity(0.22)

    var body: some View {
        let s = size
        let cornerRadius = s * 0.22
        let pinW = s * 0.045
        let pinH = s * 0.08
        let pinSpacing = s * 0.155      // gap between pin centers
        // pinOuter = distance from logo origin to pin's CENTER along
        // the perpendicular axis. The previous 0.45 multiplier left
        // the pin's inner edge just barely overlapping the chip's
        // straight edge, but at the rounded corners the chip's curve
        // pulled away from y=±s/2 and a thin white sliver opened
        // between pin and chip. 0.30 deepens the pin's overlap into
        // the chip body so the chip covers the inner edge even at
        // the corners.
        let pinOuter = s * 0.5 + pinH * 0.30
        let traceLen = s * 0.16
        let traceInset = s * 0.5 - traceLen / 2
        let traceThickness = pinW * 0.55
        let heartSize = s * 0.42

        ZStack {
            // Static chip + pins + traces — wrapped in their own
            // ZStack and flattened with drawingGroup so the chip
            // body never re-rasterizes during the splash animations.
            // Only the heart (the sibling below) animates.
            ZStack {
                // Pins — 5 per side, drawn before the chip so the
                // chip's rounded corner gently overlaps each pin's
                // inner edge.
                ForEach(-2...2, id: \.self) { i in
                    let lateral = CGFloat(i) * pinSpacing
                    // Top
                    Rectangle()
                        .fill(pinColor)
                        .frame(width: pinW, height: pinH)
                        .offset(x: lateral, y: -pinOuter)
                    // Bottom
                    Rectangle()
                        .fill(pinColor)
                        .frame(width: pinW, height: pinH)
                        .offset(x: lateral, y: pinOuter)
                    // Left (rotated 90°: width/height swap)
                    Rectangle()
                        .fill(pinColor)
                        .frame(width: pinH, height: pinW)
                        .offset(x: -pinOuter, y: lateral)
                    // Right
                    Rectangle()
                        .fill(pinColor)
                        .frame(width: pinH, height: pinW)
                        .offset(x: pinOuter, y: lateral)
                }

                // Chip body
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(chipGradient)
                    .frame(width: s, height: s)

                // Trace strokes — thin lines feeding from each pin
                // into the chip interior. Drawn ON TOP of the chip
                // so they're visible against the blue gradient.
                ForEach(-2...2, id: \.self) { i in
                    let lateral = CGFloat(i) * pinSpacing
                    // Top trace (vertical, just inside top edge)
                    Rectangle()
                        .fill(traceColor)
                        .frame(width: traceThickness, height: traceLen)
                        .offset(x: lateral, y: -traceInset)
                    // Bottom trace
                    Rectangle()
                        .fill(traceColor)
                        .frame(width: traceThickness, height: traceLen)
                        .offset(x: lateral, y: traceInset)
                    // Left trace (horizontal, just inside left edge)
                    Rectangle()
                        .fill(traceColor)
                        .frame(width: traceLen, height: traceThickness)
                        .offset(x: -traceInset, y: lateral)
                    // Right trace
                    Rectangle()
                        .fill(traceColor)
                        .frame(width: traceLen, height: traceThickness)
                        .offset(x: traceInset, y: lateral)
                }
            }
            .drawingGroup()

            // The heart — white fill, centered. Scaled by heartScale
            // so the splash can pulse the heart by itself while the
            // chip + pins above stay still. SF Symbol heart.fill
            // sits slightly below its geometric bounding box, so a
            // tiny upward nudge makes it look optically centered
            // inside the chip.
            Image(systemName: "heart.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.white)
                .frame(width: heartSize, height: heartSize)
                .offset(y: -heartSize * 0.04)
                .scaleEffect(heartScale, anchor: .center)
        }
        // Logo bounds include the pins, so the splash centers the
        // whole composition (chip + pins) rather than just the chip.
        .frame(width: s + pinH * 2, height: s + pinH * 2)
    }
}
