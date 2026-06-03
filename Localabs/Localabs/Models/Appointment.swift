import Foundation

/// A doctor visit the user is preparing for. v1 stores a single
/// "upcoming" appointment — a date plus an optional note (e.g. "Annual
/// physical with Dr. Lee"). Pre-visit prep mode (#30) reads and writes
/// it; the post-visit check-in (#34) will schedule its evening
/// notification from `date`.
///
/// Persisted as JSON in one UserDefaults key, the same lightweight
/// pattern as `UserProfile` and `SymptomEntry` — no new storage backend.
struct Appointment: Codable, Equatable {
    var date: Date
    /// Free-form note: who the visit is with / what it's for. Optional.
    var note: String

    init(date: Date, note: String = "") {
        self.date = date
        self.note = note
    }

    private static let storageKey = "localabs_upcoming_appointment"

    /// The currently-saved upcoming appointment, if any.
    static func loadUpcoming() -> Appointment? {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let appt = try? JSONDecoder().decode(Appointment.self, from: data)
        else { return nil }
        return appt
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}

/// The user's personal "questions to ask my doctor" list for the next
/// visit. Kept separate from `Appointment` so it survives even when no
/// appointment date is set, and so seeded suggestions (recomputed each
/// time) stay distinct from what the user deliberately kept.
enum VisitPrepQuestions {
    private static let storageKey = "localabs_visit_questions"

    static func load() -> [String] {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let list = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return list
    }

    static func save(_ list: [String]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}
