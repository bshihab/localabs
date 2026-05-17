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

    /// Toggled once in .onAppear to fire the keyframe timeline. A
    /// single keyframeAnimator drives ALL animated values (pulse,
    /// zoom, opacity) off CADisplayLink — that's what lets SwiftUI
    /// request ProMotion's high refresh rate on iPhone 17. The old
    /// chained DispatchQueue + withAnimation pattern fired ~10
    /// independent short animations and never qualified for the
    /// 120Hz path, so the splash felt like it was running at 30fps.
    @State private var animationTrigger: Bool = false

    /// All animated values bundled into one struct so a single
    /// `keyframeAnimator` block can drive them as a coordinated
    /// timeline. Each property gets its own KeyframeTrack below.
    private struct Beats {
        var heartScale: CGFloat = 1.0
        var zoomScale: CGFloat = 1.0
        var contentOpacity: Double = 1.0
        var wordmarkOpacity: Double = 1.0
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            // Single keyframeAnimator drives the entire splash —
            // pulse + zoom + opacity on one timeline. The animator
            // schedules against CADisplayLink, which is what
            // qualifies for ProMotion's 120Hz refresh on iPhone 17.
            // Inside the animator's content builder, the chip and
            // heart are stacked separately so heartScale only
            // applies to the heart (chip + pins stay still during
            // the pulse).
            ZStack {
                LocalabsLogo(layer: .chipOnly)
                    .keyframeAnimator(
                        initialValue: Beats(),
                        trigger: animationTrigger
                    ) { content, beats in
                        content
                            .overlay(
                                LocalabsLogo(layer: .heartOnly)
                                    .scaleEffect(beats.heartScale, anchor: .center)
                            )
                            .scaleEffect(beats.zoomScale, anchor: .center)
                            .opacity(beats.contentOpacity)
                    } keyframes: { _ in
                        // Heartbeat: 5 accelerating pulses, then a
                        // hold while the zoom takes over.
                        KeyframeTrack(\.heartScale) {
                            // beat 1 — slow (~60 bpm)
                            CubicKeyframe(1.10, duration: 0.30)
                            CubicKeyframe(1.00, duration: 0.30)
                            // beat 2 — ~85 bpm
                            CubicKeyframe(1.13, duration: 0.22)
                            CubicKeyframe(1.00, duration: 0.22)
                            // beat 3 — ~120 bpm
                            CubicKeyframe(1.17, duration: 0.16)
                            CubicKeyframe(1.00, duration: 0.16)
                            // beat 4 — ~170 bpm
                            CubicKeyframe(1.22, duration: 0.11)
                            CubicKeyframe(1.00, duration: 0.11)
                            // beat 5 — ~250 bpm (racing) — hold the
                            // peak so it merges into the zoom.
                            CubicKeyframe(1.30, duration: 0.08)
                        }

                        // Zoom: holds at 1.0 through the pulses,
                        // then accelerates to 22× over 0.6s. EaseIn
                        // for the "flying in" feel.
                        KeyframeTrack(\.zoomScale) {
                            LinearKeyframe(1.0, duration: 1.86)
                            CubicKeyframe(22.0, duration: 0.55)
                        }

                        // Splash opacity: stays full through pulse +
                        // zoom; fades to 0 only at the end, after
                        // the white heart has filled the screen.
                        KeyframeTrack(\.contentOpacity) {
                            LinearKeyframe(1.0, duration: 2.22)
                            CubicKeyframe(0.0, duration: 0.20)
                        }

                        // Wordmark fades out at the moment the racing
                        // pulse hits, so it doesn't visually compete
                        // with the zoom that follows.
                        KeyframeTrack(\.wordmarkOpacity) {
                            LinearKeyframe(1.0, duration: 1.55)
                            CubicKeyframe(0.0, duration: 0.25)
                        }
                    }
            }

            // Wordmark is OUTSIDE the keyframeAnimator's content
            // intentionally — it has its own opacity track that
            // happens to share `wordmarkOpacity`, but it doesn't
            // need to share the zoom/pulse transforms.
            Text("Localabs")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .offset(y: 140)
                .keyframeAnimator(
                    initialValue: 1.0,
                    trigger: animationTrigger
                ) { content, opacity in
                    content.opacity(opacity)
                } keyframes: { _ in
                    KeyframeTrack(\.self) {
                        LinearKeyframe(1.0, duration: 1.55)
                        CubicKeyframe(0.0, duration: 0.25)
                    }
                }
        }
        .onAppear {
            animationTrigger.toggle()
            // Total keyframe runtime ~2.42s; fire onComplete just
            // past the end so the last frame renders before
            // ContentView takes over.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.45) {
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
    enum Layer {
        case full
        /// Chip body + pins + traces. No heart. Used when exporting
        /// PNGs for Icon Composer — the chip becomes one layer of
        /// the layered `.icon` file.
        case chipOnly
        /// Just the white heart, positioned where it would sit in
        /// the full logo. Transparent everywhere else. Stacked on
        /// top of `.chipOnly` it reproduces the full logo.
        case heartOnly
    }

    var size: CGFloat = 140
    /// Scale applied to just the heart, so the splash can pulse the
    /// heart by itself while the chip + pins stay still. Default 1.0
    /// (no pulse) for non-animated use.
    var heartScale: CGFloat = 1.0
    /// Which subset of the logo to render. Defaults to the full
    /// composite for the splash + any other in-app usage; the export
    /// tool flips this to `.chipOnly` / `.heartOnly` to save layered
    /// PNGs for Icon Composer.
    var layer: Layer = .full

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
            if layer != .heartOnly {
                chipFrame(
                    pinSpacing: pinSpacing,
                    pinW: pinW,
                    pinH: pinH,
                    pinOuter: pinOuter,
                    cornerRadius: cornerRadius,
                    s: s,
                    traceLen: traceLen,
                    traceInset: traceInset,
                    traceThickness: traceThickness
                )
            }

            if layer != .chipOnly {
                Image(systemName: "heart.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.white)
                    .frame(width: heartSize, height: heartSize)
                    .offset(y: -heartSize * 0.04)
                    .scaleEffect(heartScale, anchor: .center)
            }
        }
        // Logo bounds include the pins, so the splash centers the
        // whole composition (chip + pins) rather than just the chip.
        .frame(width: s + pinH * 2, height: s + pinH * 2)
    }

    /// Extracted chip-frame view (pins, chip body, traces). Lives in
    /// its own function so the layer split above doesn't have to
    /// inline the ZStack twice. .drawingGroup() flattens this whole
    /// composition into a single Metal texture so per-frame splash
    /// animations don't re-rasterize the 40+ shapes.
    @ViewBuilder
    private func chipFrame(
        pinSpacing: CGFloat,
        pinW: CGFloat,
        pinH: CGFloat,
        pinOuter: CGFloat,
        cornerRadius: CGFloat,
        s: CGFloat,
        traceLen: CGFloat,
        traceInset: CGFloat,
        traceThickness: CGFloat
    ) -> some View {
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
    }
}
