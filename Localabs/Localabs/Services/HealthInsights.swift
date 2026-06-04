import Foundation
import SwiftUI

/// Clinical-context layer for HealthKit metrics — converts a raw
/// average into a *Status* (Good / Borderline / Concerning) plus a
/// short, honest explanation written for a non-clinician.
///
/// Cutoffs are now demographics-aware: for the metrics where the
/// reference band genuinely shifts with age or biological sex (HRV,
/// VO₂ max, walking speed, sleep, resting HR), the interpret closures
/// take both as optional inputs and apply bracketed thresholds drawn
/// from peer-reviewed sources:
///   - **HRV**: Umetani et al. (1998); age-stratified 24-h SDNN norms.
///   - **VO₂ max**: ACSM's Guidelines for Exercise Testing and
///     Prescription, age × sex percentile table.
///   - **Walking speed**: Studenski et al. (2011); gait speed and
///     survival, healthy-adult thresholds with elderly adjustment.
///   - **Sleep**: Hirshkowitz et al. (2015), National Sleep
///     Foundation duration recommendations by age.
///   - **Resting HR**: Mayo Clinic / AHA adult norms, with a small
///     elderly-floor adjustment.
/// The other metrics (BP, BMI, SpO₂, respiratory rate, body temp,
/// steps, blood glucose, walking asymmetry, double-support) use a
/// single adult population norm because the major clinical guidelines
/// (AHA/ACC, WHO, ADA) do not stratify these by age in the user-
/// facing wellness range. The interpret closures still accept the
/// demographic params for a consistent call signature.
///
/// Important framing: these are *population norms*, NOT personalized
/// diagnoses. The card UI shows them as visual cues; the detail
/// sheet spells the caveat out explicitly. We do not claim FDA
/// clearance.
enum HealthInsights {

    enum Status {
        case good
        case borderline
        case concerning
        case unknown

        var color: Color {
            switch self {
            case .good:        return .green
            case .borderline:  return .orange
            case .concerning:  return .red
            case .unknown:     return .secondary
            }
        }

        var label: String {
            switch self {
            case .good:        return "Typical"
            case .borderline:  return "Borderline"
            case .concerning:  return "Outside typical"
            case .unknown:     return "—"
            }
        }
    }

    /// Three-way bucketing of biological sex used by the metric
    /// interpreters. The `.other` bucket falls back to the male
    /// reference bands for VO₂ max (where sex matters most) since
    /// those are the more conservative thresholds — flagging fewer
    /// false-positives is the safer default when sex is unknown.
    enum BiologicalSex: Sendable, Equatable {
        case male
        case female
        case other

