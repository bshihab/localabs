import Foundation

/// Lab markers the user has explicitly chosen to follow ("Add to Health
/// Trend" from a scan's highlight, #31). All lab values already appear
/// in cross-report trends (#28) automatically; tracking *pins* the ones
/// the user cares about so they can be featured in the Trends tab.
///
/// Stored as a normalized-name set in one UserDefaults key — same
/// lightweight pattern as the rest of the app. Names are normalized
/// with `LabValue.normalizeKey` so "LDL Cholesterol" and "ldl
/// cholesterol" are the same marker.
enum TrackedMarkers {
    private static let storageKey = "localabs_tracked_markers"

    static func all() -> Set<String> {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let set = try? JSONDecoder().decode(Set<String>.self, from: data)
        else { return [] }
        return set
    }

    static func isTracked(_ name: String) -> Bool {
        all().contains(LabValue.normalizeKey(name))
    }

    static func add(_ name: String) {
        var set = all()
        set.insert(LabValue.normalizeKey(name))
        persist(set)
    }

    static func remove(_ name: String) {
        var set = all()
        set.remove(LabValue.normalizeKey(name))
        persist(set)
    }

    private static func persist(_ set: Set<String>) {
        guard let data = try? JSONEncoder().encode(set) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    static func resetAll() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}

/// Lab markers the user has chosen to HIDE from their Health Trends —
/// "I don't want to keep track of this" — without deleting the report
/// the value came from. `LabTrendService.trends` filters these out, so
/// they vanish from the Trends tab, the dashboard "what changed" card,
/// and the AI's trend summary, while the underlying report stays intact
/// (so un-hiding restores them). Hiding also cancels the marker's
/// recheck reminder.
enum HiddenMarkers {
    private static let storageKey = "localabs_hidden_markers"

    static func all() -> Set<String> {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let set = try? JSONDecoder().decode(Set<String>.self, from: data)
        else { return [] }
        return set
    }

    static func isHidden(_ name: String) -> Bool {
        all().contains(LabValue.normalizeKey(name))
    }

    static func hide(_ name: String) {
        var set = all()
        set.insert(LabValue.normalizeKey(name))
        persist(set)
    }

    static func unhide(_ name: String) {
        var set = all()
        set.remove(LabValue.normalizeKey(name))
        persist(set)
    }

    private static func persist(_ set: Set<String>) {
        guard let data = try? JSONEncoder().encode(set) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    static func resetAll() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}
