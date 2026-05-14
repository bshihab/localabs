import Foundation
import HealthKit

/// Reads historical health metrics from Apple Health (HealthKit).
/// All data stays on-device — nothing is uploaded.
@MainActor
class HealthKitService {

    static let shared = HealthKitService()
    private let healthStore = HKHealthStore()

    /// We track whether the auth sheet has been presented at least once via
    /// UserDefaults. iOS deliberately doesn't tell apps whether read access
    /// was granted (privacy by design) — apps just get empty results when
    /// denied. So the best we can do is track "did the user complete the
    /// auth flow once" and infer everything else from query results.
    private let hasRequestedKey = "healthkit_auth_requested"

    var hasRequestedAuthorization: Bool {
        UserDefaults.standard.bool(forKey: hasRequestedKey)
    }

    var isHealthDataAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    // MARK: - Existing report-time metrics

    /// Subset used by InferenceEngine when building the LLM prompt for a
    /// lab analysis. Kept as a small flat struct because the report-time
    /// pipeline only needs 30-day averages of the cardiac/recovery
    /// dimension.
    struct HealthMetrics {
        var avgRestingHR: Double?
        var avgSleepHours: Double?
        var avgHRV: Double?

        /// True when every metric is missing. Lets the UI render a
        /// genuine empty state ("no Apple Health data yet") instead of
        /// showing zeros — and lets InferenceEngine skip injecting a
        /// useless Health section into the prompt.
        var isEmpty: Bool {
            avgRestingHR == nil && avgSleepHours == nil && avgHRV == nil
        }
    }

    /// Fetches the 30-day averages for resting HR, sleep, and HRV — the
    /// minimum set the LLM prompt has expected since v1. Returns a
    /// HealthMetrics with whatever subset HealthKit could produce; nil
    /// for missing/denied types. The UI handles the all-nil empty
    /// state explicitly; we do not fall back to mock/demo values.
    func getHealthMetrics() async -> HealthMetrics {
        let calendar = Calendar.current
        let endDate = Date()
        guard let startDate = calendar.date(byAdding: .day, value: -30, to: endDate) else {
            return HealthMetrics()
        }

        async let restingHR = fetchAverage(for: .restingHeartRate, unit: HKUnit(from: "count/min"), from: startDate, to: endDate)
        async let hrv = fetchAverage(for: .heartRateVariabilitySDNN, unit: HKUnit.secondUnit(with: .milli), from: startDate, to: endDate)
        async let sleep = fetchAverageSleep(from: startDate, to: endDate)

        return HealthMetrics(
            avgRestingHR: await restingHR,
            avgSleepHours: await sleep,
            avgHRV: await hrv
        )
    }

    // MARK: - Trends tab metrics

    /// Captures the full panel the Trends tab consumes — average,
    /// daily series for sparklines, and unit metadata. nil entries mean
    /// the user either doesn't have that data type populated (phone-
    /// only users won't have HRV, for example) or denied access. The
    /// view layer hides cards whose backing metrics are all nil.
    struct TrendsSnapshot {
        var rangeDays: Int

        // Activity (phone alone produces all of these)
        var steps: MetricSeries?
        var walkingRunningDistance: MetricSeries?
        var flightsClimbed: MetricSeries?
        var exerciseMinutes: MetricSeries?
        var activeEnergy: MetricSeries?

        // Mobility (mostly phone; passive accelerometer-derived
        // signals that correlate with clinical gait/fall-risk
        // measures but are NOT FDA-cleared diagnostics)
        var walkingSpeed: MetricSeries?
        var walkingStepLength: MetricSeries?
        var walkingAsymmetry: MetricSeries?
        var walkingDoubleSupport: MetricSeries?
        var sixMinuteWalkDistance: MetricSeries?

        // Cardio + recovery (Watch for HRV/VO2max; phone-only users see
        // resting HR only if a paired device wrote samples)
        var restingHR: MetricSeries?
        var hrv: MetricSeries?
        var vo2Max: MetricSeries?
        var walkingHR: MetricSeries?

        // Sleep — total hours per night
        var sleepHours: MetricSeries?

        // Vitals
        var systolicBP: MetricSeries?
        var diastolicBP: MetricSeries?
        var oxygenSaturation: MetricSeries?
        var respiratoryRate: MetricSeries?
        var bodyTemperature: MetricSeries?

        // Body
        var bodyMass: MetricSeries?
        var bodyMassIndex: MetricSeries?

        // Logged / nutrition
        var bloodGlucose: MetricSeries?
        var caffeine: MetricSeries?
    }