        /// Parses the free-form string Profile stores ("Male" /
        /// "Female" / "Other" / "") into the bucketed form. Returns
        /// nil for blank input so callers know demographics are
        /// missing and can suppress the status label entirely.
        static func from(_ raw: String) -> BiologicalSex? {
            switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
            case "male", "m":                                  return .male
            case "female", "f":                                return .female
            case "":                                           return nil
            default:                                           return .other
            }
        }
    }

    /// Whether a metric should render as bars (cumulative totals like
    /// step count, where each day is its own discrete column) vs. a
    /// smooth line+area (continuous measurements like resting HR or
    /// HRV, where the eye reads change over time). Matches the way
    /// Apple Health renders the same metric families.
    static func isCumulativeMetric(_ label: String) -> Bool {
        [
            "Steps",
            "Walking + running",
            "Flights climbed",
            "Exercise minutes",
            "Active energy",
            "Caffeine"
        ].contains(label)
    }

    /// Plain-language descriptions of the three status labels, used by
    /// the metric detail sheet so users understand what "Typical /
    /// Borderline / Outside typical" actually means before they read
    /// their own number.
    static func statusLegend() -> [(label: String, color: Color, description: String)] {
        [
            ("Typical", .green, "Falls inside the population norm range for your age and biological sex."),
            ("Borderline", .orange, "Just outside the typical range for your age/sex — worth keeping an eye on, but rarely urgent on its own."),
            ("Outside typical", .red, "Clearly outside age/sex-adjusted norms. Trend matters more than a single reading — discuss persistent values with your doctor.")
        ]
    }

    /// Map from a metric's display label (the one passed to
    /// `section(...)` in TrendsView) to its interpretation logic.
    /// Returning nil means "no clinical context known for this metric"
    /// — the card just shows the number and chart, no status bar.
    static func clinicalContext(for metricLabel: String) -> ClinicalContext? {
        switch metricLabel {
        case "Resting HR":          return restingHR
        case "HRV":                 return hrv
        case "VO₂ max":             return vo2Max
        case "Walking HR":          return walkingHR
        case "Sleep":               return sleep
        case "Steps":               return steps
        case "Walking + running":   return walkingDistance
        case "Walking speed":       return walkingSpeed
        case "Asymmetry":           return walkingAsymmetry
        case "Double support":      return doubleSupport
        case "Six-min walk":        return sixMinWalk
        case "Systolic BP":         return systolicBP
        case "Diastolic BP":        return diastolicBP
        case "Oxygen":              return spo2
        case "Respiratory":         return respRate
        case "Body temp":           return bodyTemp
        case "Weight":              return nil  // depends on height; no universal status
        case "BMI":                 return bmi
        case "Blood glucose":       return bloodGlucose
        default:                    return nil
        }
    }

    /// Bundles the status logic with a human-readable explanation
    /// the detail sheet renders. Both `typicalRangeLabel` and
    /// `interpret` take age + biological sex so metrics with
    /// age-dependent reference bands can return different
    /// thresholds per user. `Sendable` for Swift 6 strict
    /// concurrency — every closure here is pure.
    struct ClinicalContext: Sendable {
        /// Display string for the "Typical Range" badge — personalized
        /// for age/sex on metrics where the cutoff shifts (HRV, VO₂ max,
        /// walking speed, sleep, resting HR). Other metrics return a
        /// fixed adult range regardless of inputs.
        let typicalRangeLabel: @Sendable (_ age: Int?, _ sex: BiologicalSex?) -> String
        let explanation: String
        let interpret: @Sendable (_ value: Double, _ age: Int?, _ sex: BiologicalSex?) -> Status
    }

    // MARK: - Cardio + recovery

    private static let restingHR = ClinicalContext(
        typicalRangeLabel: { age, _ in
            // Resting HR baseline drifts slightly downward with age
            // (older adults often run lower from lifelong vagal
            // tone), but the typical adult band 60–80 covers most
            // ages well. Just call out the elderly floor.
            guard let age else { return "60–80 bpm" }
            return age >= 65 ? "55–80 bpm" : "60–80 bpm"
        },
        explanation: "Resting heart rate is how often your heart beats per minute while you're calm. 60–80 bpm is typical for adults; trained athletes often sit below 60, and persistently above 90 may indicate cardiovascular stress or deconditioning.",
        interpret: { value, age, _ in
            let lowBorder: Double = (age ?? 35) >= 65 ? 50 : 55
            if value < 50 || value > 100 { return .concerning }
            if value > 85 || value < lowBorder { return .borderline }
            return .good
        }
    )

    /// HRV reference bands by age. Numbers approximate 24-hour SDNN
    /// percentiles from Umetani et al. (1998) — the seminal age-
    /// stratified HRV norms — adjusted slightly down because Apple's
    /// Watch-derived HRV is a shorter window and runs lower than
    /// 24-hour Holter readings.
    private static func hrvBand(for age: Int?) -> (typical: ClosedRange<Double>, borderlineFloor: Double, concerningFloor: Double, label: String) {
        switch age ?? 35 {
        case ..<30:    return (50...80, 35, 25, "50–80 ms")
        case 30..<40:  return (40...65, 30, 20, "40–65 ms")
        case 40..<50:  return (30...55, 25, 15, "30–55 ms")
        case 50..<60:  return (25...45, 20, 13, "25–45 ms")
        case 60..<70:  return (20...35, 17, 11, "20–35 ms")
        default:       return (15...30, 13, 10, "15–30 ms")
        }
    }

    private static let hrv = ClinicalContext(
        typicalRangeLabel: { age, _ in hrvBand(for: age).label },
        explanation: "Heart rate variability (HRV) is the variation in time between heartbeats. Higher values generally indicate better recovery and lower stress, though HRV declines significantly with age — what's typical at 25 isn't typical at 65. Sudden drops compared to your own baseline matter more than the absolute number.",
        interpret: { value, age, _ in
            let band = hrvBand(for: age)
            if value < band.concerningFloor { return .concerning }
            if value < band.borderlineFloor { return .borderline }
            return .good
        }
    )

    /// VO₂ max percentile cutoffs from ACSM's Guidelines, table 4.10
    /// (age × sex). We return `good` = the "fair-to-good" threshold
    /// and `concerning` = the "poor" floor; anything between is
    /// borderline. The `.other` sex bucket falls back to male
    /// thresholds (the higher / more conservative band).
    private static func vo2MaxCutoffs(age: Int?, sex: BiologicalSex?) -> (good: Double, concerning: Double, label: String) {
        let bracket: Int
        switch age ?? 35 {
        case ..<30:    bracket = 0
        case 30..<40:  bracket = 1
        case 40..<50:  bracket = 2
        case 50..<60:  bracket = 3
        case 60..<70:  bracket = 4
        default:       bracket = 5
        }

        // (good-floor, concerning-floor) per age bracket
        let male:   [(Double, Double)] = [(44, 38), (42, 34), (38, 30), (33, 25), (30, 22), (26, 18)]
        let female: [(Double, Double)] = [(36, 30), (32, 26), (29, 22), (26, 20), (23, 17), (21, 16)]

        let table = (sex == .female) ? female : male
        let entry = table[bracket]
        return (entry.0, entry.1, "\(Int(entry.0))+ ml/kg/min")
    }

    private static let vo2Max = ClinicalContext(
        typicalRangeLabel: { age, sex in vo2MaxCutoffs(age: age, sex: sex).label },
        explanation: "VO₂ max estimates how efficiently your body uses oxygen during peak exercise. Higher is generally better for cardiovascular health and longevity. Thresholds shift substantially with age and biological sex — a 'good' VO₂ max for a 30-year-old man is notably higher than for a 60-year-old woman. Apple's Watch-derived value can vary by 5–15% from a lab measurement.",
        interpret: { value, age, sex in
            let cutoffs = vo2MaxCutoffs(age: age, sex: sex)
            if value < cutoffs.concerning { return .concerning }
            if value < cutoffs.good       { return .borderline }
            return .good
        }
    )

    private static let walkingHR = ClinicalContext(
        typicalRangeLabel: { _, _ in "90–120 bpm" },
        explanation: "Walking heart rate is your average heart rate during walking sessions over the period. Significant elevation from your own baseline (rather than the absolute number) is what's worth noting — it can reflect fitness, dehydration, illness, or stress.",
        interpret: { value, _, _ in
            if value > 140 { return .borderline }
            return .good
        }
    )

    // MARK: - Sleep

    /// Sleep duration recommendations from the National Sleep
    /// Foundation (Hirshkowitz et al., 2015). Young adults need
    /// slightly more, older adults slightly less; chronic short
    /// sleep is concerning regardless of age.
    private static func sleepBand(for age: Int?) -> (typical: ClosedRange<Double>, borderlineFloor: Double, concerningFloor: Double, label: String) {
        switch age ?? 35 {
        case ..<26:    return (7...9,    6.5,  5.5, "7–9 hours")
        case 65...:    return (7...8,    6.0,  5.0, "7–8 hours")
        default:       return (7...9,    6.5,  5.0, "7–9 hours")
        }
    }

    private static let sleep = ClinicalContext(
        typicalRangeLabel: { age, _ in sleepBand(for: age).label },
        explanation: "Adults typically need 7–9 hours of sleep per night for optimal recovery — young adults often need closer to 9, older adults 7–8 is healthy. Consistent short sleep (<6h) or very long sleep (>10h) over weeks is associated with elevated cardiovascular and metabolic risk. Sleep regularity matters as much as total duration.",
        interpret: { value, age, _ in
            let band = sleepBand(for: age)
            if value < band.concerningFloor || value > 11 { return .concerning }
            if value < band.borderlineFloor || value > 9.5 { return .borderline }
            return .good
        }
    )

    // MARK: - Activity

    private static let steps = ClinicalContext(
        typicalRangeLabel: { _, _ in "7,000+ daily" },
        explanation: "Daily step counts above 7,000 are associated with lower all-cause mortality in large cohort studies. Most additional benefit plateaus around 10,000. Below 5,000 is often classified as sedentary.",
        interpret: { value, _, _ in
            if value < 3000 { return .concerning }
            if value < 5000 { return .borderline }
            return .good
        }
    )

    private static let walkingDistance = ClinicalContext(
        typicalRangeLabel: { _, _ in "2+ mi daily" },
        explanation: "Walking distance complements step count by capturing stride length — useful for tracking mobility recovery after injury, surgery, or illness. Sudden drops can mirror reduced daily activity.",
        interpret: { value, _, _ in
            if value < 0.5 { return .borderline }
            return .good
        }
    )

    /// Walking-speed thresholds drawn from Studenski et al. (2011),
    /// which found that gait speed correlates with healthspan,
    /// especially in adults over 65. Below 1.0 m/s (~2.2 mph) in
    /// older adults is associated with elevated mortality; under
    /// 0.6 m/s (~1.3 mph) is clinically concerning.
    private static func walkingSpeedBand(for age: Int?) -> (good: Double, borderlineFloor: Double, concerningFloor: Double, label: String) {
        switch age ?? 35 {
        case 65...:    return (2.5, 2.0, 1.5, "2.5+ mph")
        case 50..<65:  return (2.8, 2.2, 1.8, "2.8+ mph")
        default:       return (3.0, 2.5, 2.0, "3.0+ mph")
        }
    }

    private static let walkingSpeed = ClinicalContext(
        typicalRangeLabel: { age, _ in walkingSpeedBand(for: age).label },
        explanation: "Average walking speed correlates with cardiovascular fitness and is a strong predictor of healthspan, particularly in adults over 50. Typical pace varies with age — younger adults walk faster, and the clinically meaningful 'slow' threshold shifts down for older adults. Apple measures this passively from your iPhone's accelerometer.",
        interpret: { value, age, _ in
            let band = walkingSpeedBand(for: age)
            if value < band.concerningFloor { return .concerning }
            if value < band.borderlineFloor { return .borderline }
            return .good
        }
    )

    private static let walkingAsymmetry = ClinicalContext(
        typicalRangeLabel: { _, _ in "<5%" },
        explanation: "Walking asymmetry measures how much your steps with one leg differ in timing from the other. Apple measures this passively from your iPhone. Sustained values above 5% can reflect an injury, healing pattern, or strength imbalance worth discussing with a clinician.",
        interpret: { value, _, _ in
            if value > 10 { return .concerning }
            if value > 5  { return .borderline }
            return .good
        }
    )

    private static let doubleSupport = ClinicalContext(
        typicalRangeLabel: { _, _ in "20–30%" },
        explanation: "Double support percentage is how much of your walking cycle has both feet on the ground. Higher numbers indicate slower, more cautious walking — common with fatigue, injury, or aging. Consistently elevated values can be an early signal of mobility changes.",
        interpret: { value, _, _ in
            if value > 40 { return .borderline }
            return .good
        }
    )

    private static let sixMinWalk = ClinicalContext(
        typicalRangeLabel: { _, _ in "400+ m (predicted)" },
        explanation: "The Six-Minute Walk Distance is iOS's prediction of how far you'd walk in 6 minutes, derived from your iPhone's accelerometer. The clinical 6MWT (administered by a clinician) is used to track cardiorespiratory fitness in heart and lung patients. Apple's prediction is best read as a *trend*, not a clinical result.",
        interpret: { value, _, _ in
            if value < 300 { return .borderline }
            return .good
        }
    )

    // MARK: - Vitals
    // ACC/AHA blood pressure cutoffs no longer stratify by age (the
    // older "elderly target" was retired in the 2017 guidelines), so
    // these stay uniform across demographics. SpO₂, respiratory rate,
    // body temp, BMI, and blood glucose also use single adult norms
    // — none of the major guidelines (WHO, ADA, ATS) age-stratify
    // these in the wellness range.

    private static let systolicBP = ClinicalContext(
        typicalRangeLabel: { _, _ in "<120 mmHg" },
        explanation: "Systolic blood pressure (the top number) measures arterial pressure when your heart beats. ACC/AHA classifies <120 as normal, 120–129 elevated, 130–139 stage 1 hypertension, 140+ stage 2. Single readings vary; the period average is more meaningful than any one measurement.",
        interpret: { value, _, _ in
            if value >= 140 { return .concerning }
            if value >= 120 { return .borderline }
            return .good
        }
    )

    private static let diastolicBP = ClinicalContext(
        typicalRangeLabel: { _, _ in "<80 mmHg" },
        explanation: "Diastolic blood pressure (the bottom number) is arterial pressure between beats. <80 is considered normal, 80–89 elevated, 90+ stage 2 hypertension. Sustained elevation is a major modifiable cardiovascular risk factor.",
        interpret: { value, _, _ in
            if value >= 90 { return .concerning }
            if value >= 80 { return .borderline }
            return .good
        }
    )

    private static let spo2 = ClinicalContext(
        typicalRangeLabel: { _, _ in "≥95%" },
        explanation: "Blood oxygen saturation (SpO₂) measures how much oxygen your red blood cells are carrying. ≥95% is typical at sea level; 91–94% may be concerning depending on context; persistent readings below 91% warrant clinical attention.",
        interpret: { value, _, _ in
            if value < 91 { return .concerning }
            if value < 95 { return .borderline }
            return .good
        }
    )

    private static let respRate = ClinicalContext(
        typicalRangeLabel: { _, _ in "12–20 br/min" },
        explanation: "Resting respiratory rate is breaths per minute when relaxed. Typical range is 12–20 for adults. Persistently elevated rates can indicate respiratory or cardiovascular stress, fever, or anxiety.",
        interpret: { value, _, _ in
            if value < 10 || value > 24 { return .concerning }
            if value > 20 { return .borderline }
            return .good
        }
    )

    private static let bodyTemp = ClinicalContext(
        typicalRangeLabel: { _, _ in "97–99 °F" },
        explanation: "Normal body temperature varies through the day (lower in the morning, higher in late afternoon) and across individuals. Persistent readings above 100.4°F qualify as fever.",
        interpret: { value, _, _ in
            if value >= 100.4 || value <= 95 { return .concerning }
            if value >= 99.5 { return .borderline }
            return .good
        }
    )

    // MARK: - Body

    private static let bmi = ClinicalContext(
        typicalRangeLabel: { _, _ in "18.5–24.9" },
        explanation: "Body mass index (BMI) is weight divided by height squared. It's an imperfect proxy for body composition — athletes can have a high BMI from muscle mass — but at the population level, 18.5–24.9 is the WHO-defined healthy range, 25–29.9 overweight, 30+ obese.",
        interpret: { value, _, _ in
            if value < 18.5 || value >= 30 { return .borderline }
            if value >= 25 { return .borderline }
            return .good
        }
    )

    // MARK: - Logged

    private static let bloodGlucose = ClinicalContext(
        typicalRangeLabel: { _, _ in "70–99 mg/dL (fasting)" },
        explanation: "Fasting blood glucose 70–99 mg/dL is normal, 100–125 indicates pre-diabetes, 126+ on two separate days meets the diabetes threshold. CGM data fluctuates throughout the day; the period average matters more than any single reading.",
        interpret: { value, _, _ in
            if value >= 126 { return .concerning }
            if value >= 100 { return .borderline }
            return .good
        }
    )

}
