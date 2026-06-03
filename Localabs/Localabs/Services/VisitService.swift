import Foundation
import UserNotifications

/// Schedules the single "evening after your visit" check-in
/// notification (#34) from the user's upcoming `Appointment`. Tapping it
/// deep-links to the post-visit check-in flow. Local-only, same pattern
/// as MedicationService / HealthAlertService — no network, fires whether
/// the app is open, backgrounded, or terminated.
@MainActor
enum VisitService {
    private static let requestID = "visit-checkin"

    /// When the evening check-in fires: 7:00 PM on the appointment day,
    /// or 90 minutes after the appointment, whichever is later — so it
    /// always lands after the visit and in the evening.
    static func checkInFireDate(for appointmentDate: Date, calendar cal: Calendar = .current) -> Date {
        let day = cal.startOfDay(for: appointmentDate)
        let sevenPM = cal.date(byAdding: .hour, value: 19, to: day) ?? appointmentDate
        let plus90 = appointmentDate.addingTimeInterval(90 * 60)
        return max(sevenPM, plus90)
    }

    /// (Re)schedule the check-in for an appointment. Cancels any existing
    /// one first. No-op if the fire time has already passed or
    /// notifications aren't authorized.
    static func schedule(for appointment: Appointment) async {
        cancel()
        let fire = checkInFireDate(for: appointment.date)
        guard fire > Date() else { return }

        await MedicationService.requestAuthorizationIfNeeded()
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else { return }

        let content = UNMutableNotificationContent()
        content.title = "How did your visit go?"
        content.body = appointment.note.isEmpty
            ? "Tap to log any new medications or instructions from today."
            : "\(appointment.note) — tap to log new meds or instructions."
        content.sound = .default
        content.userInfo = ["deepLink": "visitcheckin"]
        content.threadIdentifier = "visit-checkin"

        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: fire
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let req = UNNotificationRequest(identifier: requestID, content: content, trigger: trigger)
        try? await UNUserNotificationCenter.current().add(req)
    }

    static func cancel() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [requestID])
    }

    /// Re-arm from the saved upcoming appointment on app activation —
    /// keeps the notification alive across edits/relaunches, and drops
    /// it once the appointment is cleared after a check-in.
    static func syncUpcoming() async {
        if let appt = Appointment.loadUpcoming() {
            await schedule(for: appt)
        } else {
            cancel()
        }
    }
}
