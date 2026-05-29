import Foundation

/// A medication the user is tracking — either added manually or
/// linked from a scanned report. Drives the Meds tab and a set of
/// repeating local-notification reminders (one per scheduled time).
///
/// Persisted as JSON in a single UserDefaults key
/// (`localabs_medications`), same pattern as `SymptomEntry` and
/// `UserProfile` — no new storage backend. Adherence (which doses
/// were marked taken) lives in a separate keyed set so toggling a
/// dose doesn't rewrite the whole medication list.
///
/// IMPORTANT: Localabs never invents a medication. Meds come from
/// what a report explicitly lists or what the user types — the same
/// contract the report's Medication Notes section follows.
struct Medication: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    /// Free-form dose string, e.g. "500 mg", "1 tablet", "10 units".
    var dose: String
    /// Scheduled times of day for reminders. Each becomes its own
    /// repeating daily notification. Empty = tracked but no reminders.
    var times: [TimeOfDay]
    var startDate: Date
    /// nil = ongoing. When set, the med drops to "Past" after this date.
    var endDate: Date?
    var notes: String
    /// Links back to the report this med was added from, if any.
    var sourceReportID: UUID?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        dose: String = "",
        times: [TimeOfDay] = [],
        startDate: Date = Date(),
        endDate: Date? = nil,
        notes: String = "",
        sourceReportID: UUID? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.dose = dose
        self.times = times
        self.startDate = startDate
        self.endDate = endDate
        self.notes = notes
        self.sourceReportID = sourceReportID
        self.createdAt = createdAt
    }

    /// Active = started on/before today and not past its end date.
    /// Drives the Active vs. Past split in the Meds tab.
    var isActive: Bool {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        if cal.startOfDay(for: startDate) > today { return false }
        if let end = endDate, cal.startOfDay(for: end) < today { return false }
        return true
    }

    /// One-line human summary of the schedule, e.g. "Twice daily ·
    /// 8:00 AM, 8:00 PM" or "As needed" when no times are set.
    var scheduleSummary: String {
        guard !times.isEmpty else { return "As needed" }
        let freq: String
        switch times.count {
        case 1:  freq = "Once daily"
        case 2:  freq = "Twice daily"
        case 3:  freq = "Three times daily"
        default: freq = "\(times.count)× daily"
        }
        let formatted = times
            .sorted()
            .map(\.displayString)
            .joined(separator: ", ")
        return "\(freq) · \(formatted)"
    }

    /// A time of day for a reminder. Stored as hour/minute so it's
    /// timezone-stable and maps cleanly to a UNCalendarNotificationTrigger.
    struct TimeOfDay: Codable, Equatable, Comparable, Identifiable {
        var hour: Int      // 0–23
        var minute: Int    // 0–59

        var id: String { "\(hour):\(minute)" }

        static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool {
            (lhs.hour, lhs.minute) < (rhs.hour, rhs.minute)
        }

        /// 12-hour display string ("8:00 AM"). Uses the device
        /// locale's formatter so 24-hour-clock users see their format.
        var displayString: String {
            var comps = DateComponents()
            comps.hour = hour
            comps.minute = minute
            let cal = Calendar.current
            guard let date = cal.date(from: comps) else { return "\(hour):\(minute)" }
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }

        /// Which part of the day this falls in — drives the
        /// Morning/Afternoon/Evening/Night grouping in the Today view.
        var dayPart: DayPart {
            switch hour {
            case 5..<12:  return .morning
            case 12..<17: return .afternoon
            case 17..<21: return .evening
            default:      return .night
            }
        }
    }

    enum DayPart: Int, CaseIterable {
        case morning, afternoon, evening, night
        var label: String {
            switch self {
            case .morning:   return "Morning"
            case .afternoon: return "Afternoon"
            case .evening:   return "Evening"
            case .night:     return "Night"
            }
        }
    }
}

// MARK: - Persistence

extension Medication {
    private static let storageKey = "localabs_medications"

    /// All medications, newest-created first.
    static func loadAll() -> [Medication] {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let meds = try? JSONDecoder().decode([Medication].self, from: data)
        else { return [] }
        return meds.sorted { $0.createdAt > $1.createdAt }
    }

    static var active: [Medication] { loadAll().filter(\.isActive) }
    static var past: [Medication] { loadAll().filter { !$0.isActive } }

