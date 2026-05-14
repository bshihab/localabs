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

    @State private var heartScale: CGFloat = 0.85
    @State private var heartOpacity: Double = 0
    @State private var labelOpacity: Double = 0
    @State private var zoomScale: CGFloat = 1.0
    @State private var contentOpacity: Double = 1.0
    @State private var pulse: Bool = false

    var body: some View {
        ZStack {
            // Background — soft gradient so the splash doesn't look
            // like a flat sticker. Same color family as the rest of
            // the app's accent palette (blue → pink) so the
            // transition into ContentView's blue accents feels
            // continuous.
            LinearGradient(
                colors: [
                    Color(uiColor: .systemBackground),
                    Color.pink.opacity(0.08),
                    Color.blue.opacity(0.06)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                LocalabsLogo()
                    .scaleEffect(heartScale * (pulse ? 1.06 : 1.0))
                    .opacity(heartOpacity)
                    .shadow(color: .pink.opacity(0.35), radius: 22, y: 10)

                Text("Localabs")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .opacity(labelOpacity)
            }
            .scaleEffect(zoomScale)
            .opacity(contentOpacity)
        }
        .onAppear {
            // Fade in the heart + wordmark
            withAnimation(.easeOut(duration: 0.45)) {
                heartScale = 1.0
                heartOpacity = 1.0
            }
            withAnimation(.easeOut(duration: 0.6).delay(0.25)) {
                labelOpacity = 1.0
            }
            // Subtle continuous heartbeat pulse — gives the static
            // logo a sense of life during the brief settle period.
            withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true).delay(0.6)) {
                pulse = true
            }
            // Zoom into the heart + fade to clear. Timing: settle ~1.2s,
            // then 0.6s of aggressive zoom + cross-fade. Total ~1.8s.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation(.easeIn(duration: 0.6)) {
                    zoomScale = 6.0
                    contentOpacity = 0
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.75) {
                onComplete()
            }
        }
    }
}

/// Placeholder logo — a stylized heart with a bold "L" centered on
/// top. Drawn entirely in SwiftUI so it scales cleanly through the
/// zoom animation (no raster artifacts at 6x scale). Swap this view
/// for an `Image("Logo")` reading from Assets.xcassets once a real
/// asset lands.
struct LocalabsLogo: View {
    var size: CGFloat = 140

    var body: some View {
        ZStack {
            Image(systemName: "heart.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.red, Color.pink],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size, height: size)

            // The "L" sits slightly above center because SF heart's
            // visual center is below the geometric center (the dip
            // at the top pulls the eye downward).
            Text("L")
                .font(.system(size: size * 0.45, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .offset(y: -size * 0.04)
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
        }
    }
}
