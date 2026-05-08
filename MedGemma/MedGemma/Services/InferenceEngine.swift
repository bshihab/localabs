import Foundation
import UIKit
import UserNotifications
import PDFKit

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
    @Published var streamingText = ""
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
            await self?.requestNotificationPermissionIfNeeded()
            do {
                try await downloader.download(from: model.downloadURL, to: model.localURL)
                await MainActor.run {
                    self?.isDownloading = false
                    self?.activeDownloader = nil
                }
                await self?.loadModelIfDownloaded()
                await self?.scheduleModelReadyNotificationIfPermitted()
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

    // MARK: - Notifications

    /// Asks for permission once. If the user has already decided (granted or
    /// denied), this no-ops — iOS only shows the system prompt for `.notDetermined`.
    private func requestNotificationPermissionIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    /// Fires a local banner the moment the model finishes loading into Metal.
    /// iOS suppresses this in the foreground by default, which is what we want —
    /// if the user is in-app the green "loaded & ready" badge already covers it.
    /// They'll see the banner on the lock screen / notification center if they
    /// switched away during the download.
    private func scheduleModelReadyNotificationIfPermitted() async {
        guard isModelLoaded else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else { return }

        let content = UNMutableNotificationContent()
        content.title = "\(selectedModel.displayName) is ready"
        content.body = "Open MedGemma to scan a lab report."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "medgemma-model-download-complete",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
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
    /// Single-image convenience wrapper.
    func analyzeImage(_ image: UIImage) async -> StructuredReport {
        await analyzeImages([image])
    }

    /// Multi-page entry point. Runs OCR on each image (or PDF page rendered
    /// to image), concatenates the extracted text with page markers so
    /// MedGemma can reason about page boundaries, saves every image, and
    /// returns a single StructuredReport with `imagePath` = page 1 and
    /// `additionalPagePaths` = pages 2…N.
    func analyzeImages(_ images: [UIImage]) async -> StructuredReport {
        guard !images.isEmpty else {
            return StructuredReport(patientSummary: "No pages were provided.")
        }

        isProcessing = true
        defer { isProcessing = false }

        // ── OCR every page sequentially ──
        // Sequential (not concurrent) because each Vision call already
        // allocates significant memory; running 5 in parallel against a
        // 4B model in RAM courts the same jetsam crash we just fixed.
        var pageTexts: [String] = []
        for (idx, image) in images.enumerated() {
            processingStatus = images.count == 1
                ? "Scanning with Apple Vision…"
                : "Scanning page \(idx + 1) of \(images.count)…"
            do {
                let text = try await VisionOCRService.extractText(from: image)
                pageTexts.append(text)
            } catch {
                pageTexts.append("")
            }
        }

        let combinedText = combinePageTexts(pageTexts)
        if combinedText.isEmpty {
            return StructuredReport(patientSummary: "No text was found in these pages. Please ensure the document is clearly visible and try again.")
        }

        // ── Save every page image ──
        processingStatus = "Saving scan…"
        let savedNames = images.compactMap { saveScannedImage($0) }
        let firstPath = savedNames.first
        let extraPaths = savedNames.count > 1 ? Array(savedNames.dropFirst()) : nil

        processingStatus = "Fetching Apple Health context…"
        let healthMetrics = await HealthKitService.shared.getHealthMetrics()

        processingStatus = "MedGemma is analyzing your results…"
        var report = await runInference(extractedText: combinedText, healthMetrics: healthMetrics, mode: .lab)
        report.imagePath = firstPath
        report.additionalPagePaths = extraPaths

        LocalStorageService.shared.saveReport(report)
        processingStatus = ""
        return report
    }

    /// Picks up a PDF, renders each page to an image, extracts text (using
    /// the embedded PDF text where available, falling back to Vision OCR
    /// per page), and runs the same MedGemma pipeline as `analyzeImages`.
    /// The rendered page images are kept around so the document viewer
    /// can show what the user looked at.
    func analyzePDF(at url: URL) async -> StructuredReport {
        let needsScopedAccess = url.startAccessingSecurityScopedResource()
        defer { if needsScopedAccess { url.stopAccessingSecurityScopedResource() } }

        guard let document = PDFDocument(url: url), document.pageCount > 0 else {
            return StructuredReport(patientSummary: "Couldn't open this PDF. Try a different file.")
        }

        // Render every page as an image so the user can see the pages
        // in the document viewer later. Quality is high enough for OCR
        // and overlay alignment without ballooning memory.
        var images: [UIImage] = []
        var pdfTextByPage: [String] = []
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            images.append(renderPDFPage(page))
            pdfTextByPage.append(page.string ?? "")
        }

        // If the PDF has embedded text on every page, skip OCR and use it
        // directly — much faster and more accurate. If any page is empty
        // (scanned PDF), fall through to OCR via analyzeImages.
        let hasEmbeddedTextEverywhere = pdfTextByPage.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if hasEmbeddedTextEverywhere {
            isProcessing = true
            defer { isProcessing = false }

            processingStatus = "Saving PDF…"
            let savedNames = images.compactMap { saveScannedImage($0) }
            let firstPath = savedNames.first
            let extraPaths = savedNames.count > 1 ? Array(savedNames.dropFirst()) : nil

            processingStatus = "Fetching Apple Health context…"
            let healthMetrics = await HealthKitService.shared.getHealthMetrics()

            let combinedText = combinePageTexts(pdfTextByPage)
            processingStatus = "MedGemma is analyzing your results…"
            var report = await runInference(extractedText: combinedText, healthMetrics: healthMetrics, mode: .lab)
            report.imagePath = firstPath
            report.additionalPagePaths = extraPaths
            LocalStorageService.shared.saveReport(report)
            processingStatus = ""
            return report
        }

        // Scanned PDF (no embedded text) — go through the OCR path.
        return await analyzeImages(images)
    }

    private func renderPDFPage(_ page: PDFPage) -> UIImage {
        let bounds = page.bounds(for: .mediaBox)
        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(bounds)
            // PDF coordinate system has y up; UIKit has y down. Flip.
            ctx.cgContext.translateBy(x: 0, y: bounds.height)
            ctx.cgContext.scaleBy(x: 1.0, y: -1.0)
            page.draw(with: .mediaBox, to: ctx.cgContext)
        }
    }

    /// Joins per-page text with explicit page markers. The markers help
    /// MedGemma cite information by page when the user later asks
    /// "where was the cholesterol value?" type questions, and they
    /// disambiguate cases where the same value appears on multiple pages.
    /// Single-page input gets no marker.
    private func combinePageTexts(_ pages: [String]) -> String {
        let nonEmpty = pages.enumerated().compactMap { idx, text -> String? in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : (idx, trimmed)
        }
        guard nonEmpty.count > 1 else {
            return nonEmpty.first?.1 ?? ""
        }
        return nonEmpty.map { idx, text in "--- Page \(idx + 1) ---\n\(text)" }
            .joined(separator: "\n\n")
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

        streamingText = ""
        var collected = ""
        let stream = context.predict(prompt: prompt, maxTokens: 1000)
        for await piece in stream {
            collected += piece
            streamingText = collected
        }
        streamingText = ""

        var parsed = StructuredReport.parse(from: collected)
        if parsed.rawText.isEmpty { parsed.rawText = collected }
        return parsed
    }

    // MARK: - Follow-Up Chat

    struct ChatTurn: Sendable {
        let isUser: Bool
        let content: String
    }

    /// Streams the answer to a highlighted-text follow-up question.
    /// The caller iterates the stream and appends each piece to a chat bubble.
    /// `history` is every prior completed turn in the same chat sheet,
    /// alternating user/model starting with user. Pass `[]` for the first
    /// question. The system context (selected text, report excerpt, profile)
    /// is folded into the first user turn; subsequent turns are raw.
    func askFollowUp(
        question: String,
        history: [ChatTurn] = [],
        selectedText: String,
        reportContext: String,
        ocrText: String
    ) -> AsyncStream<String> {
        let profile = UserProfile.load()

        let systemHeader = """
        You are an empathetic medical assistant. The user has a lab report and is asking about specific text they highlighted.

        Context from their full report analysis:
        "\(String(reportContext.prefix(500)))"

        The user highlighted this specific text from their lab report:
        "\(selectedText)"

        User's medical context:
        - Conditions: \(profile.medicalConditions.isEmpty ? "None reported" : profile.medicalConditions)
        - Medications: \(profile.medications.isEmpty ? "None reported" : profile.medications)

        Provide clear, empathetic answers in 2-4 sentences. Use simple language. If the highlighted text contains a medical term, define it. If it's a lab value, explain whether it's normal and what it means.
        """

        var prompt = ""
        if let firstTurn = history.first, firstTurn.isUser {
            prompt += "<start_of_turn>user\n\(systemHeader)\n\nTheir first question: \"\(firstTurn.content)\"\n<end_of_turn>\n"
            for turn in history.dropFirst() {
                let role = turn.isUser ? "user" : "model"
                prompt += "<start_of_turn>\(role)\n\(turn.content)\n<end_of_turn>\n"
            }
            prompt += "<start_of_turn>user\n\(question)\n<end_of_turn>\n<start_of_turn>model\n"
        } else {
            prompt += "<start_of_turn>user\n\(systemHeader)\n\nTheir question: \"\(question)\"\n<end_of_turn>\n<start_of_turn>model\n"
        }

        guard let context = llamaContext else {
            let model = selectedModel
            let preview = selectedText.prefix(60)
            return AsyncStream { continuation in
                continuation.yield("MedGemma isn't loaded yet. Download \(model.displayName) in Profile to get a real answer about “\(preview)…”.")
                continuation.finish()
            }
        }

        return context.predict(prompt: prompt, maxTokens: 400)
    }
}