    /// Insert or replace by id, then re-sync this med's reminders.
    static func save(_ med: Medication) {
        var meds = loadAll()
        if let idx = meds.firstIndex(where: { $0.id == med.id }) {
            meds[idx] = med
        } else {
            meds.insert(med, at: 0)
        }
        persist(meds)
    }

    /// Remove a med, its reminders, and its adherence records.
    static func delete(id: UUID) {
        var meds = loadAll()
        meds.removeAll { $0.id == id }
        persist(meds)
        MedicationAdherence.clear(medID: id)
    }

    /// Called from Profile → Reset App. Wipes meds + adherence;
    /// the caller (MedicationService) cancels notifications.
    static func resetAll() {
        UserDefaults.standard.removeObject(forKey: storageKey)
        MedicationAdherence.resetAll()
    }

    /// When a report is deleted, meds added from it keep working
    /// (the user is still taking them) — we only drop the now-broken
    /// source link. Mirrors SymptomEntry.nullifyLinks.
    static func nullifyLinks(toReport reportID: UUID) {
        var meds = loadAll()
        var changed = false
        for i in meds.indices where meds[i].sourceReportID == reportID {
            meds[i].sourceReportID = nil
            changed = true
        }
        if changed { persist(meds) }
    }

    private static func persist(_ meds: [Medication]) {
        guard let data = try? JSONEncoder().encode(meds) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

/// Tracks which specific dose occurrences (a medication + a calendar
/// day + a time-index) the user has marked as taken. Kept separate
/// from the Medication list so checking off a dose is a cheap
/// targeted write, not a full re-encode of every medication.
enum MedicationAdherence {
    private static let storageKey = "localabs_med_adherence"

    /// Stable key for one dose occurrence.
    private static func key(medID: UUID, date: Date, timeIndex: Int) -> String {
        let day = dayString(date)
        return "\(medID.uuidString)|\(day)|\(timeIndex)"
    }

    private static func dayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private static func loadTaken() -> Set<String> {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let set = try? JSONDecoder().decode(Set<String>.self, from: data)
        else { return [] }
        return set
    }

    private static func persist(_ set: Set<String>) {
        guard let data = try? JSONEncoder().encode(set) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    static func isTaken(medID: UUID, date: Date, timeIndex: Int) -> Bool {
        loadTaken().contains(key(medID: medID, date: date, timeIndex: timeIndex))
    }

    static func setTaken(_ taken: Bool, medID: UUID, date: Date, timeIndex: Int) {
        var set = loadTaken()
        let k = key(medID: medID, date: date, timeIndex: timeIndex)
        if taken { set.insert(k) } else { set.remove(k) }
        persist(set)
    }

    /// Consecutive-day streak counting back from today. A day counts
    /// toward the streak only if every scheduled dose that day was
    /// marked taken. Today is included only once all of today's doses
    /// are done (so an in-progress day doesn't break the streak —
    /// it just doesn't extend it yet). Returns 0 for meds with no
    /// scheduled times (nothing to adhere to).
    static func streak(for med: Medication) -> Int {
        guard !med.times.isEmpty else { return 0 }
        let cal = Calendar.current
        var streak = 0
        var day = cal.startOfDay(for: Date())

        // If today isn't fully done, start counting from yesterday so
        // a partial today doesn't zero out an otherwise-good streak.
        if !allDosesTaken(for: med, on: day) {
            day = cal.date(byAdding: .day, value: -1, to: day) ?? day
        }

        let start = cal.startOfDay(for: med.startDate)
        while day >= start {
            if allDosesTaken(for: med, on: day) {
                streak += 1
                guard let prev = cal.date(byAdding: .day, value: -1, to: day) else { break }
                day = prev
            } else {
                break
            }
        }
        return streak
    }

    private static func allDosesTaken(for med: Medication, on day: Date) -> Bool {
        guard !med.times.isEmpty else { return false }
        let taken = loadTaken()
        for idx in med.times.indices {
            if !taken.contains(key(medID: med.id, date: day, timeIndex: idx)) {
                return false
            }
        }
        return true
    }

    /// Drop every adherence record for a deleted medication so the
    /// taken-set doesn't accumulate orphans.
    static func clear(medID: UUID) {
        let prefix = "\(medID.uuidString)|"
        var set = loadTaken()
        set = set.filter { !$0.hasPrefix(prefix) }
        persist(set)
    }

    static func resetAll() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}
