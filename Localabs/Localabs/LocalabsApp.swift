import SwiftUI
import UIKit

@main
struct LocalabsApp: App {
    /// AppDelegate adaptor — needed only so iOS can deliver
    /// background-URLSession relaunch events to us. Without this, a
    /// download finishing while the app is killed wouldn't get a chance
    /// to fire the model-ready notification.
    @UIApplicationDelegateAdaptor(LocalabsAppDelegate.self) private var appDelegate
    @StateObject private var engine = InferenceEngine.shared
    /// Controls the splash → ContentView handoff. The splash plays its
    /// own zoom animation and calls back when done; we cross-fade
    /// ContentView in here so the visual transition isn't abrupt.
    @State private var showSplash: Bool = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .environmentObject(engine)
                    .task {
                        await engine.loadModelIfDownloaded()
                    }

                if showSplash {
                    SplashView {
                        withAnimation(.easeOut(duration: 0.35)) {
                            showSplash = false
                        }
                    }
                    .transition(.opacity)
                }
            }
        }
    }
}

/// Minimal AppDelegate. Its only job is to forward the
/// background-URLSession relaunch handler to ModelDownloader so the
/// shared session can complete event delivery and tell iOS we're done.
final class LocalabsAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        // Park the completion handler on the downloader; it'll be invoked
        // from urlSessionDidFinishEvents(forBackgroundURLSession:) once
        // the session has flushed all pending events.
        ModelDownloader.shared.backgroundCompletionHandler = completionHandler
        // Eagerly create the background URLSession so iOS can bind the
        // pending events to its delegate — without this, iOS would have
        // a session id with no live delegate to deliver to.
        ModelDownloader.shared.ensureBackgroundSessionReady()
    }
}
