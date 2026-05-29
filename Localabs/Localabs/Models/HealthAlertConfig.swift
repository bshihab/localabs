import Foundation

/// User configuration for Trends threshold alerts — which Apple
/// Health metrics should fire a local notification when they drift
/// outside the user's age/sex-adjusted norms, and how sensitive
/// that trip should be.
///
/// The actual reference bands live in `HealthInsights` (the same
/// logic that colours the Trends cards). An alert config doesn't
/// store its own numeric cutoff — it just says "watch this metric,
/// at this sensitivity, for this many recent readings." That keeps
/// the thresholds in one place and means the alert and the on-card
/// status pill can never disagree.
struct HealthAlertConfig: Codable, Identifiable, Equatable {
    var metric: AlertMetric
    var enabled: Bool
    var sensitivity: Sensitivity
    /// How many of the most recent data points must all be at-or-
    /// worse than `sensitivity` before the alert trips. Counts data
    /// points, not calendar days — many metrics (HRV, BP, glucose)
    /// are logged irregularly, so requiring N consecutive *calendar*
    /// days with data would almost never fire. 3 is a sensible
    /// default: one bad reading is noise, three in a row is a trend.
    var consecutivePoints: Int

    var id: String { metric.rawValue }

    /// How far outside the norm a reading has to be to count toward
    /// tripping the alert.
    enum Sensitivity: String, Codable, CaseIterable {
        /// Trip on Borderline-or-worse. More sensitive, more noise.
        case borderline
        /// Trip only on Outside-typical (the red band). Quieter;
        /// the default, so users aren't nagged by mild drift.
        case concerning

        var displayName: String {
            switch self {
            case .borderline: return "Borderline or worse"
            case .concerning: return "Only when clearly off"
            }
        }

        /// Minimum HealthInsights.Status severity that counts as a
        /// trip. good = 0, borderline = 1, concerning = 2.
        var minSeverity: Int {
            switch self {
            case .borderline: return 1
            case .concerning: return 2
            }
        }
    }

    // MARK: - Persistence

    private static let storageKey = "localabs_health_alerts"

    /// Loads saved configs, backfilling any metric the user has
    /// never seen (e.g. a metric added in an app update) with its
    /// default. So the settings screen always shows the full set.
    static func loadAll() -> [HealthAlertConfig] {
        let saved: [HealthAlertConfig]
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([HealthAlertConfig].self, from: data) {
            saved = decoded
        } else {
            saved = []
        }
        let savedByMetric = Dictionary(
            saved.map { ($0.metric, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // Preserve the canonical metric order from the enum; merge
        // saved overrides on top of defaults.
        return AlertMetric.allCases.map { metric in
            savedByMetric[metric] ?? HealthAlertConfig.default(for: metric)
        }
    }

    static func saveAll(_ configs: [HealthAlertConfig]) {
        guard let data = try? JSONEncoder().encode(configs) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    /// Whether the user has at least one metric armed — used to
    /// decide whether to bother scheduling background work / asking
    /// for notification permission.
    static var anyEnabled: Bool {
        loadAll().contains { $0.enabled }
    }

    static func resetAll() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    /// Sensible per-metric default. Everything ships OFF — alerts
    /// are opt-in, both for notification-fatigue reasons and so we
    /// don't request notification permission until the user has
    /// actually armed something.
    static func `default`(for metric: AlertMetric) -> HealthAlertConfig {
        HealthAlertConfig(
            metric: metric,
            enabled: false,
            sensitivity: .concerning,
            consecutivePoints: 3
        )
    }
}

/// The metrics that support threshold alerts. A subset of the full
/// Trends catalogue — only the ones with a clinically meaningful
/// reference band in `HealthInsights` AND a reading frequent enough
/// that an alert is actionable. (Body weight, step length, etc. are
/// excluded — no universal norm or too noisy.)
///
/// Each case carries: the display label (which MUST match the keys
/// in `HealthInsights.clinicalContext(for:)` so the same bands
/// apply), and the keywords used to look up whether a past report
/// is relevant when an alert fires (so the notification can say
/// "...and your March cardiology report flagged this").
enum AlertMetric: String, Codable, CaseIterable, Identifiable {
    case restingHR
    case hrv
    case sleep
    case vo2Max
    case systolicBP
    case diastolicBP
    case oxygen
    case respiratory
    case bloodGlucose
    case bmi

    var id: String { rawValue }

    /// Must match the label passed to `HealthInsights.clinicalContext(for:)`.
    var clinicalLabel: String {
        switch self {
        case .restingHR:    return "Resting HR"
        case .hrv:          return "HRV"
        case .sleep:        return "Sleep"
        case .vo2Max:       return "VO₂ max"
        case .systolicBP:   return "Systolic BP"
        case .diastolicBP:  return "Diastolic BP"
        case .oxygen:       return "Oxygen"
        case .respiratory:  return "Respiratory"
        case .bloodGlucose: return "Blood glucose"
        case .bmi:          return "BMI"
        }
    }

    /// Short user-facing name for the settings row.
    var displayName: String {
        switch self {
        case .restingHR:    return "Resting heart rate"
        case .hrv:          return "Heart rate variability"
        case .sleep:        return "Sleep"
        case .vo2Max:       return "VO₂ max (cardio fitness)"
        case .systolicBP:   return "Systolic blood pressure"
        case .diastolicBP:  return "Diastolic blood pressure"
        case .oxygen:       return "Blood oxygen"
        case .respiratory:  return "Respiratory rate"
        case .bloodGlucose: return "Blood glucose"
        case .bmi:          return "Body mass index"
        }
    }

    var systemImage: String {
        switch self {
        case .restingHR, .hrv, .vo2Max: return "heart.fill"
        case .sleep:                    return "bed.double.fill"
        case .systolicBP, .diastolicBP: return "waveform.path.ecg"
        case .oxygen:                   return "lungs.fill"
        case .respiratory:              return "wind"
        case .bloodGlucose:             return "drop.fill"
        case .bmi:                      return "figure.stand"
        }
    }

    /// Lowercased keywords searched against past reports' text when
    /// an alert fires. A hit lets the notification connect the
    /// metric drift to a documented condition, which is the whole
    /// reason this beats Apple Health's generic notifications.
    var reportKeywords: [String] {
        switch self {
        case .restingHR, .hrv:
            return ["heart", "cardiac", "cardio", "hypertension", "arrhythmia", "tachycardia", "palpitation"]
        case .vo2Max:
            return ["cardio", "fitness", "heart", "pulmonary"]
        case .sleep:
            return ["sleep", "apnea", "insomnia", "fatigue"]
        case .systolicBP, .diastolicBP:
            return ["blood pressure", "hypertension", "hypotension", "bp"]
        case .oxygen:
            return ["oxygen", "spo2", "pulmonary", "respiratory", "copd", "asthma"]
        case .respiratory:
            return ["respiratory", "breathing", "pulmonary", "asthma", "copd"]
        case .bloodGlucose:
            return ["glucose", "diabetes", "a1c", "hba1c", "insulin", "prediabetes"]
        case .bmi:
            return ["weight", "obesity", "bmi", "metabolic"]
        }
    }
}
