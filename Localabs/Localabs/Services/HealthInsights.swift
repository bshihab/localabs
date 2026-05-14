import Foundation
import SwiftUI

/// Clinical-context layer for HealthKit metrics — converts a raw
/// average into a *Status* (Good / Borderline / Concerning) plus a
/// short, honest explanation written for a non-clinician.
///
/// Important framing: these ranges are *population norms* from
/// peer-reviewed literature, NOT personalized diagnoses. The card UI
/// shows them as visual cues ("your number sits in the typical
/// range") and the detail sheet spells the caveat out explicitly.
/// We do not claim FDA-clearance.
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
    /// the detail sheet renders. Two strings: a one-liner for the
    /// "typical range" badge, and a paragraph of context.
    struct ClinicalContext {
        let typicalRangeLabel: String
        let explanation: String
        let interpret: (Double) -> Status
    }

    // MARK: - Cardio + recovery

    private static let restingHR = ClinicalContext(
        typicalRangeLabel: "60–80 bpm",
        explanation: "Resting heart rate measures how often your heart beats per minute while you're calm and not exercising. 60–80 bpm is typical for adults; below 60 is common in trained athletes, and persistently above 90 may indicate cardiovascular stress or deconditioning.",
        interpret: { value in
            if value < 50 || value > 100 { return .concerning }
            if value > 85 || value < 55 { return .borderline }
            return .good
        }
    )

    private static let hrv = ClinicalContext(
        typicalRangeLabel: "20–80 ms",
        explanation: "Heart rate variability (HRV) is the variation in time between heartbeats. Higher values generally indicate better recovery and lower stress, though HRV varies widely by age, fitness, and individual baseline. Sudden drops compared to your own baseline matter more than the absolute number.",
        interpret: { value in
            if value < 15 { return .concerning }
            if value < 25 { return .borderline }
            return .good
        }
    )

    private static let vo2Max = ClinicalContext(
        typicalRangeLabel: "30+ ml/kg/min (adult)",
        explanation: "VO₂ max estimates how efficiently your body uses oxygen during peak exercise. Higher is generally better for cardiovascular health and longevity. Apple's Watch-derived value can vary by 5–15% from a lab measurement, so trends matter more than the exact number.",
        interpret: { value in
            if value < 25 { return .concerning }
            if value < 35 { return .borderline }
            return .good
        }
    )

    private static let walkingHR = ClinicalContext(
        typicalRangeLabel: "90–120 bpm",
        explanation: "Walking heart rate is your average heart rate during walking sessions over the period. Significant elevation from your own baseline (rather than the absolute number) is what's worth noting — it can reflect fitness, dehydration, illness, or stress.",
        interpret: { value in
            if value > 140 { return .borderline }
            return .good
        }
    )

    // MARK: - Sleep

    private static let sleep = ClinicalContext(
        typicalRangeLabel: "7–9 hours",
        explanation: "Adults typically need 7–9 hours of sleep per night for optimal recovery. Consistent short sleep (<6h) or long sleep (>10h) over weeks is associated with elevated cardiovascular and metabolic risk. Sleep regularity matters as much as total duration.",
        interpret: { value in
            if value < 5 || value > 11 { return .concerning }
            if value < 6.5 || value > 9.5 { return .borderline }
            return .good
        }
    )

    // MARK: - Activity

    private static let steps = ClinicalContext(
        typicalRangeLabel: "7,000+ daily",
        explanation: "Daily step counts above 7,000 are associated with lower all-cause mortality in large cohort studies. Most additional benefit plateaus around 10,000. Below 5,000 is often classified as sedentary.",
        interpret: { value in
            if value < 3000 { return .concerning }
            if value < 5000 { return .borderline }
            return .good
        }
    )

    private static let walkingDistance = ClinicalContext(
        typicalRangeLabel: "2+ mi daily",
        explanation: "Walking distance complements step count by capturing stride length — useful for tracking mobility recovery after injury, surgery, or illness. Sudden drops can mirror reduced daily activity.",
        interpret: { value in
            if value < 0.5 { return .borderline }
            return .good
        }
    )

    private static let walkingSpeed = ClinicalContext(
        typicalRangeLabel: "2.5+ mph",
        explanation: "Average walking speed correlates with cardiovascular fitness and is a predictor of healthspan in adults over 50. Speeds below 2.0 mph in healthy adults often warrant attention.",
        interpret: { value in
            if value < 2.0 { return .borderline }
            return .good
        }
    )

    private static let walkingAsymmetry = ClinicalContext(
        typicalRangeLabel: "<5%",
        explanation: "Walking asymmetry measures how much your steps with one leg differ in timing from the other. Apple measures this passively from your iPhone. Sustained values above 5% can reflect an injury, healing pattern, or strength imbalance worth discussing with a clinician.",
        interpret: { value in
            if value > 10 { return .concerning }
            if value > 5 { return .borderline }
            return .good
        }
    )

    private static let doubleSupport = ClinicalContext(
        typicalRangeLabel: "20–30%",
        explanation: "Double support percentage is how much of your walking cycle has both feet on the ground. Higher numbers indicate slower, more cautious walking — common with fatigue, injury, or aging. Consistently elevated values can be an early signal of mobility changes.",
        interpret: { value in
            if value > 40 { return .borderline }
            return .good
        }
    )

    private static let sixMinWalk = ClinicalContext(
        typicalRangeLabel: "400+ m (predicted)",
        explanation: "The Six-Minute Walk Distance is iOS's prediction of how far you'd walk in 6 minutes, derived from your iPhone's accelerometer. The clinical 6MWT (administered by a clinician) is used to track cardiorespiratory fitness in heart and lung patients. Apple's prediction is best read as a *trend*, not a clinical result.",
        interpret: { value in
            if value < 300 { return .borderline }
            return .good
        }
    )

    // MARK: - Vitals

    private static let systolicBP = ClinicalContext(
        typicalRangeLabel: "<120 mmHg",
        explanation: "Systolic blood pressure (the top number) measures arterial pressure when your heart beats. ACC/AHA classifies <120 as normal, 120–129 elevated, 130–139 stage 1 hypertension, 140+ stage 2. Single readings vary; the period average is more meaningful than any one measurement.",
        interpret: { value in
            if value >= 140 { return .concerning }
            if value >= 120 { return .borderline }
            return .good
        }
    )

    private static let diastolicBP = ClinicalContext(
        typicalRangeLabel: "<80 mmHg",
        explanation: "Diastolic blood pressure (the bottom number) is arterial pressure between beats. <80 is considered normal, 80–89 elevated, 90+ stage 2 hypertension. Sustained elevation is a major modifiable cardiovascular risk factor.",
        interpret: { value in
            if value >= 90 { return .concerning }
            if value >= 80 { return .borderline }
            return .good
        }
    )

    private static let spo2 = ClinicalContext(
        typicalRangeLabel: "≥95%",
        explanation: "Blood oxygen saturation (SpO₂) measures how much oxygen your red blood cells are carrying. ≥95% is typical at sea level; 91–94% may be concerning depending on context; persistent readings below 91% warrant clinical attention.",
        interpret: { value in
            if value < 91 { return .concerning }
            if value < 95 { return .borderline }
            return .good
        }
    )

    private static let respRate = ClinicalContext(
        typicalRangeLabel: "12–20 br/min",
        explanation: "Resting respiratory rate is breaths per minute when relaxed. Typical range is 12–20 for adults. Persistently elevated rates can indicate respiratory or cardiovascular stress, fever, or anxiety.",
        interpret: { value in
            if value < 10 || value > 24 { return .concerning }
            if value > 20 { return .borderline }
            return .good
        }
    )

    private static let bodyTemp = ClinicalContext(
        typicalRangeLabel: "97–99 °F",
        explanation: "Normal body temperature varies through the day (lower in the morning, higher in late afternoon) and across individuals. Persistent readings above 100.4°F qualify as fever.",
        interpret: { value in
            if value >= 100.4 || value <= 95 { return .concerning }
            if value >= 99.5 { return .borderline }
            return .good
        }
    )

    // MARK: - Body

    private static let bmi = ClinicalContext(
        typicalRangeLabel: "18.5–24.9",
        explanation: "Body mass index (BMI) is weight divided by height squared. It's an imperfect proxy for body composition — athletes can have a high BMI from muscle mass — but at the population level, 18.5–24.9 is the WHO-defined healthy range, 25–29.9 overweight, 30+ obese.",
        interpret: { value in
            if value < 18.5 || value >= 30 { return .borderline }
            if value >= 25 { return .borderline }
            return .good
        }
    )

    // MARK: - Logged

    private static let bloodGlucose = ClinicalContext(
        typicalRangeLabel: "70–99 mg/dL (fasting)",
        explanation: "Fasting blood glucose 70–99 mg/dL is normal, 100–125 indicates pre-diabetes, 126+ on two separate days meets the diabetes threshold. CGM data fluctuates throughout the day; the period average matters more than any single reading.",
        interpret: { value in
            if value >= 126 { return .concerning }
            if value >= 100 { return .borderline }
            return .good
        }
    )

    // MARK: - Insight generation

    /// Auto-computed "what's notable this period" cards shown above
    /// the metric grid. Pure stats-based — no LLM call. We surface up
    /// to 3, prioritized: concerning status > meaningful delta > new
    /// positive trend.
    struct Insight: Identifiable {
        var id = UUID()
        var icon: String
        var tint: Color
        var headline: String
        var detail: String
        /// The metric label this insight is about — lets the
        /// "Tell me more" CTA open the right detail sheet.
        var metricLabel: String?
    }

    /// Computes up to `maxInsights` insights from the supplied
    /// (label, MetricSeries, ClinicalContext?) tuples. Each entry
    /// represents one metric we have data for. The caller passes the
    /// full set; this function filters and ranks.
    static func computeInsights(
        from entries: [(label: String, series: HealthKitService.MetricSeries, context: ClinicalContext?)],
        maxInsights: Int = 3
    ) -> [Insight] {
        var insights: [Insight] = []

        // Priority 1: any metric whose status is .concerning
        for entry in entries {
            guard let ctx = entry.context else { continue }
            let status = ctx.interpret(entry.series.average)
            if status == .concerning {
                insights.append(Insight(
                    icon: "exclamationmark.triangle.fill",
                    tint: .red,
                    headline: "\(entry.label) outside typical range",
                    detail: "Average \(formatNumber(entry.series.average)) \(entry.series.unit) — typical is \(ctx.typicalRangeLabel).",
                    metricLabel: entry.label
                ))
            }
        }

        // Priority 2: meaningful deltas (>10% change vs prior period)
        for entry in entries {
            guard let prior = entry.series.previousAverage, prior > 0 else { continue }
            let delta = (entry.series.average - prior) / prior
            guard abs(delta) >= 0.10 else { continue }
            let pct = Int((delta * 100).rounded())
            let direction = delta > 0 ? "up" : "down"
            insights.append(Insight(
                icon: delta > 0 ? "arrow.up.right.circle.fill" : "arrow.down.right.circle.fill",
                tint: delta > 0 ? .blue : .orange,
                headline: "\(entry.label) \(direction) \(abs(pct))% vs prior period",
                detail: "Was \(formatNumber(prior)) \(entry.series.unit), now \(formatNumber(entry.series.average)) \(entry.series.unit).",
                metricLabel: entry.label
            ))
        }

        // Cap to maxInsights, preserving priority order.
        return Array(insights.prefix(maxInsights))
    }

    private static func formatNumber(_ value: Double) -> String {
        if value >= 1000 { return String(format: "%.0f", value) }
        if value >= 100  { return String(format: "%.0f", value) }
        if value >= 10   { return String(format: "%.1f", value) }
        return String(format: "%.2f", value)
    }
}
