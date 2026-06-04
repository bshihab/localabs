import SwiftUI
import UIKit

/// Animated splash with a "content emerging from the heart" reveal.
/// The splash sits on top of ContentView (composed by the parent in
/// a ZStack) and renders a white + chip overlay with a heart-shaped
/// HOLE punched through it. During the pulse phase the hole is
/// small (a heartbeat-sized window) — then in the zoom phase the
/// hole grows past the screen, so ContentView naturally fills the
/// visible area. No fade-out is needed at the end: once the hole
/// exceeds the screen, the splash is invisible, and the parent can
/// dismiss it silently.
///
/// Every animation is GPU-driven: the splash overlay is a flat
/// raster, the chip is an Image, the mask scale is a hardware
/// texture sample. Each animated property uses its own
/// `keyframeAnimator` with the same trigger so SwiftUI requests
/// ProMotion's 120Hz refresh on iPhone 17.
struct SplashView: View {
    var onComplete: () -> Void

    @State private var animationTrigger: Bool = false

    /// Chip's base render size before zoom — matches the brand
    /// mark's natural sticker size on iPhone screens.
    private let chipBase: CGFloat = 160
    /// Heart hole base diameter. Sized to about 28% of the chip so
    /// it sits comfortably inside the chip body rather than
    /// crowding the edges — earlier 60pt (37.5% of chip) looked
    /// oversized against the brand mark.
    private let heartBase: CGFloat = 45

