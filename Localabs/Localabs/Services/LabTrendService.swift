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
    /// The lab's own reference range for this marker, taken from the
    /// most recent report that printed one. Drives both the
    /// classification (range-crossing) and the shaded band on the
    /// chart. nil bounds → no range available → percentage fallback.
    let referenceLower: Double?
    let referenceUpper: Double?

    struct Point: Identifiable {
        var id: UUID { reportID }
        let reportID: UUID
        let date: Date
        let value: Double
    }

    /// How the latest reading compares to the first.
    enum Change {
        case improved
        case worsened
        case stable
        case changed   // moved, but direction-of-concern is ambiguous (midOptimal, no range)
    }

    var latest: Point? { points.last }
    var previous: Point? { points.count >= 2 ? points[points.count - 2] : nil }

    var delta: Double? {
        guard let latest, let previous else { return nil }
        return latest.value - previous.value
    }

    var hasRange: Bool { referenceLower != nil || referenceUpper != nil }

    /// How far a value sits OUTSIDE its reference range in the
    /// clinically concerning direction — 0 when in range (or out only
    /// in a harmless direction). This is the signal classification
    /// uses, so movement is judged against the lab's own normal range,
    /// not an arbitrary percentage. For higher-worse markers only
    /// being above the upper bound counts; for lower-worse, only below
    /// the lower bound; for mid-optimal, either side.
    func badness(_ value: Double) -> Double {
        switch concern {
        case .higherWorse:
            guard let upper = referenceUpper else { return 0 }
            return max(0, value - upper)
        case .lowerWorse:
            guard let lower = referenceLower else { return 0 }
            return max(0, lower - value)
        case .midOptimal:
            var b = 0.0
            if let upper = referenceUpper { b = max(b, value - upper) }
            if let lower = referenceLower { b = max(b, lower - value) }
            return b
        }
    }

    /// Classification of the marker's movement, first → latest, judged
    /// against the reference range (badness). With no range available
    /// there's no clinical basis to call a move good or bad, so it
    /// reads as a neutral "Changed" (or "Stable" if it didn't move) —
    /// no arbitrary percentage guess.
    var change: Change? {
        guard let first = points.first, let latest, points.count >= 2 else { return nil }
        guard hasRange else {
            return latest.value == first.value ? .stable : .changed
        }
        let bl = badness(latest.value)
        let bf = badness(first.value)
        let tol = max(0.0001, abs(latest.value) * 0.02)  // ignore tiny wiggle
        if abs(bl - bf) <= tol { return .stable }
        return bl > bf ? .worsened : .improved
    }

    /// A sustained worsening: badness increases on each of the last
    /// `n` steps AND the latest reading is actually out of range.
    /// Requires a reference range (no range → no worsening verdict)
    /// and at least `n`+1 points.
    func isWorseningStreak(minSteps n: Int = 2) -> Bool {
        guard hasRange, points.count >= n + 1 else { return false }
        let recent = Array(points.suffix(n + 1))
        let bs = recent.map { badness($0.value) }
        let rising = zip(bs, bs.dropFirst()).allSatisfy { $1 > $0 }
        return rising && badness(latest?.value ?? 0) > 0
    }

    /// Human-readable reference range for display, e.g. "70–100",
    /// "<100", ">40". nil when no range is known.
    var referenceRangeLabel: String? {
        switch (referenceLower, referenceUpper) {
        case let (lo?, hi?): return "\(LabTrend.fmt(lo))–\(LabTrend.fmt(hi))"
        case let (nil, hi?): return "<\(LabTrend.fmt(hi))"
        case let (lo?, nil): return ">\(LabTrend.fmt(lo))"
        default:             return nil
        }
    }

    static func fmt(_ v: Double) -> String {
        v.rounded() == v ? String(format: "%.0f", v) : String(format: "%.1f", v)
    }
}

/// Builds cross-report lab trends from saved report history. Pure
/// computation over already-extracted `labValues` — no LLM, no network.
@MainActor
enum LabTrendService {

    /// All markers measured in 2+ reports, as trends. Tracks EVERY
    /// marker, joined by normalized name. The reference range and the
    /// concern direction come from the model (per `LabValue`), not a
    /// hardcoded catalog — the most recent report's values win when
    /// they differ. A value with no model-supplied concern direction
    /// trends without a good/bad verdict. Markers seen only once are
    /// omitted. Sorted so worsening trends surface first.
    private struct DayPoint {
        let value: Double
        let scanTime: Date
        let reportID: UUID
        let date: Date
    }
    private struct MarkerAccumulator {
        var display: String
        var unit: String
        var concern: ConcernDirection
        // One entry per calendar day — collapses duplicate reports
        // (e.g. re-scanning the same report) into a single point.
        var byDay: [Date: DayPoint] = [:]
        // Reference range from the most recent report that supplied one.
        var refLower: Double?
        var refUpper: Double?
        // Newest scan time seen, so the latest report's concern /
        // range win when they differ across reports.
        var newestScan: Date = .distantPast
    }

