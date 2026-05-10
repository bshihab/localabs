import SwiftUI
import UIKit

@main
struct MedGemmaApp: App {
    /// AppDelegate adaptor — needed only so iOS can deliver
    /// background-URLSession relaunch events to us. Without this, a
    /// download finishing while the app is killed wouldn't get a chance
    /// to fire the model-ready notification.
    @UIApplicationDelegateAdaptor(MedGemmaAppDelegate.self) private var appDelegate
    @StateObject private var engine = InferenceEngine.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(engine)
                .task {
                    await engine.loadModelIfDownloaded()
                }
        }
    }
}

/// Minimal AppDelegate. Its only job is to forward the
/// background-URLSession relaunch handler to ModelDownloader so the
/// shared session can complete event delivery and tell iOS we're done.
final class MedGemmaAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        // Park the completion handler on the downloader; it'll be invoked
        // from urlSessionDidFinishEvents(forBackgroundURLSession:) once
        // the session has flushed all pending events.
        ModelDownloader.shared.backgroundCompletionHandler = completionHandler
    }
}
