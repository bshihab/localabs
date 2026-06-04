import SwiftUI

struct ContentView: View {
    @EnvironmentObject var engine: InferenceEngine
    @Environment(\.scenePhase) private var scenePhase
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
                        Label("Home", systemImage: "house.fill")
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

                MedsView()
                    .tabItem {
                        Label("Meds", systemImage: "pills.fill")
                    }
                    .tag(2)

                HistoryView()
                    .tabItem {
                        Label("History", systemImage: "clock.arrow.circlepath")
                    }
                    .tag(3)

                ProfileView()
                    .tabItem {
                        Label("Profile", systemImage: "person.crop.circle")
                    }
                    .tag(4)
            }
            .tint(.blue)
            // When a paused analysis exists, jump the user to the Scan
            // tab so they see the live cards / Resume CTA rather than
            // sitting on Trends or History wondering where it went.
            .onChange(of: engine.pendingResumeReport?.id) { _, newID in
                if newID != nil { selectedTab = 0 }
            }
            // Tapping a Health threshold-alert notification deep-links
            // to the Trends tab (tag 1) so the user lands on the data
            // the alert was about.
            .onReceive(NotificationCenter.default.publisher(for: .openTrendsFromAlert)) { _ in
                selectedTab = 1
            }
            // Tapping a medication-reminder notification deep-links to
            // the Meds tab (tag 2) so the user can check off the dose.
            .onReceive(NotificationCenter.default.publisher(for: .openMedsFromReminder)) { _ in
                selectedTab = 2
            }
            // Tapping the evening post-visit check-in notification lands
            // on the Home tab (tag 0); ScanView opens the check-in sheet.
            .onReceive(NotificationCenter.default.publisher(for: .openVisitCheckIn)) { _ in
                selectedTab = 0
            }
            // Tapping a "time to recheck your <marker>" notification lands
            // on the Home tab so the user can scan a fresh result.
            .onReceive(NotificationCenter.default.publisher(for: .openRecheckScan)) { _ in
                selectedTab = 0
            }
            // Foreground path on app activation: re-check armed Health
            // alerts, and re-sync medication reminders so edits made
            // while backgrounded (or pending requests iOS dropped) are
            // restored. (No background refresh in v1.)
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { @MainActor in
                    await HealthAlertService.shared.evaluate()
                    await MedicationService.syncAll()
                    await VisitService.syncUpcoming()
                    await RecheckService.syncAll()
                }
            }
        } else {
            OnboardingView()
        }
    }
}

