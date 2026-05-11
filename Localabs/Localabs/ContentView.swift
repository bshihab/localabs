import SwiftUI

struct ContentView: View {
    @EnvironmentObject var engine: InferenceEngine
    @AppStorage("onboarding_complete") var onboardingComplete = false
    
    var body: some View {
        if onboardingComplete {
            TabView {
                ScanView()
                    .tabItem {
                        Label("Scan", systemImage: "doc.text.viewfinder")
                    }
                
                DashboardView()
                    .tabItem {
                        Label("Dashboard", systemImage: "heart.text.square")
                    }
                
                HistoryView()
                    .tabItem {
                        Label("History", systemImage: "clock.arrow.circlepath")
                    }
                
                ProfileView()
                    .tabItem {
                        Label("Profile", systemImage: "person.crop.circle")
                    }
            }
            .tint(.blue)
        } else {
            OnboardingView()
        }
    }
}
