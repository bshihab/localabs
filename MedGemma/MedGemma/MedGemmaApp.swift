import SwiftUI

@main
struct MedGemmaApp: App {
    @StateObject private var engine = InferenceEngine.shared
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(engine)
        }
    }
}
