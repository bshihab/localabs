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
    @State private var pulse: Bool = false
    @State private var wordmarkOpacity: Double = 1.0

    var body: some View {
        ZStack {
            // Pure white ground — matches Option C's brand spec.
            // Hardcoded white (not systemBackground) so it stays
            // white even in dark mode, where the brand asset reads
            // best against light.
            Color.white
                .ignoresSafeArea()

            VStack(spacing: 24) {
                LocalabsLogo()
                    .scaleEffect(pulse ? 1.04 : 1.0)
                    .shadow(color: Color.blue.opacity(0.18), radius: 24, y: 10)
                    // Flatten the entire logo into a single Metal
                    // texture so the zoom scales one bitmap instead
                    // of re-rasterizing 40+ vector subviews (chip,
                    // 20 pins, 20 trace strokes, heart) every frame.
                    // The difference between "vector scale at 60fps"
                    // and "texture scale at 120fps ProMotion" is the
                    // difference between choppy and butter-smooth.
                    .drawingGroup()

                Text("Localabs")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .opacity(wordmarkOpacity)
            }
            .scaleEffect(zoomScale, anchor: .center)
            .opacity(contentOpacity)
        }
        .onAppear {
            // Heartbeat pulse from the moment the splash appears
            // through the start of the zoom.
            withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                pulse = true
            }
            // 1.0s settle — user registers the logo and a couple
            // pulse cycles.
            // Then the zoom: aggressive easeIn for the "flying in"
            // feel. Wordmark fades out as the zoom begins so it
            // doesn't dominate the frame as it scales massively.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                withAnimation(.easeOut(duration: 0.18)) {
                    wordmarkOpacity = 0
                }
                withAnimation(.easeIn(duration: 0.65)) {
                    zoomScale = 22.0
                }
            }
            // The fade-out kicks in only AFTER the zoom has done
            // most of its work — at that point the white heart
            // fills the entire screen, so fading the splash reveals
            // ContentView underneath cleanly. Doing zoom + fade in
            // parallel was what made the previous version read as
            // a cross-fade instead of a zoom.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation(.easeOut(duration: 0.2)) {
                    contentOpacity = 0
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.75) {
                onComplete()
            }
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
        let pinOuter = s * 0.5 + pinH * 0.45  // distance from origin to pin's outer edge
        let traceLen = s * 0.16
        let traceInset = s * 0.5 - traceLen / 2
        let traceThickness = pinW * 0.55
        let heartSize = s * 0.42

        ZStack {
            // Pins — 5 per side, drawn before the chip so the chip's
            // rounded corner gently overlaps each pin's inner edge.
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

            // Trace strokes — thin lines feeding from each pin into
            // the chip interior. Drawn ON TOP of the chip so they're
            // visible against the blue gradient.
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

            // The heart — white fill, centered. SF Symbol heart.fill
            // sits slightly below its geometric bounding box, so a
            // tiny upward nudge makes it look optically centered
            // inside the chip.
            Image(systemName: "heart.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.white)
                .frame(width: heartSize, height: heartSize)
                .offset(y: -heartSize * 0.04)
        }
        // Logo bounds include the pins, so the splash centers the
        // whole composition (chip + pins) rather than just the chip.
        .frame(width: s + pinH * 2, height: s + pinH * 2)
    }
}
