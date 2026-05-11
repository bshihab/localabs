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

                DashboardView()
                    .tabItem {
                        Label("Dashboard", systemImage: "heart.text.square")
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
            // When a Resume banner is tapped anywhere, the dashboard sets
            // engine.pendingResumeReport. Jump the user to the Scan tab so
            // ScanView's own onChange picks it up and shows live streaming.
            .onChange(of: engine.pendingResumeReport?.id) { _, newID in
                if newID != nil { selectedTab = 0 }
            }
        } else {
            OnboardingView()
        }
    }
}
