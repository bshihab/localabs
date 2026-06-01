import Foundation
import UserNotifications

/// Evaluates the user's armed Trends threshold alerts against fresh
/// Apple Health data and fires local notifications when a metric has
/// been drifting outside its age/sex-adjusted norm. The notification
/// is enriched with past-report context when a relevant condition is
/// on file ("...and your March cardiology report flagged this"),
/// which is the differentiator over Apple Health's generic alerts.
///
/// Evaluation runs on the foreground path — every time the app
/// becomes active (wired in ContentView). That's the reliable
/// trigger; iOS background refresh is heavily throttled and a poor
/// fit for a v1. A background-refresh path can be layered on later
/// (it needs careful Swift 6 BGTask concurrency handling + on-device
/// testing) without changing any of the evaluation logic here.
///
/// Everything stays on-device: HealthKit reads are local, the
/// notification is a local UNNotificationRequest, no network.
@MainActor
final class HealthAlertService {
    static let shared = HealthAlertService()
    private init() {}

    /// Don't re-fire the same metric within this window — an ongoing
    /// condition (e.g. resting HR elevated for two weeks) should
    /// nudge once, not every evaluation. Three days balances "don't
    /// nag" against "remind me it's still off."
    private let cooldown: TimeInterval = 3 * 24 * 60 * 60

    private let firedStateKey = "localabs_health_alerts_fired"
    private let logKey = "localabs_health_alerts_log"

    // MARK: - Notification authorization