    /// One metric's time series for the selected range. `average` is
    /// what the card displays as the headline number; `daily` powers
    /// the sparkline. `unit` is a display string (e.g. "bpm", "h",
    /// "lb"); the actual unit conversion happens at fetch time.
    /// `previousAverage` is the same metric's average over the prior
    /// same-sized window — used for the "↑ X% vs prior" delta line
    /// on the card.
    struct MetricSeries {
        var average: Double
        var daily: [DailyValue]
        var unit: String
        var previousAverage: Double?

        /// Empty when HealthKit returned no samples in the window —
        /// callers should treat this as "no data" and not render a card.
        var hasData: Bool { !daily.isEmpty }
    }

    struct DailyValue: Identifiable {
        var id: Date { date }
        var date: Date
        var value: Double
    }

    /// Fetches every metric the Trends tab knows about over the given
    /// window. Concurrent so the wait time is bounded by the slowest
    /// query, not the sum of them. Any individual fetch that returns
    /// nil (denied / never logged) leaves the corresponding field nil
    /// in the snapshot — Trends hides the matching card.
    func getTrends(rangeDays: Int) async -> TrendsSnapshot {
        let calendar = Calendar.current
        let endDate = Date()
        guard
            let startDate = calendar.date(byAdding: .day, value: -rangeDays, to: endDate),
            let priorStart = calendar.date(byAdding: .day, value: -rangeDays * 2, to: endDate)
        else {
            return TrendsSnapshot(rangeDays: rangeDays)
        }

        // Activity
        async let steps = fetchSumSeries(for: .stepCount, unit: .count(), unitLabel: "steps", from: startDate, to: endDate, priorStart: priorStart)
        async let distance = fetchSumSeries(for: .distanceWalkingRunning, unit: HKUnit.mile(), unitLabel: "mi", from: startDate, to: endDate, priorStart: priorStart)
        async let flights = fetchSumSeries(for: .flightsClimbed, unit: .count(), unitLabel: "flights", from: startDate, to: endDate, priorStart: priorStart)
        async let exercise = fetchSumSeries(for: .appleExerciseTime, unit: .minute(), unitLabel: "min", from: startDate, to: endDate, priorStart: priorStart)
        async let energy = fetchSumSeries(for: .activeEnergyBurned, unit: .kilocalorie(), unitLabel: "kcal", from: startDate, to: endDate, priorStart: priorStart)

        // Mobility
        async let walkSpeed = fetchAverageSeries(for: .walkingSpeed, unit: HKUnit(from: "mi/hr"), unitLabel: "mph", from: startDate, to: endDate, priorStart: priorStart)
        async let stepLength = fetchAverageSeries(for: .walkingStepLength, unit: .inch(), unitLabel: "in", from: startDate, to: endDate, priorStart: priorStart)
        async let asymmetry = fetchAverageSeries(for: .walkingAsymmetryPercentage, unit: .percent(), unitLabel: "%", from: startDate, to: endDate, priorStart: priorStart, multiplyBy: 100)
        async let doubleSupport = fetchAverageSeries(for: .walkingDoubleSupportPercentage, unit: .percent(), unitLabel: "%", from: startDate, to: endDate, priorStart: priorStart, multiplyBy: 100)
        async let sixMinWalk = fetchAverageSeries(for: .sixMinuteWalkTestDistance, unit: .meter(), unitLabel: "m", from: startDate, to: endDate, priorStart: priorStart)

        // Cardio + recovery
        async let restingHR = fetchAverageSeries(for: .restingHeartRate, unit: HKUnit(from: "count/min"), unitLabel: "bpm", from: startDate, to: endDate, priorStart: priorStart)
        async let hrv = fetchAverageSeries(for: .heartRateVariabilitySDNN, unit: HKUnit.secondUnit(with: .milli), unitLabel: "ms", from: startDate, to: endDate, priorStart: priorStart)
        async let vo2 = fetchAverageSeries(for: .vo2Max, unit: HKUnit(from: "ml/(kg*min)"), unitLabel: "ml/kg/min", from: startDate, to: endDate, priorStart: priorStart)
        async let walkingHR = fetchAverageSeries(for: .walkingHeartRateAverage, unit: HKUnit(from: "count/min"), unitLabel: "bpm", from: startDate, to: endDate, priorStart: priorStart)

        // Sleep
        async let sleepSeries = fetchSleepSeries(from: startDate, to: endDate, priorStart: priorStart)

        // Vitals
        async let sbp = fetchAverageSeries(for: .bloodPressureSystolic, unit: .millimeterOfMercury(), unitLabel: "mmHg", from: startDate, to: endDate, priorStart: priorStart)
        async let dbp = fetchAverageSeries(for: .bloodPressureDiastolic, unit: .millimeterOfMercury(), unitLabel: "mmHg", from: startDate, to: endDate, priorStart: priorStart)
        async let spo2 = fetchAverageSeries(for: .oxygenSaturation, unit: .percent(), unitLabel: "%", from: startDate, to: endDate, priorStart: priorStart, multiplyBy: 100)
        async let respRate = fetchAverageSeries(for: .respiratoryRate, unit: HKUnit(from: "count/min"), unitLabel: "br/min", from: startDate, to: endDate, priorStart: priorStart)
        async let temp = fetchAverageSeries(for: .bodyTemperature, unit: .degreeFahrenheit(), unitLabel: "°F", from: startDate, to: endDate, priorStart: priorStart)

        // Body
        async let weight = fetchAverageSeries(for: .bodyMass, unit: .pound(), unitLabel: "lb", from: startDate, to: endDate, priorStart: priorStart)
        async let bmi = fetchAverageSeries(for: .bodyMassIndex, unit: .count(), unitLabel: "BMI", from: startDate, to: endDate, priorStart: priorStart)

        // Logged
        async let glucose = fetchAverageSeries(for: .bloodGlucose, unit: HKUnit(from: "mg/dL"), unitLabel: "mg/dL", from: startDate, to: endDate, priorStart: priorStart)
        async let caffeine = fetchSumSeries(for: .dietaryCaffeine, unit: HKUnit.gramUnit(with: .milli), unitLabel: "mg", from: startDate, to: endDate, priorStart: priorStart)

        return TrendsSnapshot(
            rangeDays: rangeDays,
            steps: await steps,
            walkingRunningDistance: await distance,
            flightsClimbed: await flights,
            exerciseMinutes: await exercise,
            activeEnergy: await energy,
            walkingSpeed: await walkSpeed,
            walkingStepLength: await stepLength,
            walkingAsymmetry: await asymmetry,
            walkingDoubleSupport: await doubleSupport,
            sixMinuteWalkDistance: await sixMinWalk,
            restingHR: await restingHR,
            hrv: await hrv,
            vo2Max: await vo2,
            walkingHR: await walkingHR,
            sleepHours: await sleepSeries,
            systolicBP: await sbp,
            diastolicBP: await dbp,
            oxygenSaturation: await spo2,
            respiratoryRate: await respRate,
            bodyTemperature: await temp,
            bodyMass: await weight,
            bodyMassIndex: await bmi,
            bloodGlucose: await glucose,
            caffeine: await caffeine
        )
    }

