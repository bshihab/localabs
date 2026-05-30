import Foundation

/// One marker's trajectory across reports — the unit the cross-report
/// comparison feature (#28) works in. Built by `LabTrendService` from
/// the structured `labValues` on each `StructuredReport`.
struct LabTrend: Identifiable {
    var id: String { canonicalName }
    let canonicalName: String
    let unit: String
    let concern: ConcernDirection
    /// Chronological points (oldest → newest), one per report that
    /// measured this marker.
    let points: [Point]

    struct Point: Identifiable {
        var id: UUID { reportID }
        let reportID: UUID
        let date: Date
        let value: Double
    }

    /// How the latest reading compares to the one before it.
    enum Change {
        case improved
        case worsened
        case stable
        case changed   // moved, but direction-of-concern is ambiguous (midOptimal)
    }

    var latest: Point? { points.last }
    var previous: Point? { points.count >= 2 ? points[points.count - 2] : nil }

    /// Signed change from the previous reading to the latest.
    var delta: Double? {
        guard let latest, let previous else { return nil }
        return latest.value - previous.value
    }

    /// Classification of the marker's movement. Uses the OVERALL
    /// change (first reading → latest) rather than just the last step,
    /// so the chip matches the visible trajectory and the worsening-
    /// streak warning. Previously this compared only the last two
    /// points, which could read "Stable" for a marker that had clearly
    /// declined across all readings (e.g. eGFR 92→88→84, where the
    /// final 88→84 step alone fell inside the tolerance).
    var change: Change? {
        guard let first = points.first, let latest, points.count >= 2 else { return nil }
        let overall = latest.value - first.value
        let tolerance = abs(latest.value) * marker.stableTolerance
        return concern.classify(delta: overall, tolerance: tolerance)
    }

    /// True when the marker has moved in the concerning direction on
    /// each of the last `n` consecutive readings (a sustained bad
    /// trend, not a single blip). Requires at least `n`+1 points.
    func isWorseningStreak(minSteps n: Int = 2) -> Bool {
        guard concern != .midOptimal, points.count >= n + 1 else { return false }
        let recent = points.suffix(n + 1)
        let deltas = zip(recent, recent.dropFirst()).map { $1.value - $0.value }
        switch concern {
        case .higherWorse: return deltas.allSatisfy { $0 > 0 }
        case .lowerWorse:  return deltas.allSatisfy { $0 < 0 }
        case .midOptimal:  return false
        }
    }

    /// The catalog marker backing this trend (for tolerance/concern).
    private var marker: LabMarker {
        LabMarkerCatalog.markers.first { $0.canonicalName == canonicalName }
            ?? LabMarker(canonicalName: canonicalName, aliases: [], concern: concern, stableTolerance: 0.05)
    }
}

/// Builds cross-report lab trends from saved report history. Pure
/// computation over already-extracted `labValues` — no LLM, no network.
@MainActor
enum LabTrendService {

    /// All markers measured in 2+ reports, as trends. Tracks EVERY
    /// marker — not just catalog ones. A catalog match supplies the
    /// canonical name (so "LDL" / "LDL Cholesterol" unify) and the
    /// concern direction (for worsening warnings); a marker outside
    /// the catalog still trends, joined by its own name, with a
    /// neutral direction (we don't presume which way is "bad"). Markers
    /// seen only once are omitted. Sorted so worsening trends surface
    /// first.
    static func trends(from history: [StructuredReport]) -> [LabTrend] {
        // Oldest → newest BY REPORT DATE (the date printed on the
        // report), not scan time — so scanning an old report after a
        // newer one still orders the progression correctly.
        let ordered = history.sorted { $0.effectiveDate < $1.effectiveDate }

        // join-key (lowercased canonical/raw name) → accumulator.
        var byMarker: [String: (display: String, unit: String, concern: ConcernDirection, points: [LabTrend.Point])] = [:]

        for report in ordered {
            guard let values = report.labValues else { continue }
            for value in values {
                let resolved = resolve(value)
                let key = resolved.name.lowercased()
                let point = LabTrend.Point(reportID: report.id, date: report.effectiveDate, value: value.value)
                if var existing = byMarker[key] {
                    existing.points.append(point)
                    // Prefer a non-empty unit if we had none yet.
                    if existing.unit.isEmpty && !value.unit.isEmpty { existing.unit = value.unit }
                    byMarker[key] = existing
                } else {
                    byMarker[key] = (resolved.name, value.unit, resolved.concern, [point])
                }
            }
        }

        let trends = byMarker.values
            .filter { $0.points.count >= 2 }
            .map { data in
                LabTrend(
                    canonicalName: data.display,
                    unit: data.unit,
                    concern: data.concern,
                    points: data.points.sorted { $0.date < $1.date }
                )
            }

        return trends.sorted { a, b in
            let aw = a.isWorseningStreak() || a.change == .worsened
            let bw = b.isWorseningStreak() || b.change == .worsened
            if aw != bw { return aw }  // worsening first
            return a.canonicalName < b.canonicalName
        }
    }

    /// Resolve a lab value to a display name + concern direction. A
    /// catalog match gives the canonical name + real concern; anything
    /// else keeps its stored canonical/raw name and a neutral concern.
    private static func resolve(_ value: LabValue) -> (name: String, concern: ConcernDirection) {
        if let marker = LabMarkerCatalog.match(rawName: value.rawName)
            ?? LabMarkerCatalog.markers.first(where: { $0.canonicalName == value.canonicalName }) {
            return (marker.canonicalName, marker.concern)
        }
        return (value.canonicalName, .midOptimal)
    }

    /// Compare a specific (usually just-scanned) report against the
    /// rest of history: for every marker in `report` that also appears
    /// in an earlier report, the resulting trend. Used for the
    /// Dashboard "what changed since last time" banner.
    static func comparison(for report: StructuredReport, in history: [StructuredReport]) -> [LabTrend] {
        guard let values = report.labValues, !values.isEmpty else { return [] }
        // Keys for every marker in this report (catalog or not).
        let markersInReport = Set(values.map { resolve($0).name.lowercased() })
        guard !markersInReport.isEmpty else { return [] }
        return trends(from: history).filter { markersInReport.contains($0.canonicalName.lowercased()) }
    }

    /// Markers from this report that are on a sustained worsening
    /// streak — the ones worth a proactive warning on a new scan.
    static func worseningTrends(for report: StructuredReport, in history: [StructuredReport]) -> [LabTrend] {
        comparison(for: report, in: history).filter { $0.isWorseningStreak() }
    }
}