    /// Requests notification permission if the user has armed at
    /// least one alert and we haven't asked yet. Called when the
    /// user enables their first alert in settings. Safe to call
    /// repeatedly — UNUserNotificationCenter no-ops once decided.
    func requestAuthorizationIfNeeded() async {
        guard HealthAlertConfig.anyEnabled else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    // MARK: - Evaluation

    /// Pulls a fresh 30-day snapshot, runs every armed alert through
    /// the same `HealthInsights` bands the Trends cards use, and
    /// fires a notification for any metric that's been at-or-worse
    /// than its configured sensitivity for the last N readings (and
    /// isn't in its cooldown window). Returns the number fired.
    @discardableResult
    func evaluate() async -> Int {
        let configs = HealthAlertConfig.loadAll().filter(\.enabled)
        guard !configs.isEmpty else { return 0 }

        // Don't fire into the void — if the user revoked notification
        // permission, skip the work entirely.
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else {
            return 0
        }

        let snapshot = await HealthKitService.shared.getTrends(rangeDays: 30)
        let profile = UserProfile.load()
        let age = profile.ageYears
        let sex = HealthInsights.BiologicalSex.from(profile.biologicalSex)

        var fired = 0
        var firedState = loadFiredState()

        for config in configs {
            guard let series = series(for: config.metric, in: snapshot),
                  series.hasData,
                  let context = HealthInsights.clinicalContext(for: config.metric.clinicalLabel)
            else { continue }

            // Most recent N readings, oldest→newest, take the tail.
            let recent = series.daily
                .sorted { $0.date < $1.date }
                .suffix(config.consecutivePoints)
            guard recent.count >= config.consecutivePoints else { continue }

            let allTrip = recent.allSatisfy { point in
                let status = context.interpret(point.value, age, sex)
                return severity(status) >= config.sensitivity.minSeverity
            }
            guard allTrip else { continue }

            // Cooldown gate.
            if let last = firedState[config.metric.rawValue],
               Date().timeIntervalSince(last) < cooldown {
                continue
            }

            let latest = recent.last!
            await fire(
                config: config,
                latestValue: latest.value,
                unit: series.unit,
                typicalRange: context.typicalRangeLabel(age, sex),
                consecutivePoints: config.consecutivePoints
            )
            firedState[config.metric.rawValue] = Date()
            fired += 1
        }

        if fired > 0 { saveFiredState(firedState) }
        return fired
    }

    // MARK: - Firing

    private func fire(
        config: HealthAlertConfig,
        latestValue: Double,
        unit: String,
        typicalRange: String,
        consecutivePoints: Int
    ) async {
        let valueStr = formatValue(latestValue, unit: unit)
        let title = "\(config.metric.displayName) outside your typical range"

        var body = "Your last \(consecutivePoints) readings were outside range (most recent \(valueStr); typical is \(typicalRange))."
        if let reportNote = pastReportNote(for: config.metric) {
            body += " \(reportNote)"
        } else {
            body += " Tap to review in Trends."
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["metric": config.metric.rawValue, "deepLink": "trends"]
        // Group all health alerts so they collapse in Notification
        // Center rather than stacking one row per metric.
        content.threadIdentifier = "health-alerts"

        let request = UNNotificationRequest(
            identifier: "health-alert-\(config.metric.rawValue)",
            content: content,
            trigger: nil  // deliver immediately
        )
        try? await UNUserNotificationCenter.current().add(request)

        appendLog(
            FiredAlert(
                id: UUID(),
                metricRawValue: config.metric.rawValue,
                title: title,
                body: body,
                date: Date()
            )
        )
    }

    /// Finds the most recent past report whose text references a
    /// condition related to this metric, and returns a sentence
    /// connecting the two. Nil when nothing relevant is on file.
    private func pastReportNote(for metric: AlertMetric) -> String? {
        let history = LocalStorageService.shared.getHistory()
        let keywords = metric.reportKeywords
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM"

        for report in history {  // history is newest-first
            let haystack = (
                report.patientSummary + " " +
                report.rawText + " " +
                report.medicationNotes
            ).lowercased()
            if keywords.contains(where: { haystack.contains($0) }) {
                let month = formatter.string(from: report.timestamp)
                return "Your \(month) report touched on this — worth reviewing together."
            }
        }
        return nil
    }

    // MARK: - Snapshot mapping

    /// Maps an AlertMetric to its MetricSeries inside a snapshot.
    /// Kept here (rather than on TrendsSnapshot) so the alert
    /// feature owns its own coupling to the snapshot shape.
    private func series(
        for metric: AlertMetric,
        in snapshot: HealthKitService.TrendsSnapshot
    ) -> HealthKitService.MetricSeries? {
        switch metric {
        case .restingHR:    return snapshot.restingHR
        case .hrv:          return snapshot.hrv
        case .sleep:        return snapshot.sleepHours
        case .vo2Max:       return snapshot.vo2Max
        case .systolicBP:   return snapshot.systolicBP
        case .diastolicBP:  return snapshot.diastolicBP
        case .oxygen:       return snapshot.oxygenSaturation
        case .respiratory:  return snapshot.respiratoryRate
        case .bloodGlucose: return snapshot.bloodGlucose
        case .bmi:          return snapshot.bodyMassIndex
        }
    }

    // MARK: - Helpers

    private func severity(_ status: HealthInsights.Status) -> Int {
        switch status {
        case .good:        return 0
        case .borderline:  return 1
        case .concerning:  return 2
        case .unknown:     return -1  // never trips
        }
    }

    private func formatValue(_ value: Double, unit: String) -> String {
        // Whole numbers for count-like units, one decimal otherwise.
        let isWhole = value.rounded() == value
        let num = isWhole ? String(format: "%.0f", value) : String(format: "%.1f", value)
        return "\(num) \(unit)"
    }

    // MARK: - Fired-state persistence (dedup cooldown)

    private func loadFiredState() -> [String: Date] {
        guard let data = UserDefaults.standard.data(forKey: firedStateKey),
              let decoded = try? JSONDecoder().decode([String: Date].self, from: data)
        else { return [:] }
        return decoded
    }

    private func saveFiredState(_ state: [String: Date]) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: firedStateKey)
    }

    // MARK: - Recent-alerts log (shown in settings)

    func recentLog() -> [FiredAlert] {
        guard let data = UserDefaults.standard.data(forKey: logKey),
              let decoded = try? JSONDecoder().decode([FiredAlert].self, from: data)
        else { return [] }
        return decoded.sorted { $0.date > $1.date }
    }

    private func appendLog(_ entry: FiredAlert) {
        var log = recentLog()
        log.insert(entry, at: 0)
        log = Array(log.prefix(20))  // keep the list short
        if let data = try? JSONEncoder().encode(log) {
            UserDefaults.standard.set(data, forKey: logKey)
        }
    }

    // MARK: - Reset

    /// Wipes alert configs, dedup state, and the log. Called from
    /// Profile → Reset App alongside the other storage wipes.
    static func resetAll() {
        HealthAlertConfig.resetAll()
        UserDefaults.standard.removeObject(forKey: "localabs_health_alerts_fired")
        UserDefaults.standard.removeObject(forKey: "localabs_health_alerts_log")
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }
}

/// One past alert firing, shown in the settings "Recent alerts"
/// list so the user can see what tripped and when.
struct FiredAlert: Codable, Identifiable, Equatable {
    let id: UUID
    let metricRawValue: String
    let title: String
    let body: String
    let date: Date
}
