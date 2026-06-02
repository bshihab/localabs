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
    /// Scheduled times of day for reminders. Each time fires on the
    /// days selected by `repeatRule`. Empty = tracked but no reminders.
    var times: [TimeOfDay]
    /// Which days the medication is taken on — every day, specific
    /// weekdays weekly, or specific weekdays every other week.
    var repeatRule: RepeatRule
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
        repeatRule: RepeatRule = .daily,
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
        self.repeatRule = repeatRule
        self.startDate = startDate
        self.endDate = endDate
        self.notes = notes
        self.sourceReportID = sourceReportID
        self.createdAt = createdAt
    }

    // Custom decoder so medications saved before `repeatRule` existed
    // still load — the missing key defaults to `.daily` rather than
    // failing the whole decode (which would silently drop every med).
    enum CodingKeys: String, CodingKey {
        case id, name, dose, times, repeatRule, startDate, endDate, notes, sourceReportID, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        dose = try c.decode(String.self, forKey: .dose)
        times = try c.decode([TimeOfDay].self, forKey: .times)
        repeatRule = try c.decodeIfPresent(RepeatRule.self, forKey: .repeatRule) ?? .daily
        startDate = try c.decode(Date.self, forKey: .startDate)
        endDate = try c.decodeIfPresent(Date.self, forKey: .endDate)
        notes = try c.decode(String.self, forKey: .notes)
        sourceReportID = try c.decodeIfPresent(UUID.self, forKey: .sourceReportID)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
    }

    /// How often, in terms of *days*, the medication recurs. The
    /// times-of-day (`times`) are orthogonal — they say when within a
    /// given day; this says which days.
    struct RepeatRule: Codable, Equatable {
        enum Cadence: String, Codable { case daily, weekly, biweekly }
        var cadence: Cadence
        /// Calendar weekdays (1 = Sunday … 7 = Saturday). Ignored for
        /// `.daily`. For `.weekly`/`.biweekly`, the days the med is taken.
        var weekdays: [Int]

        static let daily = RepeatRule(cadence: .daily, weekdays: [])

        /// Short human label, e.g. "Every day", "Mon, Thu",
        /// "Every 2 weeks · Mon".
        var summary: String {
            switch cadence {
            case .daily:
                return "Every day"
            case .weekly:
                return weekdayList
            case .biweekly:
                return "Every 2 weeks · \(weekdayList)"
            }
        }

        private var weekdayList: String {
            guard !weekdays.isEmpty else { return "—" }
            let symbols = Calendar.current.shortWeekdaySymbols  // ["Sun","Mon",…]
            return weekdays
                .sorted()
                .compactMap { wd in
                    (1...7).contains(wd) ? symbols[wd - 1] : nil
                }
                .joined(separator: ", ")
        }
    }

    /// Whether the medication is due on a given calendar day, per its
    /// repeat rule. Daily = always; weekly = the day's weekday is in
    /// the set; biweekly = weekday is in the set AND the day falls in
    /// an "on" week relative to `startDate` (week parity). Used for
    /// both the Today schedule and the adherence streak.
    func isScheduled(on day: Date) -> Bool {
        let cal = Calendar.current
        switch repeatRule.cadence {
        case .daily:
            return true
        case .weekly:
            let wd = cal.component(.weekday, from: day)
            return repeatRule.weekdays.contains(wd)
        case .biweekly:
            let wd = cal.component(.weekday, from: day)
            guard repeatRule.weekdays.contains(wd) else { return false }
            // Week parity: count whole weeks between the start week and
            // this day's week; even = an "on" week.
            let startWeek = cal.dateInterval(of: .weekOfYear, for: startDate)?.start ?? startDate
            let dayWeek = cal.dateInterval(of: .weekOfYear, for: day)?.start ?? day
            let weeks = cal.dateComponents([.weekOfYear], from: startWeek, to: dayWeek).weekOfYear ?? 0
            return abs(weeks) % 2 == 0
        }
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

    /// One-line human summary of the schedule. Combines the day
    /// cadence with the times of day, e.g.:
    ///   daily   → "Twice daily · 8:00 AM, 8:00 PM"
    ///   weekly  → "Mon, Thu · 8:00 AM, 8:00 PM"
    ///   biweekly→ "Every 2 weeks · Mon · 8:00 AM"
    /// "As needed" when no times are set.
    var scheduleSummary: String {
        guard !times.isEmpty else { return "As needed" }
        let formattedTimes = times
            .sorted()
            .map(\.displayString)
            .joined(separator: ", ")

        switch repeatRule.cadence {
        case .daily:
            let freq: String
            switch times.count {
            case 1:  freq = "Once daily"
            case 2:  freq = "Twice daily"
            case 3:  freq = "Three times daily"
            default: freq = "\(times.count)× daily"
            }
            return "\(freq) · \(formattedTimes)"
        case .weekly, .biweekly:
            return "\(repeatRule.summary) · \(formattedTimes)"
        }
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

// MARK: - LLM prompt context

extension Medication {
    /// One compact line describing this medication for the on-device
    /// model's context, e.g.
    ///   "Atorvastatin 20 mg — once daily, ongoing since Mar 2025"
    ///   "Amoxicillin 500 mg — three times daily, course Jun 1 – Jun 10 2025"
    /// The model reads these SILENTLY to interpret lab values (a statin
    /// contextualizes an LDL trend; a diuretic contextualizes potassium)
    /// — never to invent or recommend a medication.
    var promptLine: String {
        var head = name
        let d = dose.trimmingCharacters(in: .whitespaces)
        if !d.isEmpty { head += " \(d)" }
        var tail: [String] = []
        let freq = promptFrequencyPhrase
        if !freq.isEmpty { tail.append(freq) }
        tail.append(promptDurationPhrase)
        return "\(head) — \(tail.joined(separator: ", "))"
    }

    private var promptFrequencyPhrase: String {
        guard !times.isEmpty else { return "as needed" }
        switch repeatRule.cadence {
        case .daily:
            switch times.count {
            case 1:  return "once daily"
            case 2:  return "twice daily"
            case 3:  return "three times daily"
            default: return "\(times.count)× daily"
            }
        case .weekly:   return "weekly on \(repeatRule.summary)"
        case .biweekly: return repeatRule.summary  // "Every 2 weeks · Mon"
        }
    }

    private var promptDurationPhrase: String {
        let monthYear = DateFormatter()
        monthYear.dateFormat = "MMM yyyy"
        guard let end = endDate else {
            return "ongoing since \(monthYear.string(from: startDate))"
        }
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "MMM d yyyy"
        return "course \(dayFmt.string(from: startDate)) – \(dayFmt.string(from: end))"
    }

    /// Bullet block of every ACTIVE medication, for injection into the
    /// model prompt. Empty when the user tracks none, so the caller can
    /// omit the section entirely. The 8-space indentation on the joiner
    /// matches the multi-line prompt strings in InferenceEngine.
    static func promptContextBlock() -> String {
        let active = loadAll().filter(\.isActive)
        guard !active.isEmpty else { return "" }
        return active
            .map { "- \($0.promptLine)" }
            .joined(separator: "\n        ")
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

    /// Consecutive-scheduled-day streak counting back from today. Only
    /// days the med is actually due (per its repeat rule) count; days
    /// it isn't scheduled are skipped over, not treated as misses — so
    /// a Mon/Thu med doesn't lose its streak on a Tuesday. A scheduled
    /// day extends the streak only if every dose that day was taken.
    /// Today, if scheduled but not yet fully taken, is skipped (doesn't
    /// break the streak — just doesn't extend it yet). Returns 0 for
    /// meds with no scheduled times.
    static func streak(for med: Medication) -> Int {
        guard !med.times.isEmpty else { return 0 }
        let cal = Calendar.current
        var streak = 0
        var day = cal.startOfDay(for: Date())
        let start = cal.startOfDay(for: med.startDate)

        // Skip an in-progress today: if today is scheduled but not yet
        // fully taken, step back a day before counting so it doesn't
        // zero out an otherwise-good streak.
        if med.isScheduled(on: day) && !allDosesTaken(for: med, on: day) {
            day = cal.date(byAdding: .day, value: -1, to: day) ?? day
        }

        // Walk back up to ~1 year. Non-scheduled days are skipped;
        // a scheduled day with a miss ends the streak.
        var guardCounter = 0
        while day >= start && guardCounter < 400 {
            guardCounter += 1
            if med.isScheduled(on: day) {
                if allDosesTaken(for: med, on: day) {
                    streak += 1
                } else {
                    break
                }
            }
            guard let prev = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
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
