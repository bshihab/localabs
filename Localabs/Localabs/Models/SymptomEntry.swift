import Foundation

/// One logged symptom — the user's record of how they were feeling
/// at a moment in time. Lives in the History tab as a running
/// timeline alongside scanned reports, and feeds pre-visit prep
/// mode (a future feature) so the question generator can surface
/// recurring symptoms.
///
/// Persisted as JSON inside a single UserDefaults key
/// (`localabs_symptoms`), same pattern as `UserProfile` — keeps
/// reset / delete simple and avoids introducing a new storage
/// backend. Optional `linkedReportID` ties an entry to a specific
/// scan when the symptom relates to a known condition.
struct SymptomEntry: Codable, Identifiable, Equatable {
    let id: UUID
    var text: String
    var intensity: Intensity
    var timestamp: Date
    var tags: [String]
    var linkedReportID: UUID?

    init(
        id: UUID = UUID(),
        text: String,
        intensity: Intensity,
        timestamp: Date = Date(),
        tags: [String] = [],
        linkedReportID: UUID? = nil
    ) {
        self.id = id
        self.text = text
        self.intensity = intensity
        self.timestamp = timestamp
        self.tags = tags
        self.linkedReportID = linkedReportID
    }

    /// 5-point intensity scale — rendered as emoji faces in the
    /// quick-add picker and in timeline rows. Coarser than a 1–10
    /// slider on purpose: most users can't reliably distinguish a
    /// 6 from a 7, but everyone can tell a 😟 from a 😫.
    enum Intensity: Int, Codable, CaseIterable {
        case veryMild = 1
        case mild = 2
        case moderate = 3
        case strong = 4
        case severe = 5

        var emoji: String {
            switch self {
            case .veryMild: return "😊"
            case .mild:     return "🙂"
            case .moderate: return "😐"
            case .strong:   return "😟"
            case .severe:   return "😫"
            }
        }

        var label: String {
            switch self {
            case .veryMild: return "Very mild"
            case .mild:     return "Mild"
            case .moderate: return "Moderate"
            case .strong:   return "Strong"
            case .severe:   return "Severe"
            }
        }
    }
}

// MARK: - Persistence

extension SymptomEntry {
    private static let storageKey = "localabs_symptoms"

    /// Newest first. Sort is done on every load rather than on
    /// write so manually-edited timestamps (the user may backdate
    /// an entry from "log a symptom from yesterday") sort correctly
    /// without requiring a re-shuffle pass on save.
    static func loadAll() -> [SymptomEntry] {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let entries = try? JSONDecoder().decode([SymptomEntry].self, from: data)
        else {
            return []
        }
        return entries.sorted { $0.timestamp > $1.timestamp }
    }

    /// Insert a new entry, or replace an existing one in place when
    /// the id matches (used by the edit-from-timeline flow).
    static func save(_ entry: SymptomEntry) {
        var entries = loadAll()
        if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[idx] = entry
        } else {
            entries.insert(entry, at: 0)
        }
        persist(entries)
    }

    static func delete(id: UUID) {
        var entries = loadAll()
        entries.removeAll { $0.id == id }
        persist(entries)
    }

    /// Called by Profile → Reset App alongside the other wipe paths
    /// in LocalStorageService.clearHistory(). Without this, reset
    /// would leave symptom entries behind as orphans.
    static func resetAll() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    /// When a report is deleted, any symptom whose `linkedReportID`
    /// pointed at it gets the link nullified — the user logged the
    /// symptom intending to keep it, so we preserve the entry and
    /// only drop the source attribution.
    static func nullifyLinks(toReport reportID: UUID) {
        var entries = loadAll()
        var changed = false
        for i in entries.indices where entries[i].linkedReportID == reportID {
            entries[i].linkedReportID = nil
            changed = true
        }
        if changed { persist(entries) }
    }

    /// Formatted block of recently-logged symptoms for injection
    /// into chat prompts — the symptom-log equivalent of
    /// `UserProfile.promptContextBullets`. Defaults to the last 14
    /// days (the window that's clinically relevant for "what's been
    /// going on lately" without dragging in stale entries) and caps
    /// the count so a prolific logger can't blow the 4096-token
    /// context window. Returns an empty string when there's nothing
    /// to add, so callers can drop the whole section cleanly rather
    /// than render an empty header.
    ///
    /// Designed to be used SILENTLY by the model as background
    /// context — same contract as the profile bullets. The caller's
    /// prompt wording tells the model not to restate these as
    /// findings.
    static func promptContextBlock(withinDays days: Int = 14, maxEntries: Int = 12) -> String {
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -days,
            to: Date()
        ) ?? .distantPast
        let recent = loadAll()
            .filter { $0.timestamp >= cutoff }
            .prefix(maxEntries)
        guard !recent.isEmpty else { return "" }

        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        let lines = recent.map { entry -> String in
            let date = formatter.string(from: entry.timestamp)
            let tags = entry.tags.isEmpty ? "" : " [\(entry.tags.joined(separator: ", "))]"
            return "- \(date): \(entry.text) (\(entry.intensity.label.lowercased()))\(tags)"
        }
        return lines.joined(separator: "\n        ")
    }

    /// Tags the user has used before, most-recent-use first.
    /// Surfaced as suggestion chips in the quick-add sheet so they
    /// can re-tap "headache" with one tap instead of retyping.
    static func recentTags(limit: Int = 8) -> [String] {
        var seen: [String: Date] = [:]
        for entry in loadAll() {
            for tag in entry.tags {
                if seen[tag] == nil || (seen[tag] ?? .distantPast) < entry.timestamp {
                    seen[tag] = entry.timestamp
                }
            }
        }
        return seen
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map(\.key)
    }

    private static func persist(_ entries: [SymptomEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
