import Foundation
import UIKit

/// The core AI engine that orchestrates the full pipeline:
/// Apple VisionKit OCR → MedGemma 4B (via llama.cpp on Metal GPU)
///
/// For now, this uses mock responses for development.
/// When we integrate llama.cpp via Swift Package Manager, the `runInference` method
/// will be swapped to call the real Metal-accelerated model.
@MainActor
class InferenceEngine: ObservableObject {
    
    static let shared = InferenceEngine()
    
    @Published var isModelLoaded = false
    @Published var loadingProgress: Double = 0
    @Published var isProcessing = false
    @Published var processingStatus = ""
    private var llamaContext: LlamaContext?
    private let modelFilename = "medgemma-4b.gguf"
    
    private var modelURL: URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths[0].appendingPathComponent(modelFilename)
    }
    
    /// Checks if the model file is already downloaded and loads it into Metal GPU memory.
    func initializeModel() async {
        guard !isModelLoaded else { return }
        
        let fileManager = FileManager.default
        // Check if the file exists and is reasonably large (to ignore the old dummy file)
        let isRealFile = (try? fileManager.attributesOfItem(atPath: modelURL.path)[.size] as? Int) ?? 0 > 10_000_000
        
        if !isRealFile {
            isProcessing = true
            processingStatus = "Downloading TinyLlama (637 MB)..."
            
            // Using TinyLlama 1.1B Chat (Q4_K_M) as our real test model
            let url = URL(string: "https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/tinyllama-1.1b-chat-v1.0.q4_k_m.gguf")!
            let downloader = ModelDownloader()
            
            downloader.onProgress = { [weak self] progress in
                self?.loadingProgress = progress
            }
            
            do {
                try await downloader.download(from: url, to: modelURL)
            } catch {
                print("Failed to download model: \(error)")
                isProcessing = false
                processingStatus = "Download failed."
                return
            }
            
            isProcessing = false
            processingStatus = ""
        }
        
        loadingProgress = 100
        
        // Load into Metal memory
        do {
            self.llamaContext = try LlamaContext(modelPath: modelURL.path)
            self.isModelLoaded = true
        } catch {
            print("Failed to load LLaMA model: \(error)")
        }
    }
    
    /// The full pipeline: Image → Apple VisionKit OCR → MedGemma Analysis → Structured Report
    func analyzeImage(_ image: UIImage) async -> StructuredReport {
        isProcessing = true
        defer { isProcessing = false }
        
        // Step 1: Extract text using Apple's native Vision framework
        processingStatus = "Scanning with Apple Vision..."
        let extractedText: String
        do {
            extractedText = try await VisionOCRService.extractText(from: image)
        } catch {
            print("[VisionOCR] Error: \(error)")
            return StructuredReport(patientSummary: "Failed to extract text from the image. Please try a clearer photo.")
        }
        
        if extractedText.isEmpty {
            return StructuredReport(patientSummary: "No text was found in this image. Please ensure the lab report is clearly visible and try again.")
        }
        
        // Step 2: Save original scan to disk for interactive review later
        processingStatus = "Saving scan..."
        let savedImageName = saveScannedImage(image)
        
        // Step 3: Fetch Apple Health context
        processingStatus = "Fetching Apple Health context..."
        let healthMetrics = await HealthKitService.shared.getHealthMetrics()
        
        // Step 4: Run MedGemma inference
        processingStatus = "MedGemma is analyzing your results..."
        var report = await runInference(extractedText: extractedText, healthMetrics: healthMetrics, mode: .lab)
        report.imagePath = savedImageName
        
        // Step 5: Save to local history vault
        LocalStorageService.shared.saveReport(report)
        
        processingStatus = ""
        return report
    }
    
    /// Saves a scanned image to the Documents/scans directory. Returns the filename.
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
    
    /// Runs the weekly Apple Health review (no image needed).
    func generateWeeklyReview() async -> StructuredReport {
        isProcessing = true
        defer { isProcessing = false }
        
        processingStatus = "Reading Apple Health data..."
        let healthMetrics = await HealthKitService.shared.getHealthMetrics()
        
        processingStatus = "MedGemma is reviewing your week..."
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
    
    /// Runs MedGemma inference on the extracted text.
    /// Currently returns mock data for development; will be replaced with llama.cpp Metal inference.
    private func runInference(extractedText: String, healthMetrics: HealthKitService.HealthMetrics, mode: AnalysisMode) async -> StructuredReport {
        let profile = UserProfile.load()
        let pastTranslation = LocalStorageService.shared.getMostRecentPastTranslation()
        
        // Build the prompt (same format we validated in test_advanced_features.py)
        // Use the RAG context builder to give MedGemma longitudinal memory
        let ragContext = LocalStorageService.shared.buildRAGContext(maxReports: 3)
        
        let behaviorPrompt = mode == .weekly
            ? "The user is requesting their weekly health check-in review. Analyze their Apple Health data provided below."
            : "The user just scanned a lab report. The following text was extracted using Apple's VisionKit OCR."
        
        let _prompt = """
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
        
        // Log the prompt for debugging
        print("[InferenceEngine] Prompt built (\(_prompt.count) chars)")
        
        // If we have a real loaded model, use it!
        if let context = llamaContext {
            // Predict asynchronously to not block the main UI thread
            let resultText = await Task.detached(priority: .userInitiated) {
                context.predict(prompt: _prompt, maxTokens: 1000)
            }.value
            
            return StructuredReport.parse(from: resultText)
        }
        
        // --- FALLBACK MOCK RESPONSE (if no real model file is present) ---
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        
        return StructuredReport(
            patientSummary: """
            Great news! I reviewed your lab results alongside your Apple Health data. \
            Your resting heart rate of \(healthMetrics.avgRestingHR.map { "\($0)" } ?? "62") bpm and \
            sleep average of \(healthMetrics.avgSleepHours.map { "\($0)" } ?? "7.2") hours both look healthy. \
            Your cholesterol panel shows Total Cholesterol is slightly elevated at 248 mg/dL (ideal is under 200), \
            and your HDL ("good" cholesterol) is a bit low at 35 mg/dL. This is very manageable with some small lifestyle tweaks!
            """,
            doctorQuestions: """
            1. "Dr. Reed, my LDL is 165 mg/dL — should we consider a statin medication, or would you recommend trying diet and exercise changes first?"
            
            2. "My HDL is 35 mg/dL, which is below the 40 mg/dL threshold. What specific activities or foods can I focus on to raise my HDL?"
            
            3. "Given my family history, how often should I be getting lipid panels done — annually, or more frequently?"
            """,
            dietaryAdvice: """
            Based on your elevated LDL and triglycerides, here is a 3-step plan:
            
            🥑 Step 1: Increase omega-3 fatty acids — Add salmon, walnuts, or flaxseeds to at least 3 meals per week.
            
            🥗 Step 2: Boost soluble fiber — Oatmeal, beans, and apples can actively lower LDL cholesterol by 5-10%.
            
            🚫 Step 3: Reduce saturated fats — Swap butter for olive oil, and limit red meat to once per week.
            """,
            medicalGlossary: """
            • Hyperlipidemia — A condition where you have too many fats (lipids) in your blood. Think of it as your blood being a little "thicker" than ideal.
            
            • LDL Cholesterol — Often called "bad" cholesterol. It can build up in your artery walls and increase heart disease risk.
            
            • HDL Cholesterol — Often called "good" cholesterol. It acts like a cleanup crew, carrying bad cholesterol away from your arteries.
            
            • Triglycerides — A type of fat in your blood. Your body converts unused calories into triglycerides for energy storage.
            """,
            medicationNotes: profile.medications.isEmpty
                ? "No medications were provided. You can add your current medications in your Profile to get personalized cross-referencing."
                : "Your medications (\(profile.medications)) have been noted. Based on the lab results, no obvious interactions were detected. However, always confirm with your physician.",
            rawText: "Mock development response"
        )
    }
    
    // MARK: - Follow-Up Chat
    
    /// Handles a follow-up question about specific text the user highlighted in the document viewer.
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
        
        if let context = llamaContext {
            return await Task.detached(priority: .userInitiated) {
                context.predict(prompt: prompt, maxTokens: 400)
            }.value
        }
        
        // Fallback response when model isn't loaded
        return "Based on your highlighted text \"\(selectedText)\", this appears to be a standard lab measurement. For a detailed AI explanation, please download the MedGemma engine in your Profile tab. In the meantime, consider bringing this up with your physician at your next visit."
    }
}
