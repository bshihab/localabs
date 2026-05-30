import Foundation

/// A single lab measurement extracted from a report — the structured
/// counterpart to the freeform text in `StructuredReport`. Stored on
/// the report so cross-report comparison (#28) and on-scan
/// highlighting (#31) can work with real numbers instead of re-parsing
/// prose every time.
///
/// All clinical metadata comes from the on-device medical model, not a
/// hardcoded table: `referenceRange` is the report's printed range when
/// present, otherwise the model's standard adult range; `concernDirection`
/// is the model's judgment of which way is clinically worse. `rawName`
/// preserves what the report actually said, and is used (normalized) as
/// the cross-report join key.
struct LabValue: Codable, Hashable, Identifiable {
    var id: UUID
    /// Display name. Kept equal to `rawName` now that there's no
    /// hardcoded canonical catalog; trends join on the normalized name.
    var canonicalName: String
    /// The marker name exactly as written in the report.
    var rawName: String
    var value: Double
    var unit: String
    /// Reference range — the report's printed range ("70–100", "<100")
    /// when present, otherwise a standard adult range supplied by the
    /// model. Optional so values saved before this existed still decode.
    var referenceRange: String?
    /// Which direction is clinically concerning, per the model. Optional:
    /// nil when unknown (e.g. a value caught only by the deterministic
    /// parser, which makes no clinical judgment) → the trend shows the
    /// trajectory without a good/bad verdict.
    var concernDirection: ConcernDirection?

    init(
        id: UUID = UUID(),
        canonicalName: String,
        rawName: String,
        value: Double,
        unit: String,
        referenceRange: String? = nil,
        concernDirection: ConcernDirection? = nil
    ) {
        self.id = id
        self.canonicalName = canonicalName
        self.rawName = rawName
        self.value = value
        self.unit = unit
        self.referenceRange = referenceRange
        self.concernDirection = concernDirection
    }
}

extension LabValue {
    /// Parse a reference-range string into numeric bounds. Handles
    /// two-sided ("70-100", "3.5–5.0", "70 to 100"), one-sided
    /// ("<100", "≤100", ">40", "≥40"), and returns (nil, nil) when
    /// unparseable. Lab values are non-negative, so the dash is safe
    /// to treat as a separator.
    static func parseRange(_ raw: String?) -> (lower: Double?, upper: Double?) {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return (nil, nil)
        }
        let s = raw.lowercased()
        if let f = s.first, "<≤".contains(f) {
            return (nil, firstDouble(s.dropFirst()))
        }
        if let f = s.first, ">≥".contains(f) {
            return (firstDouble(s.dropFirst()), nil)
        }
        for sep in ["–", "—", " to ", "-"] {
            if let r = s.range(of: sep) {
                let lo = firstDouble(s[..<r.lowerBound])
                let hi = firstDouble(s[r.upperBound...])
                if lo != nil || hi != nil { return (lo, hi) }
            }
        }
        return (nil, nil)
    }

    /// First run of digits (optional single decimal) in a substring.
    private static func firstDouble<S: StringProtocol>(_ s: S) -> Double? {
        var num = ""
        var dot = false
        for ch in s {
            if ch.isNumber { num.append(ch) }
            else if ch == "." && !dot { num.append(ch); dot = true }
            else if !num.isEmpty { break }
        }
        return Double(num)
    }

    /// Normalized cross-report join key: lowercased, whitespace-
    /// collapsed name. Two reports that print the same test name join;
    /// no hardcoded synonym table.
    var joinKey: String { LabValue.normalizeKey(canonicalName) }

    static func normalizeKey(_ name: String) -> String {
        name
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// Which direction of movement is clinically concerning for a marker.
/// Supplied by the medical model per reading — NOT hardcoded per
/// disease.
enum ConcernDirection: String, Codable {
    case higherWorse   // higher value is worse
    case lowerWorse    // lower value is worse
    case midOptimal    // both extremes are concerning

    /// Parse the model's single-token direction field ("HIGH"/"LOW"/
    /// "MID") into a direction. nil for anything unrecognized.
    static func from(token: String) -> ConcernDirection? {
        switch token.uppercased().trimmingCharacters(in: .whitespaces) {
        case "HIGH", "HIGHER", "H": return .higherWorse
        case "LOW", "LOWER", "L":   return .lowerWorse
        case "MID", "BOTH", "M":    return .midOptimal
        default:                    return nil
        }
    }
}
