import Foundation
import UserNotifications

/// Schedules and cancels the repeating local notifications that
/// remind the user to take their medications. One repeating daily
/// notification per scheduled time, identified deterministically by
/// the medication id + time index so we can re-sync without tracking
/// identifiers on the model.
///
/// Everything is local: UNCalendarNotificationTrigger reminders, no
/// network, no server. Reminders fire whether the app is open,
/// backgrounded, or terminated — iOS owns delivery once scheduled.
@MainActor
enum MedicationService {

    /// Notification identifier for one med's one dose-time. Stable
    /// across edits so re-syncing replaces cleanly.
    private static func identifier(medID: UUID, timeIndex: Int) -> String {
        "med-\(medID.uuidString)-\(timeIndex)"
    }

    // MARK: - Authorization

    /// Requests notification permission the first time the user
    /// schedules a reminder. Safe to call repeatedly — the system
    /// no-ops once the user has decided.
    static func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    static func notificationsDenied() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .denied
    }

    // MARK: - Scheduling

    /// Re-sync one medication's reminders: cancel its existing
    /// requests, then schedule fresh ones for each scheduled time —
    /// but only if the med is active and has times. Call after every
    /// add / edit.
    static func sync(_ med: Medication) async {
        cancel(medID: med.id, timeCount: 24)  // clear generously
        guard med.isActive, !med.times.isEmpty else { return }

        // Don't schedule into the void.
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else { return }

        for (index, time) in med.times.enumerated() {
            let content = UNMutableNotificationContent()
            content.title = "Time for \(med.name)"
            content.body = med.dose.isEmpty
                ? "Tap to mark as taken."
                : "\(med.dose) — tap to mark as taken."
            content.sound = .default
            content.userInfo = ["medID": med.id.uuidString, "deepLink": "meds"]
            content.threadIdentifier = "med-reminders"

            var dateComponents = DateComponents()
            dateComponents.hour = time.hour
            dateComponents.minute = time.minute
            let trigger = UNCalendarNotificationTrigger(
                dateMatching: dateComponents,
                repeats: true
            )
            let request = UNNotificationRequest(
                identifier: identifier(medID: med.id, timeIndex: index),
                content: content,
                trigger: trigger
            )
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    /// Cancel a medication's reminders. `timeCount` is an upper
    /// bound on how many time-slots to clear (a med can't realistically
    /// have more than a handful, but we clear generously so reducing
    /// a med's times leaves no orphaned requests).
    static func cancel(medID: UUID, timeCount: Int = 24) {
        let ids = (0..<timeCount).map { identifier(medID: medID, timeIndex: $0) }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// Re-sync every active medication's reminders. Called on app
    /// activation so reminders survive edits made while the app was
    /// backgrounded and recover if iOS dropped pending requests.
    static func syncAll() async {
        for med in Medication.loadAll() {
            await sync(med)
        }
    }

    /// Profile → Reset App: wipe meds + adherence + every reminder.
    static func resetAll() {
        let ids = Medication.loadAll().flatMap { med in
            (0..<24).map { identifier(medID: med.id, timeIndex: $0) }
        }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        Medication.resetAll()
    }
}
