import SwiftUI
import UIKit
import UserNotifications

extension Notification.Name {
    /// Posted when the user taps a Health threshold-alert
    /// notification. ContentView observes it to switch to the
    /// Trends tab so the user lands on the relevant data.
    static let openTrendsFromAlert = Notification.Name("localabs.openTrendsFromAlert")
    /// Posted when the user taps a medication-reminder notification.
    /// ContentView switches to the Meds tab to check off the dose.
    static let openMedsFromReminder = Notification.Name("localabs.openMedsFromReminder")
    /// Posted when the user taps the evening post-visit check-in
    /// notification. ContentView switches to the Home tab and ScanView
    /// opens the check-in flow.
    static let openVisitCheckIn = Notification.Name("localabs.openVisitCheckIn")
    /// Posted when the user taps a "time to recheck your <marker>"
    /// notification. ContentView switches to the Home tab to scan.
    static let openRecheckScan = Notification.Name("localabs.openRecheckScan")
    /// Posted from the post-visit check-in's "Scan your after-visit summary"
    /// button. Tears down the WHOLE visit flow (the check-in sheet AND the
    /// visit hub that presented it) and lands the user on the Home tab to
    /// scan — rather than dismissing only one sheet level.
    static let openScanFromVisit = Notification.Name("localabs.openScanFromVisit")
    /// Posted when the user changes their age or biological sex. Views
    /// that show age/sex-dependent reference ranges (Trends, Dashboard)
    /// reload so the "normal" ranges reflect the new demographics — even
    /// when there are no saved reports to trigger a lab recompute.
    static let profileDemographicsChanged = Notification.Name("localabs.profileDemographicsChanged")
}

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
            // The on-device 4B model needs an 8 GB iPhone (15 Pro and
            // later). The App Store can't restrict downloads by RAM, so we
            // gate at launch and show a clear requirement screen rather than
            // letting the model fail to load on an unsupported device.
            if DeviceSupport.meetsRequirements {
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
            } else {
                UnsupportedDeviceView()
            }
        }
    }
}

/// Minimum-device gate. Localabs loads a ~2.5 GB model into Metal GPU
/// memory, which needs an iPhone with 8 GB of RAM (iPhone 15 Pro and
/// later). A 7 GiB threshold cleanly separates 8 GB devices (~8.6e9 bytes)
/// from 6 GB ones (~6.4e9) — `physicalMemory` reports total installed RAM,
/// not free RAM, so it's stable regardless of what else is running.
enum DeviceSupport {
    static var meetsRequirements: Bool {
        ProcessInfo.processInfo.physicalMemory >= 7 * 1024 * 1024 * 1024
    }
}

/// Shown in place of the app on devices that can't run the on-device model.
/// Explains the requirement instead of failing silently at model-load time.
struct UnsupportedDeviceView: View {
    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 52, weight: .regular))
                    .foregroundStyle(.orange)
                Text("This iPhone isn't supported")
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                Text("Localabs runs a medical AI model entirely on your device — nothing is sent to a server. That needs an iPhone 15 Pro or later (8 GB of memory). This iPhone doesn't have enough memory to run it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 32)
            }
            .padding()
        }
    }
}

/// Minimal AppDelegate. Forwards the background-URLSession relaunch
/// handler to ModelDownloader, registers the Health-alert background
/// task, and routes notification taps. Also the
/// UNUserNotificationCenter delegate so alerts present in-foreground
/// and taps deep-link to Trends.
final class LocalabsAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Become the notification delegate so Health alerts show a
        // banner even when the app is foregrounded, and taps route
        // through us to the Trends tab.
        UNUserNotificationCenter.current().delegate = self

        // Cold-start the keyboard subsystem during launch so the
        // first real text-field tap doesn't pay the ~10s
        // "Result accumulator timeout / Reporter disconnected"
        // delay we were seeing in the chat input. iOS spins up the
        // RemoteTextInput (RTI) daemon lazily on first
        // becomeFirstResponder — by doing that on a throwaway
        // off-screen field at launch, the daemon is already warm by
        // the time the user actually opens a chat.
        DispatchQueue.main.async {
            Self.prewarmKeyboard()
        }
        return true
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Present Health alerts as a banner + sound even while the app
    /// is in the foreground — otherwise a notification that fires
    /// during a foreground evaluation would be silently swallowed.
    ///
    /// `nonisolated`: UNUserNotificationCenterDelegate methods are
    /// non-isolated in the protocol, but the AppDelegate class is
    /// implicitly @MainActor (via UIApplicationDelegate). Without
    /// `nonisolated` the conformance crosses actor isolation and
    /// Swift 6 flags a potential data race. This method only calls
    /// the completion handler, so no main-actor state is touched.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    /// Route a tapped Health alert to the Trends tab. `nonisolated`
    /// for the same reason as above; the only main-actor work (the
    /// NotificationCenter post that drives the SwiftUI tab switch)
    /// is hopped onto the main actor explicitly. We read the simple
    /// Bool out of the non-Sendable response first so nothing
    /// non-Sendable is captured across the hop.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let deepLink = response.notification.request.content.userInfo["deepLink"] as? String
        if let deepLink {
            Task { @MainActor in
                switch deepLink {
                case "trends":
                    NotificationCenter.default.post(name: .openTrendsFromAlert, object: nil)
                case "meds":
                    NotificationCenter.default.post(name: .openMedsFromReminder, object: nil)
                case "visitcheckin":
                    NotificationCenter.default.post(name: .openVisitCheckIn, object: nil)
                case "recheck":
                    NotificationCenter.default.post(name: .openRecheckScan, object: nil)
                default:
                    break
                }
            }
        }
        completionHandler()
    }

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

    /// Triggers the iOS keyboard daemon (UIKeyboard / RTI) by briefly
    /// making a hidden, off-screen `UITextField` first responder.
    /// The field is removed immediately after — it never appears
    /// visually — but the system has now done the expensive one-time
    /// keyboard bring-up work, so the first real text-field focus is
    /// instant instead of taking ~10s on launch.
    private static func prewarmKeyboard() {
        guard let scene = UIApplication.shared.connectedScenes
                .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first
        else { return }

        let field = UITextField(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
        field.isHidden = true
        window.addSubview(field)
        _ = field.becomeFirstResponder()
        DispatchQueue.main.async {
            field.resignFirstResponder()
            field.removeFromSuperview()
        }
    }
}
