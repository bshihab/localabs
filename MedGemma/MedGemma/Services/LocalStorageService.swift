import Foundation

/// Manages local on-device history of AI translations using UserDefaults.
/// Acts as the persistent "memory" for the AI — enabling longitudinal RAG
/// (Retrieval-Augmented Generation) so MedGemma can reference past reports.
///
/// All data stays on the phone — nothing is uploaded to the cloud.
@MainActor
class LocalStorageService {
    
    static let shared = LocalStorageService()
    private let storageKey = "medgemma_history_vault"
    private let maxRecords = 50  // Keep up to 50 past reports for rich longitudinal context
    
    // MARK: - Save & Retrieve
    
    /// Saves a new structured report to the local history vault.
    func saveReport(_ report: StructuredReport) {
        var history = getHistory()
        
        // Avoid saving duplicate reports (same timestamp)
        if history.contains(where: { $0.id == report.id }) { return }
        
        history.insert(report, at: 0)
        
        // Keep only the most recent records to prevent storage bloat
        if history.count > maxRecords {
            history = Array(history.prefix(maxRecords))
        }
        
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
    
    /// Retrieves the full translation history (newest first).
    func getHistory() -> [StructuredReport] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let history = try? JSONDecoder().decode([StructuredReport].self, from: data) else {
            return []
        }
        return history
    }
    
    /// Gets the most recent past translation to provide longitudinal context to MedGemma.
    func getMostRecentPastTranslation() -> String? {
        let history = getHistory()
        return history.first?.patientSummary
    }
    
    // MARK: - RAG Context Builder
    
    /// Builds a longitudinal context string from past reports for the AI prompt.
    /// This is the core of the "RAG" — it retrieves relevant past data so MedGemma
    /// can track trends, congratulate improvements, and flag regressions.
    func buildRAGContext(maxReports: Int = 3) -> String {
        let history = getHistory()
        guard !history.isEmpty else { return "" }
        
        let reportsToUse = Array(history.prefix(maxReports))
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        
        var context = "\n\nLONGITUDINAL PATIENT HISTORY (from previous visits):"
        
        for (index, report) in reportsToUse.enumerated() {
            let dateStr = formatter.string(from: report.timestamp)
            let summary = String(report.patientSummary.prefix(300)) // Limit each to 300 chars to save context window
            context += """
            
            --- Previous Report #\(index + 1) (\(dateStr)) ---
            \(summary)
            """
        }
        
        context += """
        
        --- END HISTORY ---
        (Use this history to identify trends. Congratulate improvements. Flag regressions. If a metric was high before and is normal now, celebrate it.)
        """
        
        return context
    }
    
    // MARK: - Search (Simple RAG Retrieval)
    
    /// Searches past reports for a keyword. Used for the future "Chat with your history" feature.
    /// Returns all reports whose summary, glossary, or raw text contain the search term.
    func searchHistory(for query: String) -> [StructuredReport] {
        let lowered = query.lowercased()
        return getHistory().filter { report in
            report.patientSummary.lowercased().contains(lowered) ||
            report.medicalGlossary.lowercased().contains(lowered) ||
            report.rawText.lowercased().contains(lowered) ||
            report.dietaryAdvice.lowercased().contains(lowered) ||
            report.medicationNotes.lowercased().contains(lowered)
        }
    }
    
    // MARK: - Cleanup
    
    /// Clears all history.
    func clearHistory() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
    
    /// Deletes a specific report by ID.
    func deleteReport(id: UUID) {
        var history = getHistory()
        history.removeAll { $0.id == id }
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
