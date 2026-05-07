import Foundation
import HealthKit

/// Reads historical health metrics from Apple Health (HealthKit).
/// All data stays on-device — nothing is uploaded.
@MainActor
class HealthKitService {
    
    static let shared = HealthKitService()
    private let healthStore = HKHealthStore()
    
    struct HealthMetrics {
        var avgRestingHR: Double?
        var avgSleepHours: Double?
        var avgHRV: Double?
        var isMockData: Bool = false
    }
    
    /// Requests read-only access to the health data types we need.
    func requestAuthorization() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        
        let typesToRead: Set<HKObjectType> = [
            HKObjectType.quantityType(forIdentifier: .restingHeartRate)!,
            HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!,
            HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!,
        ]
        
        do {
            try await healthStore.requestAuthorization(toShare: [], read: typesToRead)
            return true
        } catch {
            print("[HealthKit] Authorization failed: \(error)")
            return false
        }
    }
    
    /// Fetches the 30-day averages for resting HR, sleep, and HRV.
    func getHealthMetrics() async -> HealthMetrics {
        let calendar = Calendar.current
        let endDate = Date()
        guard let startDate = calendar.date(byAdding: .day, value: -30, to: endDate) else {
            return HealthMetrics(isMockData: true)
        }
        
        async let restingHR = fetchAverage(for: .restingHeartRate, unit: HKUnit(from: "count/min"), from: startDate, to: endDate)
        async let hrv = fetchAverage(for: .heartRateVariabilitySDNN, unit: HKUnit.secondUnit(with: .milli), from: startDate, to: endDate)
        async let sleep = fetchAverageSleep(from: startDate, to: endDate)
        
        let hr = await restingHR
        let hrvVal = await hrv
        let sleepVal = await sleep
        
        // If all values are nil, the user likely hasn't granted HealthKit access.
        // Return mock data for development/demo purposes.
        if hr == nil && hrvVal == nil && sleepVal == nil {
            return HealthMetrics(avgRestingHR: 62, avgSleepHours: 7.2, avgHRV: 42, isMockData: true)
        }
        
        return HealthMetrics(avgRestingHR: hr, avgSleepHours: sleepVal, avgHRV: hrvVal)
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