    // MARK: - Report-time snapshot

    /// 7-day averages centered on `date` — used by DashboardView to
    /// show the user's resting HR / HRV / sleep / steps *at the time*
    /// they scanned a lab report. Anchors the report in their broader
    /// health state. Returns nil for any metric the user hasn't
    /// authorized or doesn't have data for around that window.
    struct ReportTimeMetrics {
        var restingHR: Double?
        var hrv: Double?
        var sleepHours: Double?
        var steps: Double?

        var isEmpty: Bool {
            restingHR == nil && hrv == nil && sleepHours == nil && steps == nil
        }
    }

    func getMetricsAround(date: Date) async -> ReportTimeMetrics {
        let calendar = Calendar.current
        // 7-day window centered on the report date. If the report is
        // recent (less than 3 days old) the window will overlap with
        // "now" — that's fine, we just want the user's typical state
        // around when they got the panel back.
        guard
            let start = calendar.date(byAdding: .day, value: -7, to: date),
            let end = calendar.date(byAdding: .day, value: 1, to: date)
        else {
            return ReportTimeMetrics()
        }

        async let restingHR = fetchAverage(for: .restingHeartRate, unit: HKUnit(from: "count/min"), from: start, to: end)
        async let hrv = fetchAverage(for: .heartRateVariabilitySDNN, unit: HKUnit.secondUnit(with: .milli), from: start, to: end)
        async let sleep = fetchAverageSleep(from: start, to: end)
        async let steps = fetchStepsSum(from: start, to: end)

        return ReportTimeMetrics(
            restingHR: await restingHR,
            hrv: await hrv,
            sleepHours: await sleep,
            steps: await steps
        )
    }

