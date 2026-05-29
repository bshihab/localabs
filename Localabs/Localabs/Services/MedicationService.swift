import Foundation
import UserNotifications

/// Schedules and cancels the local notifications that remind the
/// user to take their medications. Scheduling depends on the med's
/// repeat rule:
///   - daily   → one repeating trigger per time (hour/minute)
///   - weekly  → one repeating trigger per (weekday × time)
///   - biweekly→ a rolling window of dated, non-repeating triggers
///               per (weekday × time), topped up on each app launch
///               (iOS has no native "every other week" trigger)
///
/// Every request id is prefixed with the med's UUID so cancellation
/// can match by prefix regardless of the scheme used.
///
/// Everything is local: no network, no server. Reminders fire whether
/// the app is open, backgrounded, or terminated — iOS owns delivery.
@MainActor
enum MedicationService {

    /// All of a med's notification ids share this prefix so we can
    /// cancel by prefix without tracking individual identifiers.
    private static func idPrefix(_ medID: UUID) -> String {
        "med-\(medID.uuidString)-"
    }

    /// How many future occurrences to pre-schedule for biweekly meds.
    /// Kept small to stay well under iOS's 64-pending-notification cap
    /// when several meds are active; topped up on every app launch.
    private static let biweeklyWindow = 4

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
        await cancel(medID: med.id)
        guard med.isActive, !med.times.isEmpty else { return }

        // Don't schedule into the void.
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else { return }

        let center = UNUserNotificationCenter.current()

        func content() -> UNMutableNotificationContent {
            let c = UNMutableNotificationContent()
            c.title = "Time for \(med.name)"
            c.body = med.dose.isEmpty
                ? "Tap to mark as taken."
                : "\(med.dose) — tap to mark as taken."
            c.sound = .default
            c.userInfo = ["medID": med.id.uuidString, "deepLink": "meds"]
            c.threadIdentifier = "med-reminders"
            return c
        }

        switch med.repeatRule.cadence {
        case .daily:
            for (index, time) in med.times.enumerated() {
                var comps = DateComponents()
                comps.hour = time.hour
                comps.minute = time.minute
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
                let req = UNNotificationRequest(
                    identifier: "\(idPrefix(med.id))t\(index)",
                    content: content(),
                    trigger: trigger
                )
                try? await center.add(req)
            }

        case .weekly:
            // One repeating trigger per (weekday × time). iOS fires a
            // weekday+hour+minute match every week automatically.
            for weekday in med.repeatRule.weekdays {
                for (index, time) in med.times.enumerated() {
                    var comps = DateComponents()
                    comps.weekday = weekday
                    comps.hour = time.hour
                    comps.minute = time.minute
                    let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
                    let req = UNNotificationRequest(
                        identifier: "\(idPrefix(med.id))w\(weekday)-t\(index)",
                        content: content(),
                        trigger: trigger
                    )
                    try? await center.add(req)
                }
            }

        case .biweekly:
            // No native "every other week" trigger — schedule a rolling
            // window of explicit future dates (non-repeating), topped
            // up by syncAll() on each app launch.
            let cal = Calendar.current
            for weekday in med.repeatRule.weekdays {
                for (index, time) in med.times.enumerated() {
                    let dates = upcomingBiweeklyDates(
                        med: med, weekday: weekday, time: time, count: biweeklyWindow, calendar: cal
                    )
                    for (occurrence, date) in dates.enumerated() {
                        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
                        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                        let req = UNNotificationRequest(
                            identifier: "\(idPrefix(med.id))bw\(weekday)-t\(index)-\(occurrence)",
                            content: content(),
                            trigger: trigger
                        )
                        try? await center.add(req)
                    }
                }
            }
        }
    }

    /// Future dates a biweekly med fires on for a given weekday+time,
    /// honoring the start-date week parity from `Medication.isScheduled`.
    private static func upcomingBiweeklyDates(
        med: Medication,
        weekday: Int,
        time: Medication.TimeOfDay,
        count: Int,
        calendar cal: Calendar
    ) -> [Date] {
        var result: [Date] = []
        var probe = cal.startOfDay(for: Date())
        var guardCounter = 0
        // Walk forward day by day, collecting matching scheduled days.
        while result.count < count && guardCounter < 400 {
            guardCounter += 1
            if cal.component(.weekday, from: probe) == weekday,
               med.isScheduled(on: probe) {
                var comps = cal.dateComponents([.year, .month, .day], from: probe)
                comps.hour = time.hour
                comps.minute = time.minute
                if let fireDate = cal.date(from: comps), fireDate > Date() {
                    result.append(fireDate)
                }
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: probe) else { break }
            probe = next
        }
        return result
    }

    /// Cancel all of a medication's reminders by matching the id
    /// prefix — covers every scheme (daily/weekly/biweekly) without
    /// needing to know which the med used.
    static func cancel(medID: UUID) async {
        let prefix = idPrefix(medID)
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        let ids = pending.map(\.identifier).filter { $0.hasPrefix(prefix) }
        if !ids.isEmpty {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    /// Re-sync every active medication's reminders. Called on app
    /// activation so reminders survive edits made while the app was
    /// backgrounded, recover if iOS dropped pending requests, and —
    /// importantly — top up the rolling window for biweekly meds.
    static func syncAll() async {
        for med in Medication.loadAll() {
            await sync(med)
        }
    }

    /// Profile → Reset App: wipe meds + adherence + every reminder.
    static func resetAll() {
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            let medIDs = requests.map(\.identifier).filter { $0.hasPrefix("med-") }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: medIDs)
        }
        Medication.resetAll()
    }
}
