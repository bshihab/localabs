import SwiftUI

struct ContentView: View {
    @EnvironmentObject var engine: InferenceEngine
    @AppStorage("onboarding_complete") var onboardingComplete = false
    // Bound so the Resume banner on the Dashboard tab can route the user
    // back to the Scan tab — that's where the live streaming UI lives, so
    // re-running an incomplete analysis has to surface there rather than
    // staying on the dashboard.
    @State private var selectedTab: Int = 0

    var body: some View {
        if onboardingComplete {
            TabView(selection: $selectedTab) {
                ScanView()
                    .tabItem {
                        Label("Scan", systemImage: "doc.text.viewfinder")
                    }
                    .tag(0)

                // Replaces the old empty Dashboard tab — that tab had
                // no real content under the new pause/resume design.
                // Trends gives the slot a genuine job: phone + Watch
                // health metrics over 7/30/90 days, the same pipeline
                // Localabs already pulls into the lab-report prompt.
                TrendsView()
                    .tabItem {
                        Label("Trends", systemImage: "chart.line.uptrend.xyaxis")
                    }
                    .tag(1)

                HistoryView()
                    .tabItem {
                        Label("History", systemImage: "clock.arrow.circlepath")
                    }
                    .tag(2)

                ProfileView()
                    .tabItem {
                        Label("Profile", systemImage: "person.crop.circle")
                    }
                    .tag(3)
            }
            .tint(.blue)
            // When a paused analysis exists, jump the user to the Scan
            // tab so they see the live cards / Resume CTA rather than
            // sitting on Trends or History wondering where it went.
            .onChange(of: engine.pendingResumeReport?.id) { _, newID in
                if newID != nil { selectedTab = 0 }
            }
        } else {
            OnboardingView()
        }
    }
}