    /// Discrete sum over the window — only used by ReportTimeMetrics
    /// for the steps figure. The Trends path uses HKStatisticsCollectionQuery
    /// for per-day buckets, but here we just want the daily average
    /// for an at-a-glance card.
    private func fetchStepsSum(from startDate: Date, to endDate: Date) async -> Double? {
        guard let stepsType = HKQuantityType.quantityType(forIdentifier: .stepCount) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: stepsType, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, result, _ in
                guard let sum = result?.sumQuantity()?.doubleValue(for: .count()) else {
                    continuation.resume(returning: nil)
                    return
                }
                let days = max(1, Calendar.current.dateComponents([.day], from: startDate, to: endDate).day ?? 7)
                continuation.resume(returning: (sum / Double(days)).rounded())
            }
            healthStore.execute(query)
        }
    }

    // MARK: - Authorization

    /// Read access to every type the Trends tab + report pipeline can
    /// consume. The system permission sheet shows one row per type;
    /// users can deny anything individually and the Trends cards will
    /// silently hide.
    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = []
        let quantity: [HKQuantityTypeIdentifier] = [
            .restingHeartRate,
            .heartRateVariabilitySDNN,
            .walkingHeartRateAverage,
            .vo2Max,
            .stepCount,
            .distanceWalkingRunning,
            .flightsClimbed,
            .appleExerciseTime,
            .activeEnergyBurned,
            .walkingSpeed,
            .walkingStepLength,
            .walkingAsymmetryPercentage,
            .walkingDoubleSupportPercentage,
            .sixMinuteWalkTestDistance,
            .bloodPressureSystolic,
            .bloodPressureDiastolic,
            .oxygenSaturation,
            .respiratoryRate,
            .bodyTemperature,
            .bodyMass,
            .bodyMassIndex,
            .bloodGlucose,
            .dietaryCaffeine
        ]
        for id in quantity {
            if let t = HKQuantityType.quantityType(forIdentifier: id) { types.insert(t) }
        }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            types.insert(sleep)
        }
        return types
    }

    /// Requests read-only access to the health data types we need.
    /// Returns true if the auth flow completed (the user saw the sheet and
    /// dismissed it) — NOT necessarily that they granted access. iOS hides
    /// that distinction for privacy.
    func requestAuthorization() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }

        do {
            try await healthStore.requestAuthorization(toShare: [], read: readTypes)
            UserDefaults.standard.set(true, forKey: hasRequestedKey)
            return true
        } catch {
            print("[HealthKit] Authorization failed: \(error)")
            return false
        }
    }

    // MARK: - Single-value averages (used by InferenceEngine)

    private func fetchAverage(for identifier: HKQuantityTypeIdentifier, unit: HKUnit, from startDate: Date, to endDate: Date) async -> Double? {
        guard let quantityType = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }

        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let options: HKStatisticsOptions = .discreteAverage

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: quantityType, quantitySamplePredicate: predicate, options: options) { _, result, _ in
                let value = result?.averageQuantity()?.doubleValue(for: unit)
                continuation.resume(returning: value.map { ($0 * 10).rounded() / 10 })
            }
            healthStore.execute(query)
        }
    }

    private func fetchAverageSleep(from startDate: Date, to endDate: Date) async -> Double? {
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return nil }

        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: sleepType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                guard let samples = samples as? [HKCategorySample], !samples.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }

                let totalSeconds = samples.reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }
                let totalDays = max(1, Calendar.current.dateComponents([.day], from: startDate, to: endDate).day ?? 1)
                let avgHours = (totalSeconds / Double(totalDays)) / 3600.0
                continuation.resume(returning: (avgHours * 10).rounded() / 10)
            }
            healthStore.execute(query)
        }
    }

    // MARK: - Per-day time series (used by Trends)

    /// Bucketed-by-day SUM aggregation. Right for cumulative counters
    /// where the daily total is the meaningful headline (steps,
    /// distance, exercise minutes, kcal, caffeine).
    private func fetchSumSeries(
        for identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        unitLabel: String,
        from startDate: Date,
        to endDate: Date,
        priorStart: Date
    ) async -> MetricSeries? {
        await fetchSeries(identifier: identifier, unit: unit, unitLabel: unitLabel, options: .cumulativeSum, from: startDate, to: endDate, priorStart: priorStart)
    }

    /// Bucketed-by-day AVERAGE aggregation. Right for measured values
    /// where the daily mean is meaningful (HR, HRV, walking speed,
    /// weight, BP, SpO2, etc.).
    private func fetchAverageSeries(
        for identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        unitLabel: String,
        from startDate: Date,
        to endDate: Date,
        priorStart: Date,
        multiplyBy: Double = 1
    ) async -> MetricSeries? {
        await fetchSeries(identifier: identifier, unit: unit, unitLabel: unitLabel, options: .discreteAverage, from: startDate, to: endDate, priorStart: priorStart, multiplyBy: multiplyBy)
    }

    /// The actual statistics-collection plumbing. iOS gives us
    /// `HKStatisticsCollectionQuery` which buckets samples into fixed
    /// intervals — we ask for one bucket per calendar day. We query
    /// `priorStart...endDate` in one pass and split the results on
    /// `startDate`, so we get both the current-period series + a
    /// prior-period average for the delta indicator with a single
    /// HealthKit roundtrip per metric.
    private func fetchSeries(
        identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        unitLabel: String,
        options: HKStatisticsOptions,
        from startDate: Date,
        to endDate: Date,
        priorStart: Date,
        multiplyBy: Double = 1
    ) async -> MetricSeries? {
        guard let quantityType = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }

        let calendar = Calendar.current
        let anchor = calendar.startOfDay(for: priorStart)
        let interval = DateComponents(day: 1)
        let predicate = HKQuery.predicateForSamples(withStart: priorStart, end: endDate, options: .strictStartDate)

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: quantityType,
                quantitySamplePredicate: predicate,
                options: options,
                anchorDate: anchor,
                intervalComponents: interval
            )
            query.initialResultsHandler = { _, results, _ in
                guard let results else {
                    continuation.resume(returning: nil)
                    return
                }
                var currentDaily: [DailyValue] = []
                var priorDaily: [DailyValue] = []
                results.enumerateStatistics(from: priorStart, to: endDate) { stats, _ in
                    let raw: Double?
                    switch options {
                    case .cumulativeSum:
                        raw = stats.sumQuantity()?.doubleValue(for: unit)
                    case .discreteAverage:
                        raw = stats.averageQuantity()?.doubleValue(for: unit)
                    default:
                        raw = nil
                    }
                    if let value = raw {
                        let entry = DailyValue(date: stats.startDate, value: value * multiplyBy)
                        if stats.startDate < startDate {
                            priorDaily.append(entry)
                        } else {
                            currentDaily.append(entry)
                        }
                    }
                }
                guard !currentDaily.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                let avg = currentDaily.map(\.value).reduce(0, +) / Double(currentDaily.count)
                let priorAvg: Double? = priorDaily.isEmpty
                    ? nil
                    : (priorDaily.map(\.value).reduce(0, +) / Double(priorDaily.count))
                continuation.resume(returning: MetricSeries(
                    average: (avg * 10).rounded() / 10,
                    daily: currentDaily,
                    unit: unitLabel,
                    previousAverage: priorAvg.map { ($0 * 10).rounded() / 10 }
                ))
            }
            healthStore.execute(query)
        }
    }

    /// Sleep needs special handling because each sample is a (start,
    /// end) range that can span midnight. We bucket by "sleep night"
    /// using the end date — Apple's own convention for sleep cards.
    /// Queries the doubled window (`priorStart...endDate`) and splits
    /// the per-day hours on `startDate` so we can also surface the
    /// prior-period average for the delta line on the sleep card.
    private func fetchSleepSeries(from startDate: Date, to endDate: Date, priorStart: Date) async -> MetricSeries? {
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: priorStart, end: endDate, options: .strictStartDate)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: sleepType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                guard let samples = samples as? [HKCategorySample], !samples.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                let calendar = Calendar.current
                var perDay: [Date: TimeInterval] = [:]
                for sample in samples {
                    // Apple convention: a night's sleep is attributed
                    // to the *waking* day, not the day the user fell
                    // asleep. End-date is what shows up in the Health
                    // app's daily summary.
                    let day = calendar.startOfDay(for: sample.endDate)
                    perDay[day, default: 0] += sample.endDate.timeIntervalSince(sample.startDate)
                }
                let sorted = perDay
                    .map { DailyValue(date: $0.key, value: $0.value / 3600.0) }
                    .sorted { $0.date < $1.date }
                let current = sorted.filter { $0.date >= startDate }
                let prior = sorted.filter { $0.date < startDate }
                guard !current.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                let avg = current.map(\.value).reduce(0, +) / Double(current.count)
                let priorAvg: Double? = prior.isEmpty
                    ? nil
                    : (prior.map(\.value).reduce(0, +) / Double(prior.count))
                continuation.resume(returning: MetricSeries(
                    average: (avg * 10).rounded() / 10,
                    daily: current,
                    unit: "h",
                    previousAverage: priorAvg.map { ($0 * 10).rounded() / 10 }
                ))
            }
            healthStore.execute(query)
        }
    }
}