    var body: some View {
        ZStack {
            // White + chip overlay with a heart-shaped hole. The
            // chip is an animatable Image (scaleEffect + opacity);
            // the hole is inside a mask closure with its own
            // keyframeAnimator that drives the pulse + portal-scale
            // sequence as one continuous track.
            chipOverlay
                .mask {
                    Rectangle()
                        .ignoresSafeArea()
                        .overlay { heartHole }
                        .compositingGroup()
                }

            // Solid white heart sitting EXACTLY over the mask hole —
            // identical keyframe track so they scale + pulse in
            // lockstep. During the pulse phase this layer is opaque
            // and the user sees a clean white heart (not ContentView
            // peeking through the hole). During the zoom phase it
            // fades to 0, revealing whatever the now-massive hole
            // is showing underneath (ContentView).
            heartFill

            wordmark
        }
        .onAppear {
            animationTrigger.toggle()
            // Total keyframe runtime ~2.10s. Fire onComplete just
            // past the end — by that point the heart hole has
            // exceeded any iPhone screen by ~6×, so the parent
            // dismissing the splash is invisible (ContentView is
            // already fully visible).
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.15) {
                onComplete()
            }
        }
    }

    // MARK: - Subviews

    private var chipOverlay: some View {
        ZStack {
            // System-background instead of hard-coded white so the
            // splash matches the active color scheme: white in light
            // mode, near-black in dark mode. The heart-shaped hole
            // cut into this overlay reveals ContentView underneath,
            // which uses the same `.systemBackground` — so the
            // transition from splash → app is seamless in both
            // appearances. The heart fill stays white via its own
            // `.foregroundStyle(.white)` so the brand mark reads
            // light-on-dark in dark mode, matching the user's spec.
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            Image("LocalabsChip")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: chipBase, height: chipBase)
                .keyframeAnimator(
                    initialValue: 1.0,
                    trigger: animationTrigger
                ) { content, scale in
                    content.scaleEffect(scale, anchor: .center)
                } keyframes: { _ in
                    KeyframeTrack {
                        // Holds at 1.0 through the pulses, then
                        // grows during the zoom so the chip flies
                        // past the camera.
                        LinearKeyframe(1.0, duration: 1.39)
                        CubicKeyframe(8.0, duration: 0.70)
                    }
                }
                .keyframeAnimator(
                    initialValue: 1.0,
                    trigger: animationTrigger
                ) { content, opacity in
                    content.opacity(opacity)
                } keyframes: { _ in
                    KeyframeTrack {
                        // Chip fades out as the zoom begins so it
                        // doesn't visually compete with the
                        // expanding heart hole.
                        LinearKeyframe(1.0, duration: 1.55)
                        CubicKeyframe(0.0, duration: 0.45)
                    }
                }
        }
        .compositingGroup()
    }

    private var heartHole: some View {
        Image(systemName: "heart.fill")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: heartBase, height: heartBase)
            .keyframeAnimator(
                initialValue: 1.0,
                trigger: animationTrigger
            ) { content, scale in
                content.scaleEffect(scale, anchor: .center)
            } keyframes: { _ in
                // Single track that pulses 5× then ramps past the
                // screen. Combining the pulse and the zoom into
                // one keyframe sequence keeps the transition
                // seamless — the racing pulse peak hands off
                // directly into the zoom acceleration with no gap.
                KeyframeTrack {
                    // beat 1 — ~58 bpm (relaxed)
                    CubicKeyframe(1.18, duration: 0.26)
                    CubicKeyframe(1.00, duration: 0.26)
                    // beat 2 — ~83 bpm
                    CubicKeyframe(1.22, duration: 0.18)
                    CubicKeyframe(1.00, duration: 0.18)
                    // beat 3 — ~115 bpm
                    CubicKeyframe(1.26, duration: 0.13)
                    CubicKeyframe(1.00, duration: 0.13)
                    // beat 4 — ~165 bpm
                    CubicKeyframe(1.30, duration: 0.09)
                    CubicKeyframe(1.00, duration: 0.09)
                    // beat 5 — racing peak, holds briefly
                    CubicKeyframe(1.35, duration: 0.07)
                    // ZOOM — heart hole grows past the screen.
                    // 60× makes it exceed any iPhone screen by ~6×,
                    // so the user sees ContentView with no visible
                    // hole boundary at the end of the animation.
                    CubicKeyframe(60.0, duration: 0.70)
                }
            }
            .blendMode(.destinationOut)
    }

    /// White heart fill that covers the mask hole during the pulse
    /// phase so ContentView doesn't peek through. The scale keyframe
    /// track is identical to `heartHole`'s so the two views move in
    /// perfect sync. A separate opacity keyframe track fades this
    /// layer out as the zoom kicks in, at which point the hole
    /// underneath does its job and reveals ContentView.
    private var heartFill: some View {
        Image(systemName: "heart.fill")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .foregroundStyle(.white)
            .frame(width: heartBase, height: heartBase)
            .keyframeAnimator(
                initialValue: 1.0,
                trigger: animationTrigger
            ) { content, scale in
                content.scaleEffect(scale, anchor: .center)
            } keyframes: { _ in
                // MUST match heartHole's scale track exactly.
                KeyframeTrack {
                    CubicKeyframe(1.18, duration: 0.26)
                    CubicKeyframe(1.00, duration: 0.26)
                    CubicKeyframe(1.22, duration: 0.18)
                    CubicKeyframe(1.00, duration: 0.18)
                    CubicKeyframe(1.26, duration: 0.13)
                    CubicKeyframe(1.00, duration: 0.13)
                    CubicKeyframe(1.30, duration: 0.09)
                    CubicKeyframe(1.00, duration: 0.09)
                    CubicKeyframe(1.35, duration: 0.07)
                    CubicKeyframe(60.0, duration: 0.70)
                }
            }
            .keyframeAnimator(
                initialValue: 1.0,
                trigger: animationTrigger
            ) { content, opacity in
                content.opacity(opacity)
            } keyframes: { _ in
                // Stays opaque through the pulse phase, fades out
                // during the zoom. Slightly faster fade than the
                // chip — the white heart should be gone by the
                // time the hole has grown enough for ContentView
                // to dominate the visible area.
                KeyframeTrack {
                    LinearKeyframe(1.0, duration: 1.39)
                    CubicKeyframe(0.0, duration: 0.35)
                }
            }
    }

    private var wordmark: some View {
        Text("Localabs")
            .font(.system(size: 32, weight: .bold, design: .rounded))
            .foregroundStyle(.primary)
            .shadow(color: .blue.opacity(0.45), radius: 14)
            .offset(y: 130)
            .keyframeAnimator(
                initialValue: 1.0,
                trigger: animationTrigger
            ) { content, opacity in
                content.opacity(opacity)
            } keyframes: { _ in
                KeyframeTrack {
                    LinearKeyframe(1.0, duration: 1.24)
                    CubicKeyframe(0.0, duration: 0.25)
                }
            }
    }
}

/// Layered logo built from the user's brand PNGs. Two stacked
/// Image() resources at matching canvas alignment — the heart sits
/// exactly where it should over the chip. Used by the splash and
/// available for any other in-app brand usage.
struct LocalabsLogo: View {
    enum Layer {
        case full
        case chipOnly
        case heartOnly
    }

    var size: CGFloat = 140
    var heartScale: CGFloat = 1.0
    var layer: Layer = .full

    var body: some View {
        ZStack {
            if layer != .heartOnly {
                Image("LocalabsChip")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
            }
            if layer != .chipOnly {
                Image("LocalabsHeart")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
                    .scaleEffect(heartScale, anchor: .center)
            }
        }
        .frame(width: size, height: size)
    }
}
