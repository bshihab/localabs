import Foundation

/// A single lab measurement extracted from a report — the structured
/// counterpart to the freeform text in `StructuredReport`. Stored on
/// the report so cross-report comparison (#28) and on-scan
/// highlighting (#31) can work with real numbers instead of re-parsing
/// prose every time.
///
/// `canonicalName` is the join key across reports: "HbA1c", "A1c", and
/// "Hemoglobin A1c" all normalize to the same canonical marker so a
/// trend can be tracked even when labs format the name differently.
/// `rawName` preserves what the report actually said.
struct LabValue: Codable, Hashable, Identifiable {
    var id: UUID
    /// Canonical marker name from `LabMarkerCatalog`, or the raw name
    /// when the value didn't match a known marker.
    var canonicalName: String
    /// The marker name exactly as written in the report.
    var rawName: String
    var value: Double
    var unit: String
    /// Reference range as written ("70–100", "<100", "3.5-5.0"), if any.
    var referenceRange: String?

    init(
        id: UUID = UUID(),
        canonicalName: String,
        rawName: String,
        value: Double,
        unit: String,
        referenceRange: String? = nil
    ) {
        self.id = id
        self.canonicalName = canonicalName
        self.rawName = rawName
        self.value = value
        self.unit = unit
        self.referenceRange = referenceRange
    }
}

/// Which direction of movement is clinically concerning for a marker —
/// used to classify a cross-report change as improving or worsening.
enum ConcernDirection: String, Codable {
    case higherWorse   // LDL, A1c, glucose, BP, triglycerides, liver enzymes…
    case lowerWorse    // HDL, eGFR, vitamin D…
    case midOptimal    // TSH, sodium, potassium — both extremes are bad

    /// Classify a change (new − prior) for this marker.
    func classify(delta: Double, tolerance: Double) -> LabTrend.Change {
        if abs(delta) <= tolerance { return .stable }
        switch self {
        case .higherWorse: return delta > 0 ? .worsened : .improved
        case .lowerWorse:  return delta > 0 ? .improved : .worsened
        case .midOptimal:  return .changed  // direction alone isn't enough
        }
    }
}

/// A known, clinically meaningful lab marker. The catalog is curated
/// (chronic-disease markers) rather than "every number on the page" so
/// trends stay meaningful and low-noise.
struct LabMarker {
    let canonicalName: String
    /// Lowercased substrings matched against a report's raw lab name.
    /// Order matters only for readability; matching tries all.
    let aliases: [String]
    let concern: ConcernDirection
    /// Fraction-of-value tolerance below which a change is "stable"
    /// (e.g. 0.05 = a <5% wiggle isn't a real trend). Keeps normal
    /// lab-to-lab variation from reading as a worsening trend.
    let stableTolerance: Double
}

/// The curated set of markers Localabs tracks across reports. Matching
/// is alias-substring based and case-insensitive.
enum LabMarkerCatalog {
    static let markers: [LabMarker] = [
        // Glycemic
        LabMarker(canonicalName: "HbA1c", aliases: ["a1c", "hba1c", "hemoglobin a1c", "glycated", "glycohemoglobin"], concern: .higherWorse, stableTolerance: 0.03),
        LabMarker(canonicalName: "Fasting Glucose", aliases: ["fasting glucose", "glucose, fasting", "blood glucose", "glucose"], concern: .higherWorse, stableTolerance: 0.05),

        // Lipids
        LabMarker(canonicalName: "LDL Cholesterol", aliases: ["ldl"], concern: .higherWorse, stableTolerance: 0.05),
        LabMarker(canonicalName: "HDL Cholesterol", aliases: ["hdl"], concern: .lowerWorse, stableTolerance: 0.05),
        LabMarker(canonicalName: "Total Cholesterol", aliases: ["total cholesterol", "cholesterol, total"], concern: .higherWorse, stableTolerance: 0.05),
        LabMarker(canonicalName: "Triglycerides", aliases: ["triglyceride"], concern: .higherWorse, stableTolerance: 0.08),

        // Kidney
        LabMarker(canonicalName: "eGFR", aliases: ["egfr", "gfr"], concern: .lowerWorse, stableTolerance: 0.05),
        LabMarker(canonicalName: "Creatinine", aliases: ["creatinine"], concern: .higherWorse, stableTolerance: 0.05),

        // Thyroid
        LabMarker(canonicalName: "TSH", aliases: ["tsh", "thyroid stimulating"], concern: .midOptimal, stableTolerance: 0.10),

        // Liver
        LabMarker(canonicalName: "ALT", aliases: ["alt", "alanine"], concern: .higherWorse, stableTolerance: 0.10),
        LabMarker(canonicalName: "AST", aliases: ["ast", "aspartate"], concern: .higherWorse, stableTolerance: 0.10),

        // Blood pressure (sometimes printed on reports)
        LabMarker(canonicalName: "Systolic BP", aliases: ["systolic"], concern: .higherWorse, stableTolerance: 0.04),
        LabMarker(canonicalName: "Diastolic BP", aliases: ["diastolic"], concern: .higherWorse, stableTolerance: 0.04),

        // Vitamins / other chronic
        LabMarker(canonicalName: "Vitamin D", aliases: ["vitamin d", "25-hydroxy", "25 hydroxy"], concern: .lowerWorse, stableTolerance: 0.08),
        LabMarker(canonicalName: "Hemoglobin", aliases: ["hemoglobin", "hgb", "haemoglobin"], concern: .lowerWorse, stableTolerance: 0.05),
    ]

    /// Match a raw lab name to a canonical marker, or nil if it isn't
    /// one we track. Longer aliases are tried first so "hemoglobin a1c"
    /// maps to HbA1c rather than Hemoglobin.
    static func match(rawName: String) -> LabMarker? {
        let needle = rawName.lowercased().trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return nil }
        // Build (alias, marker) pairs sorted by alias length desc so the
        // most specific alias wins.
        let pairs = markers
            .flatMap { marker in marker.aliases.map { (alias: $0, marker: marker) } }
            .sorted { $0.alias.count > $1.alias.count }
        for pair in pairs where needle.contains(pair.alias) {
            return pair.marker
        }
        return nil
    }
}
