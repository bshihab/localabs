import Foundation
import UIKit

/// Orchestrates the full pipeline:
/// Apple VisionKit OCR → MedGemma 4B (via llama.cpp on Metal GPU)
@MainActor
final class InferenceEngine: ObservableObject {

    static let shared = InferenceEngine()

    @Published var isModelLoaded = false
    @Published var loadingProgress: Double = 0
    @Published var bytesWritten: Int64 = 0
    @Published var bytesExpected: Int64 = 0
    @Published var isProcessing = false
    @Published var processingStatus = ""
    @Published var isDownloading = false
    @Published var downloadError: String?

    @Published private(set) var selectedModel: AvailableModel = {
        if let raw = UserDefaults.standard.string(forKey: "medgemma_selected_model"),
           let model = AvailableModel(rawValue: raw) {
            return model
        }
        return .medGemma4B
    }()

    private var llamaContext: LlamaContext?
    private var activeDownloader: ModelDownloader?
    private var downloadTask: Task<Void, Never>?

    private var modelURL: URL { selectedModel.localURL }

    func selectModel(_ model: AvailableModel) {
        guard model != selectedModel else { return }
        selectedModel = model
        UserDefaults.standard.set(model.rawValue, forKey: "medgemma_selected_model")
        llamaContext = nil
        isModelLoaded = false
        loadingProgress = 0
        bytesWritten = 0
        bytesExpected = 0
    }

    /// Loads the model into Metal GPU memory if it's already on disk.
    /// Does NOT download — that's a separate, user-initiated step.
    func loadModelIfDownloaded() async {
        guard !isModelLoaded, selectedModel.isDownloaded else { return }
        do {
            self.llamaContext = try LlamaContext(modelPath: modelURL.path)
            self.isModelLoaded = true
            self.loadingProgress = 1.0
        } catch {
            print("[InferenceEngine] Failed to load model: \(error)")
            self.downloadError = "Failed to load model into memory."
        }
    }