    static func trends(from history: [StructuredReport]) -> [LabTrend] {
        // Exclude reports the user marked as someone else's (e.g. a
        // parent's labs) — mixing two people's values into one trend
        // would be misleading and unsafe. Then oldest → newest BY
        // REPORT DATE (not scan time), so an old report scanned after a
        // newer one still orders the progression correctly.
        let ordered = history
            .filter { $0.isOwnReport }
            .sorted { $0.effectiveDate < $1.effectiveDate }
        let cal = Calendar.current

        // normalized-name join key → accumulator.
        var byMarker: [String: MarkerAccumulator] = [:]

        for report in ordered {
            guard let values = report.labValues else { continue }
            for value in values {
                let key = value.joinKey
                let day = cal.startOfDay(for: report.effectiveDate)

                var acc = byMarker[key] ?? MarkerAccumulator(
                    display: value.canonicalName,
                    unit: value.unit,
                    concern: value.concernDirection ?? .midOptimal
                )
                if acc.unit.isEmpty && !value.unit.isEmpty { acc.unit = value.unit }
                // The most recent report's clinical metadata wins: update
                // the concern direction and range when this report is the
                // newest seen for the marker and it supplied that info.
                if report.timestamp >= acc.newestScan {
                    acc.newestScan = report.timestamp
                    if let c = value.concernDirection { acc.concern = c }
                    let (lo, hi) = LabValue.parseRange(value.referenceRange)
                    if lo != nil || hi != nil { acc.refLower = lo; acc.refUpper = hi }
                }

                // Dedupe by day: if this marker already has a reading
                // for this date (a duplicate / re-scanned report), keep
                // the one from the most-recently-scanned report rather
                // than adding a second point at the same date.
                let candidate = DayPoint(
                    value: value.value,
                    scanTime: report.timestamp,
                    reportID: report.id,
                    date: report.effectiveDate
                )
                if let existing = acc.byDay[day] {
                    if report.timestamp >= existing.scanTime { acc.byDay[day] = candidate }
                } else {
                    acc.byDay[day] = candidate
                }
                byMarker[key] = acc
            }
        }

        // A trend needs 2+ DISTINCT DATES. Re-scanning the same report
        // (one date) therefore never creates or extends a trend.
        let trends = byMarker.values
            .filter { $0.byDay.count >= 2 }
            .map { acc in
                LabTrend(
                    canonicalName: acc.display,
                    unit: acc.unit,
                    concern: acc.concern,
                    points: acc.byDay.values
                        .map { LabTrend.Point(reportID: $0.reportID, date: $0.date, value: $0.value) }
                        .sorted { $0.date < $1.date },
                    referenceLower: acc.refLower,
                    referenceUpper: acc.refUpper
                )
            }

        return trends
            // Drop markers the user hid from their trends (#31) — the
            // report still exists, the marker just stops being tracked.
            .filter { !HiddenMarkers.isHidden($0.canonicalName) }
            .sorted { a, b in
                let aw = a.isWorseningStreak() || a.change == .worsened
                let bw = b.isWorseningStreak() || b.change == .worsened
                if aw != bw { return aw }  // worsening first
                return a.canonicalName < b.canonicalName
            }
    }

    /// Compare a specific (usually just-scanned) report against the
    /// rest of history: for every marker in `report` that also appears
    /// in an earlier report, the resulting trend. Used for the
    /// Dashboard "what changed since last time" banner.
    static func comparison(for report: StructuredReport, in history: [StructuredReport]) -> [LabTrend] {
        guard let values = report.labValues, !values.isEmpty else { return [] }
        let markersInReport = Set(values.map { $0.joinKey })
        guard !markersInReport.isEmpty else { return [] }
        return trends(from: history).filter { markersInReport.contains(normalize($0.canonicalName)) }
    }

    /// Same normalization as `LabValue.joinKey`, for matching a trend's
    /// display name back to report join keys.
    private static func normalize(_ s: String) -> String {
        s.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Markers from this report that are on a sustained worsening
    /// streak — the ones worth a proactive warning on a new scan.
    static func worseningTrends(for report: StructuredReport, in history: [StructuredReport]) -> [LabTrend] {
        comparison(for: report, in: history).filter { $0.isWorseningStreak() }
    }

    /// Compact text summary of the user's lab trends for injection into
    /// chat prompts — each tracked marker's trajectory over time, so the
    /// follow-up chat can actually answer "how have my numbers been doing
    /// compared to my past reports?". Empty when there's nothing to
    /// compare. Other-person reports are already filtered out by
    /// `trends`, so this never leaks an excluded report's values.
    static func promptSummary(from history: [StructuredReport]) -> String {
        let all = trends(from: history)
        guard !all.isEmpty else { return "" }
        return all.map { t -> String in
            let nums = t.points.map { LabTrend.fmt($0.value) }.joined(separator: " → ")
            let unit = t.unit.isEmpty ? "" : " \(t.unit)"
            let range = t.referenceRangeLabel.map { " (normal \($0))" } ?? ""
            let verdict: String
            switch t.change {
            case .improved: verdict = " — improving"
            case .worsened: verdict = " — worsening"
            case .stable:   verdict = " — stable"
            default:        verdict = ""
            }
            return "- \(t.canonicalName): \(nums)\(unit)\(range)\(verdict)"
        }
        .joined(separator: "\n        ")
    }
}
