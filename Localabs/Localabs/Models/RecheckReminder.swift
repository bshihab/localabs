import Foundation

/// A reminder to re-scan a lab marker that was trending the wrong way,
/// so the user comes back when they'd otherwise forget (e.g. the
/// doctor's "recheck your A1c in 3 months"). Set from a highlighted
/// out-of-range value's action menu (#31); fires a local notification
/// on `dueDate` that deep-links to the scanner.
struct RecheckReminder: Codable, Identifiable, Equatable {
    let id: UUID
    /// Display name of the marker, e.g. "LDL Cholesterol".
    var marker: String
    var dueDate: Date
    var createdAt: Date

    init(id: UUID = UUID(), marker: String, dueDate: Date, createdAt: Date = Date()) {
        self.id = id
        self.marker = marker
        self.dueDate = dueDate
        self.createdAt = createdAt
    }

    /// Normalized key for matching (same scheme as lab-trend joins) so
    /// "LDL Cholesterol" and "ldl cholesterol" are the same marker.
    var key: String { LabValue.normalizeKey(marker) }
}

/// Persistence for recheck reminders + the user's default recheck
/// interval. One UserDefaults key each — same lightweight pattern as the
/// rest of the app.
enum RecheckStore {
    private static let listKey = "localabs_recheck_reminders"
    private static let intervalKey = "localabs_recheck_default_months"
    private static let optedOutKey = "localabs_recheck_optedout"

    static func all() -> [RecheckReminder] {
        guard
            let data = UserDefaults.standard.data(forKey: listKey),
            let list = try? JSONDecoder().decode([RecheckReminder].self, from: data)
        else { return [] }
        return list.sorted { $0.dueDate < $1.dueDate }
    }

    static func reminder(forMarker marker: String) -> RecheckReminder? {
        let k = LabValue.normalizeKey(marker)
        return all().first { $0.key == k }
    }

    static func isSet(forMarker marker: String) -> Bool {
        reminder(forMarker: marker) != nil
    }

    /// Insert or replace the reminder for a marker (one per marker).
    static func save(_ reminder: RecheckReminder) {
        var list = all().filter { $0.key != reminder.key }
        list.append(reminder)
        persist(list)
    }

    static func remove(id: UUID) {
        persist(all().filter { $0.id != id })
    }

    private static func persist(_ list: [RecheckReminder]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: listKey)
    }

    /// Default months until a recheck, used when the user flips the
    /// reminder toggle. Defaults to 3 (the common "recheck in 3 months").
    static var defaultIntervalMonths: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: intervalKey)
            return v == 0 ? 3 : v
        }
        set { UserDefaults.standard.set(newValue, forKey: intervalKey) }
    }

    // MARK: - Opt-out (markers the user turned OFF)

    /// Out-of-range markers default to ON (auto-scheduled at scan). When
    /// the user turns one OFF, we remember it here so it isn't re-created
    /// the next time the same marker is scanned.
    static func optedOut() -> Set<String> {
        guard
            let data = UserDefaults.standard.data(forKey: optedOutKey),
            let set = try? JSONDecoder().decode(Set<String>.self, from: data)
        else { return [] }
        return set
    }

    static func isOptedOut(_ marker: String) -> Bool {
        optedOut().contains(LabValue.normalizeKey(marker))
    }

    static func setOptedOut(_ marker: String, _ on: Bool) {
        var set = optedOut()
        let k = LabValue.normalizeKey(marker)
        if on { set.insert(k) } else { set.remove(k) }
        if let data = try? JSONEncoder().encode(set) {
            UserDefaults.standard.set(data, forKey: optedOutKey)
        }
    }

    static func resetAll() {
        UserDefaults.standard.removeObject(forKey: listKey)
        UserDefaults.standard.removeObject(forKey: intervalKey)
        UserDefaults.standard.removeObject(forKey: optedOutKey)
    }
}
