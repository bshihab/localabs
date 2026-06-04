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

/// A completed doctor visit, archived when the user finishes the
/// post-visit check-in (#34, #4). Keeps a lightweight record — when the
/// visit was, what it was for, and the instructions the user logged —
/// so the "Past visits" history in the visit hub can show what's already
/// been handled. Stored as a JSON array in one UserDefaults key.
struct PastVisit: Codable, Equatable, Identifiable {
    var id: UUID
    /// When the visit took place.
    var date: Date
    /// Who/what the visit was for (the appointment note). May be empty.
    var note: String
    /// The questions the user prepared *before* the visit (from Visit
    /// Prep), captured at check-in so the history shows both sides. May be
    /// empty. Optional in the decoder so visits archived before this field
    /// existed still load.
    var preVisitQuestions: [String]
    /// Instructions or diagnoses the user logged afterward. May be empty.
    var instructions: String
    /// When the user completed the check-in.
    var loggedAt: Date

    init(
        id: UUID = UUID(),
        date: Date,
        note: String = "",
        preVisitQuestions: [String] = [],
        instructions: String = "",
        loggedAt: Date = Date()
    ) {
        self.id = id
        self.date = date
        self.note = note
        self.preVisitQuestions = preVisitQuestions
        self.instructions = instructions
        self.loggedAt = loggedAt
    }

    // Custom decoder so visits saved before `preVisitQuestions` existed
    // still decode (it defaults to empty).
    enum CodingKeys: String, CodingKey {
        case id, date, note, preVisitQuestions, instructions, loggedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        date = try c.decode(Date.self, forKey: .date)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        preVisitQuestions = try c.decodeIfPresent([String].self, forKey: .preVisitQuestions) ?? []
        instructions = try c.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        loggedAt = try c.decodeIfPresent(Date.self, forKey: .loggedAt) ?? Date()
    }
}

/// Archive of completed visits, shown in the visit hub's "Past visits"
/// section. Newest first; capped so the list can't grow unbounded.
enum VisitHistory {
    private static let storageKey = "localabs_past_visits"
    private static let maxEntries = 50

    /// All archived visits, newest visit date first.
    static func all() -> [PastVisit] {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let list = try? JSONDecoder().decode([PastVisit].self, from: data)
        else { return [] }
        return list.sorted { $0.date > $1.date }
    }

    /// Append a completed visit, trimming the oldest beyond the cap.
    static func add(_ visit: PastVisit) {
        var list = all()
        list.removeAll { $0.id == visit.id }
        list.insert(visit, at: 0)
        let trimmed = Array(list.prefix(maxEntries))
        guard let data = try? JSONEncoder().encode(trimmed) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    static func remove(id: UUID) {
        let remaining = all().filter { $0.id != id }
        guard let data = try? JSONEncoder().encode(remaining) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
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
