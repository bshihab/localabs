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

    /// Requests read-only access to the health data types we need.
    /// Returns true if the auth flow completed (the user saw the sheet and
    /// dismissed it) — NOT necessarily that they granted access. iOS hides
    /// that distinction for privacy.
    func requestAuthorization() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }

        let typesToRead: Set<HKObjectType> = [
            HKObjectType.quantityType(forIdentifier: .restingHeartRate)!,
            HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!,
            HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!,
        ]

        do {
            try await healthStore.requestAuthorization(toShare: [], read: typesToRead)
            UserDefaults.standard.set(true, forKey: hasRequestedKey)
            return true
        } catch {
            print("[HealthKit] Authorization failed: \(error)")
            return false
        }
    }
    
    /// Fetches the 30-day averages for resting HR, sleep, and HRV.
    /// Returns `HealthMetrics` with whatever subset HealthKit could
    /// produce — nil for missing/denied types. The UI handles the
    /// all-nil empty state explicitly; we no longer fall back to
    /// mock/demo values, because seeing fake "62 bpm / 7.2 hr / 42 ms"
    /// confused users into thinking Health was working.
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
    
    // MARK: - Private Helpers
    
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
}
