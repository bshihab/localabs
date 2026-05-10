import Foundation
import UIKit
import UserNotifications
import PDFKit
import ImageIO

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
    /// 0.0–1.0 progress through the current analysis. Updated as each
    /// pipeline phase completes (OCR per page, save, Health fetch) and
    /// then incrementally during MedGemma's token-streaming phase. The
    /// UI binds a determinate ProgressView to this so the user sees an
    /// actual percentage instead of an indeterminate spinner.
    @Published var analysisProgress: Double = 0
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

    /// Flipped to true by `cancelInference()` (e.g., on app backgrounding).
    /// The streaming inference loop checks it between tokens and bails out
    /// early. Keeps llama.cpp from resuming into a Metal/GGML state that
    /// got corrupted while the app was suspended — that's what causes
    /// ggml_abort crashes on resume.
    private var isInferenceCancelled = false

    /// Set by DashboardView's Resume button to signal ScanView that it
    /// should pop back to the upload screen, kick off regenerateReport,
    /// and (when it finishes) push a fresh Dashboard with the new
    /// content. ScanView observes this via .onChange and clears it
    /// immediately after picking it up so the same report can be
    /// resumed again later if needed.
    @Published var pendingResumeReport: StructuredReport?

    private var modelURL: URL { selectedModel.localURL }

    init() {
        // Listen for the app entering the background. Any inference that
        // was running gets cancelled at the next safe checkpoint so the
        // GPU state can settle. Otherwise iOS suspending us mid-decode
        // can corrupt the Metal command buffer / KV cache, and the next
        // ggml call crashes with `ggml_abort`.
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didEnterBackgroundNotification) {
                self?.cancelInference()
            }
        }
    }

    /// Aborts any in-flight inference. Inference loops check this flag
    /// between tokens and exit cleanly — the partial output gets parsed
    /// and saved if there's enough of it, otherwise a "cancelled"
    /// placeholder is returned.
    func cancelInference() {
        isInferenceCancelled = true
    }

    /// Memory-efficient image downsampler. ImageIO's thumbnail API decodes
    /// directly to the target pixel size — the full-resolution bitmap is
    /// never allocated. For 12MP iPhone photos this drops the in-memory
    /// footprint from ~36MB per image to ~4MB per image, which is what
    /// keeps multi-photo scans from going OOM the moment MedGemma starts
    /// allocating its prompt / KV cache buffers.
    ///
    /// Use this for any image that's about to be held in memory across
    /// multiple async hops (OCR, save, inference). The 2048pt default is
    /// enough resolution for both Vision OCR and on-screen display.
    static func downsampledImage(from data: Data, maxDimension: CGFloat = 2048) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }
        let downsampleOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    func selectModel(_ model: AvailableModel) {
        guard model != selectedModel else { return }

        // Cancel any in-flight download for the model we're leaving so the
        // new selection isn't competing with a now-orphaned download task.
        cancelDownload()

        selectedModel = model
        UserDefaults.standard.set(model.rawValue, forKey: "medgemma_selected_model")
        llamaContext = nil
        isModelLoaded = false
        loadingProgress = 0
        bytesWritten = 0
        bytesExpected = 0

        // Auto-load the newly-selected model if its file is already on
        // disk. Without this, switching back to a model that was previously
        // downloaded showed the "Download" button as if it had vanished —
        // the user had to kill the app to make `loadModelIfDownloaded()`
        // run again on launch. Now we run it inline whenever the selection
        // changes, so the green "loaded & ready" badge appears as soon as
        // the model finishes loading into Metal.
        Task { await loadModelIfDownloaded() }
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
        // Reuse the shared background-session downloader. iOS requires a
        // single URLSession per background-session identifier, so this
        // can't be a per-call instance.
        let downloader = ModelDownloader.shared
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

        // Fresh run — clear any cancellation flag left over from a previous
        // backgrounding event so this analysis starts unblocked.
        isInferenceCancelled = false
        isProcessing = true
        analysisProgress = 0
        defer { isProcessing = false }

        // ── OCR every page sequentially ──
        // Sequential (not concurrent) because each Vision call already
        // allocates significant memory; running 5 in parallel against a
        // 4B model in RAM courts the same jetsam crash we just fixed.
        // Phases roughly map to fixed slices of the bar so the user sees
        // monotonic progress: OCR 0 → 0.20, save 0.22, Health 0.25, then
        // MedGemma 0.25 → 0.95, then 1.0 once the report is saved.
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
            analysisProgress = Double(idx + 1) / Double(images.count) * 0.20
        }

        let combinedText = truncateForContext(combinePageTexts(pageTexts))
        if combinedText.isEmpty {
            return StructuredReport(patientSummary: "No text was found in these pages. Please ensure the document is clearly visible and try again.")
        }

        // ── Save every page image ──
        processingStatus = "Saving scan…"
        let savedNames = images.compactMap { saveScannedImage($0) }
        let firstPath = savedNames.first
        let extraPaths = savedNames.count > 1 ? Array(savedNames.dropFirst()) : nil
        analysisProgress = 0.22

        processingStatus = "Fetching Apple Health context…"
        let healthMetrics = await HealthKitService.shared.getHealthMetrics()
        analysisProgress = 0.25

        processingStatus = "MedGemma is analyzing your results…"
        var report = await runInference(extractedText: combinedText, healthMetrics: healthMetrics, mode: .lab)
        report.imagePath = firstPath
        report.additionalPagePaths = extraPaths

        LocalStorageService.shared.saveReport(report)
        processingStatus = ""
        analysisProgress = 1.0
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
            isInferenceCancelled = false
            isProcessing = true
            analysisProgress = 0.20  // OCR is skipped for text-PDFs
            defer { isProcessing = false }

            processingStatus = "Saving PDF…"
            let savedNames = images.compactMap { saveScannedImage($0) }
            let firstPath = savedNames.first
            let extraPaths = savedNames.count > 1 ? Array(savedNames.dropFirst()) : nil
            analysisProgress = 0.22

            processingStatus = "Fetching Apple Health context…"
            let healthMetrics = await HealthKitService.shared.getHealthMetrics()
            analysisProgress = 0.25

            let combinedText = truncateForContext(combinePageTexts(pdfTextByPage))
            processingStatus = "MedGemma is analyzing your results…"
            var report = await runInference(extractedText: combinedText, healthMetrics: healthMetrics, mode: .lab)
            report.imagePath = firstPath
            report.additionalPagePaths = extraPaths
            LocalStorageService.shared.saveReport(report)
            processingStatus = ""
            analysisProgress = 1.0
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
    /// Hard cap on OCR text length so the prompt fits inside LlamaContext's
    /// 4096-token context window with margin for the system prompt + RAG
    /// context + 1000-token output budget. Empirically the system prompt
    /// + profile + Health + RAG comes to ~1000 tokens, leaving roughly
    /// 2000 tokens (~7000–8000 chars depending on tokenization density)
    /// for OCR. We use 7000 chars to give realistic medical-document
    /// tokenization a margin without truncating most multi-page scans.
    private func truncateForContext(_ raw: String) -> String {
        let maxChars = 7000
        guard raw.count > maxChars else { return raw }
        let cut = String(raw.prefix(maxChars))
        return cut + "\n\n[Note: OCR text was truncated to fit MedGemma's context window. If important details are missing, scan fewer pages or use a higher-resolution photo of the relevant section.]"
    }

    private func combinePageTexts(_ pages: [String]) -> String {
        // Plain loop — Swift's compactMap inference choked on the
        // EnumeratedSequence's named tuple element ((offset:Int, element:String))
        // when the closure tried to destructure it as `{ idx, text in }`.
        var nonEmpty: [(index: Int, text: String)] = []
        for (idx, text) in pages.enumerated() {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                nonEmpty.append((idx, trimmed))
            }
        }
        guard nonEmpty.count > 1 else {
            return nonEmpty.first?.text ?? ""
        }
        return nonEmpty
            .map { "--- Page \($0.index + 1) ---\n\($0.text)" }
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

    /// Re-runs MedGemma on a previously-saved report's raw OCR text. Used
    /// to refresh older reports against the current prompt (e.g., to give
    /// pre-markdown-prompt reports their bullet/bold/emoji formatting).
    /// Preserves the report's id, timestamp, and image paths so history
    /// stays continuous.
    func regenerateReport(from existing: StructuredReport) async -> StructuredReport {
        // Use rawText if it was saved (post-prompt-update reports), or fall
        // back to a concatenation of the legacy section bodies for very
        // old reports where rawText was empty.
        let sourceText: String
        if !existing.rawText.isEmpty {
            sourceText = existing.rawText
        } else {
            sourceText = [
                existing.patientSummary,
                existing.doctorQuestions,
                existing.dietaryAdvice,
                existing.medicalGlossary,
                existing.medicationNotes
            ].filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        guard !sourceText.isEmpty else { return existing }

        isInferenceCancelled = false
        isProcessing = true
        analysisProgress = 0.20  // OCR was already done for the saved report
        defer { isProcessing = false }

        processingStatus = "Fetching Apple Health context…"
        let healthMetrics = await HealthKitService.shared.getHealthMetrics()
        analysisProgress = 0.25

        processingStatus = "MedGemma is regenerating your report…"
        var fresh = await runInference(
            extractedText: sourceText,
            healthMetrics: healthMetrics,
            mode: .lab
        )
        // Preserve continuity with the existing record.
        fresh.id = existing.id
        fresh.timestamp = existing.timestamp
        fresh.imagePath = existing.imagePath
        fresh.additionalPagePaths = existing.additionalPagePaths

        LocalStorageService.shared.saveReport(fresh)
        processingStatus = ""
        analysisProgress = 1.0
        return fresh
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

        Provide a report with these 5 sections, each starting with the numbered header on its own line:

        1. PATIENT SUMMARY
        2. QUESTIONS FOR YOUR DOCTOR
        3. TARGETED DIETARY ADVICE
        4. MEDICAL GLOSSARY
        5. MEDICATION NOTES

        Within each section, write for a phone screen — short, scannable, easy to read. Specifically:

        - Default to bullet points, not paragraphs. Each bullet should be a single short sentence (one line on a phone). Lines starting with `- ` will render as bullets.
        - When you must use prose, keep paragraphs to 2 sentences max. No walls of text.
        - PATIENT SUMMARY in particular should be 2–4 short bullets that capture the headline findings, not a paragraph.
        - Use **bold** for lab values, drug names, medical terms, and important numbers.
        - Use *italics* sparingly, only for tone or emphasis.
        - Add emoji rarely and only when it genuinely aids comprehension (✅ normal, ⚠️ worth discussing, 💊 medications, 🥗 dietary). Max 1–2 per section. Never decorative.

        Do NOT wrap the section headers themselves in asterisks. Keep them as plain text on their own line so they parse cleanly.
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
        let maxTokens = 1000
        var tokenCount = 0
        // Surface prompt size in the Xcode console — useful for diagnosing
        // tokenize-overflow / slow-decode complaints. Approximate token
        // count assumes ~4 chars/token for English text + medical jargon.
        print("[InferenceEngine] Prompt: \(prompt.count) chars (~\(prompt.count / 4) tokens) before MedGemma run.")
        let stream = context.predict(prompt: prompt, maxTokens: maxTokens)
        for await piece in stream {
            // Bail if the user backgrounded the app, manually cancelled
            // from the toolbar, or the parent Task got cancelled. Preserve
            // the OCR text in rawText so the dashboard can offer a Resume
            // button that re-runs against the same source.
            if isInferenceCancelled || Task.isCancelled {
                streamingText = ""
                return StructuredReport(
                    patientSummary: "Analysis was interrupted. Tap Resume on the dashboard to continue.",
                    rawText: extractedText
                )
            }
            collected += piece
            streamingText = collected
            tokenCount += 1
            // Cap at 0.95 so the bar doesn't visibly hit 100% before save
            // completes — leaves the final bump for the post-loop write.
            analysisProgress = min(0.25 + Double(tokenCount) / Double(maxTokens) * 0.70, 0.95)
        }
        streamingText = ""

        // Empty output usually means llama_tokenize bailed because the
        // prompt overflowed n_ctx (multi-page scans + system prompt +
        // 1000-token output budget). Don't save a blank report — preserve
        // the OCR text so the user can retry via Resume.
        if collected.isEmpty {
            return StructuredReport(
                patientSummary: "Analysis didn't complete — your scan may be too long for MedGemma's context window. Tap Resume to retry, or use fewer pages.",
                rawText: extractedText
            )
        }

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