    /// User-triggered download of the currently selected model.
    func downloadSelectedModel() {
        guard !isDownloading else { return }
        downloadError = nil
        isDownloading = true
        loadingProgress = 0
        bytesWritten = 0
        bytesExpected = selectedModel.expectedSizeBytes

        let model = selectedModel
        let downloader = ModelDownloader()
        activeDownloader = downloader
        downloader.onProgress = { [weak self] progress in
            Task { @MainActor in
                self?.loadingProgress = progress.fractionCompleted
                self?.bytesWritten = progress.bytesWritten
                self?.bytesExpected = progress.bytesExpected
            }
        }

        downloadTask = Task { [weak self] in
            do {
                try await downloader.download(from: model.downloadURL, to: model.localURL)
                await MainActor.run {
                    self?.isDownloading = false
                    self?.activeDownloader = nil
                }
                await self?.loadModelIfDownloaded()
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.isDownloading = false
                    self.activeDownloader = nil
                    if (error as? URLError)?.code != .cancelled {
                        self.downloadError = error.localizedDescription
                    }
                }
            }
        }
    }

    func cancelDownload() {
        activeDownloader?.cancel()
        downloadTask?.cancel()
        isDownloading = false
        loadingProgress = 0
        bytesWritten = 0
    }

    func deleteSelectedModel() {
        try? FileManager.default.removeItem(at: selectedModel.localURL)
        llamaContext = nil
        isModelLoaded = false
        loadingProgress = 0
        bytesWritten = 0
    }

    // MARK: - Pipeline

    /// Image → Apple VisionKit OCR → MedGemma → StructuredReport
    func analyzeImage(_ image: UIImage) async -> StructuredReport {
        isProcessing = true
        defer { isProcessing = false }

        processingStatus = "Scanning with Apple Vision…"
        let extractedText: String
        do {
            extractedText = try await VisionOCRService.extractText(from: image)
        } catch {
            return StructuredReport(patientSummary: "Failed to extract text from the image. Please try a clearer photo.")
        }

        if extractedText.isEmpty {
            return StructuredReport(patientSummary: "No text was found in this image. Please ensure the lab report is clearly visible and try again.")
        }

        processingStatus = "Saving scan…"
        let savedImageName = saveScannedImage(image)

        processingStatus = "Fetching Apple Health context…"
        let healthMetrics = await HealthKitService.shared.getHealthMetrics()

        processingStatus = "MedGemma is analyzing your results…"
        var report = await runInference(extractedText: extractedText, healthMetrics: healthMetrics, mode: .lab)
        report.imagePath = savedImageName

        LocalStorageService.shared.saveReport(report)

        processingStatus = ""
        return report
    }

    private func saveScannedImage(_ image: UIImage) -> String? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let scansDir = docs.appendingPathComponent("scans")
        try? FileManager.default.createDirectory(at: scansDir, withIntermediateDirectories: true)

        let filename = "\(UUID().uuidString).jpg"
        let fileURL = scansDir.appendingPathComponent(filename)

        if let data = image.jpegData(compressionQuality: 0.85) {
            try? data.write(to: fileURL)
            return filename
        }
        return nil
    }

    /// Apple Health-only weekly review (no scan).
    func generateWeeklyReview() async -> StructuredReport {
        isProcessing = true
        defer { isProcessing = false }

        processingStatus = "Reading Apple Health data…"
        let healthMetrics = await HealthKitService.shared.getHealthMetrics()

        processingStatus = "MedGemma is reviewing your week…"
        let report = await runInference(
            extractedText: "No physical lab report was scanned. Focus purely on evaluating the Apple Health context.",
            healthMetrics: healthMetrics,
            mode: .weekly
        )

        LocalStorageService.shared.saveReport(report)
        processingStatus = ""
        return report
    }

    // MARK: - Private

    enum AnalysisMode { case lab, weekly }

    private func runInference(extractedText: String, healthMetrics: HealthKitService.HealthMetrics, mode: AnalysisMode) async -> StructuredReport {
        let profile = UserProfile.load()
        let ragContext = LocalStorageService.shared.buildRAGContext(maxReports: 3)

        let behaviorPrompt = mode == .weekly
            ? "The user is requesting their weekly health check-in review. Analyze their Apple Health data provided below."
            : "The user just scanned a lab report. The following text was extracted using Apple's VisionKit OCR."

        let prompt = """
        <start_of_turn>user
        You are an empathetic, highly trained medical assistant.
        \(behaviorPrompt)

        User's Personal Health Context:
        - Known Medical Conditions: \(profile.medicalConditions.isEmpty ? "None reported" : profile.medicalConditions)
        - Current Daily Medications: \(profile.medications.isEmpty ? "None reported" : profile.medications)
        - Resting HR (30-day avg): \(healthMetrics.avgRestingHR.map { "\($0) bpm" } ?? "Unknown")
        - Sleep (30-day avg): \(healthMetrics.avgSleepHours.map { "\($0) hours" } ?? "Unknown")
        - HRV (30-day avg): \(healthMetrics.avgHRV.map { "\($0) ms" } ?? "Unknown")\(ragContext)

        Lab Report OCR Text:
        "\(extractedText)"

        Provide a report with these 5 headers:
        1. PATIENT SUMMARY
        2. QUESTIONS FOR YOUR DOCTOR
        3. TARGETED DIETARY ADVICE
        4. MEDICAL GLOSSARY
        5. MEDICATION NOTES
        <end_of_turn>
        <start_of_turn>model
        """

        guard let context = llamaContext else {
            return StructuredReport(
                patientSummary: "MedGemma is not loaded. Open Profile and download \(selectedModel.displayName) (\(selectedModel.humanSize)) to enable on-device analysis.",
                rawText: extractedText
            )
        }

        let resultText = await Task.detached(priority: .userInitiated) {
            context.predict(prompt: prompt, maxTokens: 1000)
        }.value

        var parsed = StructuredReport.parse(from: resultText)
        if parsed.rawText.isEmpty { parsed.rawText = resultText }
        return parsed
    }

    // MARK: - Follow-Up Chat

    func askFollowUp(question: String, selectedText: String, reportContext: String, ocrText: String) async -> String {
        let profile = UserProfile.load()

        let prompt = """
        <start_of_turn>user
        You are an empathetic medical assistant. The user has a lab report and is asking about specific text they highlighted.

        Context from their full report analysis:
        "\(String(reportContext.prefix(500)))"

        The user highlighted this specific text from their lab report:
        "\(selectedText)"

        User's medical context:
        - Conditions: \(profile.medicalConditions.isEmpty ? "None reported" : profile.medicalConditions)
        - Medications: \(profile.medications.isEmpty ? "None reported" : profile.medications)

        Their question: "\(question)"

        Provide a clear, empathetic answer in 2-4 sentences. Use simple language. If the highlighted text contains a medical term, define it. If it's a lab value, explain whether it's normal and what it means.
        <end_of_turn>
        <start_of_turn>model
        """

        guard let context = llamaContext else {
            return "MedGemma isn't loaded yet. Download \(selectedModel.displayName) in Profile to get a real answer about “\(selectedText.prefix(60))…”."
        }

        return await Task.detached(priority: .userInitiated) {
            context.predict(prompt: prompt, maxTokens: 400)
        }.value
    }
}
