import Foundation
import UserNotifications

/// Schedules the local notifications that remind the user to re-scan a
/// worsening lab marker (#31 recheck reminders). Local-only, same
/// pattern as MedicationService / VisitService — fires whether the app
/// is open, backgrounded, or terminated. Tapping deep-links to the
/// scanner so the user can capture a fresh result.
@MainActor
enum RecheckService {
    private static func requestID(_ id: UUID) -> String { "recheck-\(id.uuidString)" }

    /// Set (or reset) a recheck reminder for a marker, `months` from now.
    /// Replaces any existing reminder for the same marker. Returns the
    /// stored reminder.
    @discardableResult
    static func schedule(marker: String, months: Int) async -> RecheckReminder {
        // One reminder per marker — drop the old one first.
        await cancel(marker: marker)

        let due = Calendar.current.date(byAdding: .month, value: max(1, months), to: Date()) ?? Date()
        let reminder = RecheckReminder(marker: marker, dueDate: due)
        RecheckStore.save(reminder)
        await arm(reminder)
        return reminder
    }

    static func cancel(id: UUID) async {
        RecheckStore.remove(id: id)
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [requestID(id)])
    }

    static func cancel(marker: String) async {
        if let existing = RecheckStore.reminder(forMarker: marker) {
            await cancel(id: existing.id)
        }
    }

    /// Re-arm all stored reminders on app activation (recovers any the
    /// system dropped) and clear ones whose date has already passed and
    /// fired.
    static func syncAll() async {
        for reminder in RecheckStore.all() {
            if reminder.dueDate <= Date() {
                // Past due — it has fired (or the window passed); clear it.
                await cancel(id: reminder.id)
            } else {
                await arm(reminder)
            }
        }
    }

    /// Remove just the pending notification for a reminder id (the store
    /// row is removed separately by the caller). Used by the menu toggle.
    static func removeNotification(id: UUID) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [requestID(id)])
    }

    static func arm(_ reminder: RecheckReminder) async {
        await MedicationService.requestAuthorizationIfNeeded()
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else { return }
        guard reminder.dueDate > Date() else { return }

        let content = UNMutableNotificationContent()
        content.title = "Time to recheck your \(reminder.marker)"
        content.body = "It was trending the wrong way — scan a new result to update your trend."
        content.sound = .default
        content.userInfo = ["deepLink": "recheck"]
        content.threadIdentifier = "recheck-reminders"

        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: reminder.dueDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let req = UNNotificationRequest(
            identifier: requestID(reminder.id), content: content, trigger: trigger
        )
        try? await UNUserNotificationCenter.current().add(req)
    }
}
