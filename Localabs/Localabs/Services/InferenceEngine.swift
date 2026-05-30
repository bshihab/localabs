import Foundation
import UIKit
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
    /// then incrementally during Localabs's token-streaming phase. The
    /// UI binds a determinate ProgressView to this so the user sees an
    /// actual percentage instead of an indeterminate spinner.
    @Published var analysisProgress: Double = 0
    @Published var isDownloading = false
    @Published var downloadError: String?
    /// True when the user (or the app-backgrounded observer) paused an
    /// in-flight analysis. While true, ScanView keeps the live-cards UI
    /// on screen — frozen at the last token — so the user can resume in
    /// place instead of being shoved to a duplicate Dashboard. Flips
    /// back to false when they tap Resume or Discard.
    @Published var isPaused = false

    @Published private(set) var selectedModel: AvailableModel = {
        if let raw = UserDefaults.standard.string(forKey: "localabs_selected_model"),
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

    /// Set when a run finishes with no resumable state — the model
    /// produced zero tokens (prompt overflow, model not loaded, etc.)
    /// and Resume can't help. ScanView observes this and surfaces it
    /// as an alert so the user gets a real explanation instead of a
    /// futile Resume CTA that would just hit the same failure.
    @Published var lastHardFailureMessage: String?

    private var modelURL: URL { selectedModel.localURL }

    /// True when the app has received `didEnterBackgroundNotification`
    /// and not yet received `willEnterForegroundNotification`. Replaces
    /// the previous "check applicationState at notification time"
    /// approach, which was unreliable: applicationState reads can
    /// briefly report `.background` during transition moments even
    /// when the app is on screen, especially during long async work
    /// like multi-page OCR. Paired notifications give us an
    /// unambiguous truth flag.
    private var isAppInBackground = false

    init() {
        // Track foreground/background via paired notifications — only
        // pause inference when we're GENUINELY backgrounded (i.e.
        // received didEnterBackground and haven't gotten the matching
        // willEnterForeground yet). Single-image runs survive this
        // path fine; multi-image runs were getting falsely paused
        // because the previous applicationState-at-notification check
        // would sometimes read .background during transient race
        // windows in the OCR loop's `await` points.
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didEnterBackgroundNotification) {
                self?.handleAppDidEnterBackground()
            }
        }
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIApplication.willEnterForegroundNotification) {
                self?.handleAppWillEnterForeground()
            }
        }
    }

    private func handleAppDidEnterBackground() {
        isAppInBackground = true
        // GPU-state defense: pause any in-flight inference at the
        // next safe checkpoint. iOS suspending us mid-decode can
        // corrupt the Metal command buffer / KV cache and the next
        // ggml call crashes with `ggml_abort`. Flipping `isPaused`
        // (not just cancelling silently) gives the user a clear
        // paused-state UI to come back to.
        if isProcessing {
            cancelInference()
            isPaused = true
        }
    }

    private func handleAppWillEnterForeground() {
        // The user is bringing the app back — clear the flag so
        // subsequent stale notifications (which can fire during
        // brief lifecycle blips) don't re-pause us.
        isAppInBackground = false
    }

    /// Stops the inference loop at the next safe checkpoint. Internal —
    /// callers should use `pauseInference()` (preserves UI state for a
    /// resume) or rely on the bg-observer path. The streaming loop
    /// checks this between tokens and exits cleanly; the partial output
    /// gets parsed and saved if there's enough of it.
    private func cancelInference() {
        isInferenceCancelled = true
    }

    /// User-initiated pause. Stops the inference loop and flips the
    /// `isPaused` UI flag so ScanView keeps the live cards on screen,
    /// frozen at the last token, with a Resume button instead of an X.
    /// The partial report still gets saved to LocalStorage by the
    /// analyze path, so even if the user discards the in-memory state
    /// they could in theory still find it in History.
    func pauseInference() {
        guard isProcessing else { return }
        cancelInference()
        isPaused = true
    }


    /// Picks up the most recent paused / incomplete report and re-runs
    /// the LLM step against its saved OCR text. Mirrors the existing
    /// `regenerateReport` call path; the only difference is that this
    /// is the canonical entry point when the user is sitting on a
    /// paused ScanView and taps Resume.
    ///
    /// Returns the regenerated report so the caller (ScanView's Resume
    /// button) can route it through the same `handleAnalysisResult`
    /// flow analyzeImages/analyzePDF use — without that, a successful
    /// resume cleared `pendingResumeReport` to nil and the ScanView
    /// ZStack snapped back to the upload view, leaving the user on
    /// the main menu even though the report had saved to History.
    func resumeFromPaused() async -> StructuredReport? {
        isPaused = false
        let incomplete: StructuredReport?
        if let pending = pendingResumeReport {
            incomplete = pending
        } else {
            // Fall back to the most recent stored report if it's
            // incomplete — covers the case where the app restarted
            // between pause and resume.
            incomplete = LocalStorageService.shared.getHistory().first(where: { $0.isIncomplete })
        }
        guard let target = incomplete else { return nil }
        pendingResumeReport = nil
        // streamingText still holds whatever tokens were collected
        // before the pause — pass it through so the model continues
        // from there rather than restarting from token 0. Empty
        // string means we paused before any tokens streamed; let
        // regenerate run from scratch in that case.
        let partial = streamingText.isEmpty ? nil : streamingText
        return await regenerateReport(
            from: target,
            freshStart: false,
            continueFromPartial: partial
        )
    }

    /// Canonical delete path for a saved report. Use this instead of
    /// calling `LocalStorageService.deleteReport` directly so the
    /// engine's in-memory state and the on-disk scan images get
    /// cleaned up together. Without this, deleting a report from
    /// History left two ghosts behind:
    ///   1. `pendingResumeReport` could still point at the deleted
    ///      record — Scan tab would keep showing a Resume CTA for a
    ///      report that no longer exists in History, and tapping it
    ///      would re-create the entry on regen.
    ///   2. The JPEG page images in `Documents/scans/` were orphaned,
    ///      accumulating storage with every delete.
    /// Both are addressed here.
    func deleteReport(_ report: StructuredReport) {
        var filenames: [String] = []
        if let path = report.imagePath { filenames.append(path) }
        if let extras = report.additionalPagePaths { filenames.append(contentsOf: extras) }
        if !filenames.isEmpty {
            Self.deleteSavedScans(named: filenames)
        }
        if pendingResumeReport?.id == report.id {
            pendingResumeReport = nil
            streamingText = ""
            analysisProgress = 0
            processingStatus = ""
            isPaused = false
        }
        LocalStorageService.shared.deleteReport(id: report.id)
    }

    /// Throws away the paused analysis — clears the live-cards state,
    /// deletes the saved incomplete report from LocalStorage so it
    /// doesn't reappear on the Dashboard tab or in History, and returns
    /// ScanView to the upload state.
    func discardPausedAnalysis() {
        // Fully reset every piece of analysis state so ScanView's
        // body condition (`isProcessing || isPaused ||
        // pendingResumeReport != nil`) becomes false and the view
        // flips back to upload mode. Previous bug: after pause →
        // background → foreground → Discard, ScanView would stay on
        // the progress screen. The fix is to explicitly clear ALL
        // four resumable-state flags here, not just three, AND to
        // call objectWillChange to defeat any SwiftUI batching that
        // might be holding the prior render.
        isPaused = false
        isProcessing = false
        isInferenceCancelled = false
        streamingText = ""
        analysisProgress = 0
        processingStatus = ""
        lastHardFailureMessage = nil
        if let pending = pendingResumeReport {
            LocalStorageService.shared.deleteReport(id: pending.id)
        } else if let latest = LocalStorageService.shared.getHistory().first, latest.isIncomplete {
            LocalStorageService.shared.deleteReport(id: latest.id)
        }
        pendingResumeReport = nil
        objectWillChange.send()
    }

    /// Memory-efficient image downsampler. ImageIO's thumbnail API decodes
    /// directly to the target pixel size — the full-resolution bitmap is
    /// never allocated. For 12MP iPhone photos this drops the in-memory
    /// footprint from ~36MB per image to ~4MB per image, which is what
    /// keeps multi-photo scans from going OOM the moment Localabs starts
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
        UserDefaults.standard.set(model.rawValue, forKey: "localabs_selected_model")
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
            // The two realistic causes here are (a) corrupt/incomplete
            // model file or (b) device ran out of memory while llama.cpp
            // was loading tensors. We can't distinguish them perfectly,
            // but the user can resolve both via the trash button +
            // re-download or by closing other apps to free memory.
            print("[InferenceEngine] Failed to load model: \(error)")
            self.downloadError = "Couldn't load the model. The file may be incomplete (try Delete + Download again) or your device may be low on memory (close other apps and reopen Localabs)."
        }
    }

    /// User-triggered download of the currently selected model.
    func downloadSelectedModel() {
        guard !isDownloading else { return }
        downloadError = nil
        isDownloading = true
        setKeepScreenAwakeForDownload(true)
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
            do {
                try await downloader.download(from: model.downloadURL, to: model.localURL)
                await MainActor.run {
                    self?.isDownloading = false
                    self?.setKeepScreenAwakeForDownload(false)
                    self?.activeDownloader = nil
                }
                await self?.loadModelIfDownloaded()
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.isDownloading = false
                    self.setKeepScreenAwakeForDownload(false)
                    self.activeDownloader = nil
                    if (error as? URLError)?.code != .cancelled {
                        self.downloadError = error.localizedDescription
                    }
                }
            }
        }
    }

    /// Toggles the system idle timer while the model download is active.
    /// When on, the screen won't auto-lock — which matters because the
    /// foreground URLSession gets full bandwidth only while the app is
    /// active. The moment the screen locks (or the user backgrounds), we
    /// hand off to the throttled background session. Users staring at
    /// the progress bar would otherwise watch their screen dim and slow
    /// the download by 5-10x. iOS resets the flag automatically when the
    /// app is backgrounded, but we still flip it off explicitly on
    /// completion so we don't keep the screen awake any longer than the
    /// download needs.
    private func setKeepScreenAwakeForDownload(_ keepAwake: Bool) {
        UIApplication.shared.isIdleTimerDisabled = keepAwake
    }

    func cancelDownload() {
        activeDownloader?.cancel()
        downloadTask?.cancel()
        isDownloading = false
        setKeepScreenAwakeForDownload(false)
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

    /// Image → Apple VisionKit OCR → Localabs → StructuredReport
    /// Single-image convenience wrapper.
    func analyzeImage(_ image: UIImage) async -> StructuredReport {
        await analyzeImages([image])
    }

    /// Multi-page entry point. Runs OCR on each image (or PDF page rendered
    /// to image), concatenates the extracted text with page markers so
    /// Localabs can reason about page boundaries, saves every image, and
    /// returns a single StructuredReport with `imagePath` = page 1 and
    /// `additionalPagePaths` = pages 2…N.
    func analyzeImages(_ images: [UIImage]) async -> StructuredReport {
        guard !images.isEmpty else {
            return StructuredReport(patientSummary: "No pages were provided.")
        }

        // Fresh run — clear any cancellation flag left over from a previous
        // backgrounding event so this analysis starts unblocked. Also wipe
        // streamingText and any prior hard-failure message so stale state
        // from a previous run can't be mistaken for resumable partial output
        // (which would mis-trigger the Resume CTA on the next hard failure).
        isInferenceCancelled = false
        isProcessing = true
        analysisProgress = 0
        streamingText = ""
        lastHardFailureMessage = nil
        defer { isProcessing = false }

        // ── OCR every page sequentially ──
        // Sequential (not concurrent) because each Vision call already
        // allocates significant memory; running 5 in parallel against a
        // 4B model in RAM courts the same jetsam crash we just fixed.
        // Phases roughly map to fixed slices of the bar so the user sees
        // monotonic progress: OCR 0 → 0.20, save 0.22, Health 0.25, then
        // Localabs 0.25 → 0.95, then 1.0 once the report is saved.
        var pageTexts: [String] = []
        for (idx, image) in images.enumerated() {
            processingStatus = images.count == 1
                ? "Scanning…"
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

        // ── Reject non-lab content BEFORE saving images or running inference ──
        // The heuristic short-circuits anything that doesn't look like
        // a lab report (random photos, screenshots of non-medical
        // apps, etc.) so we don't (a) burn 30s of inference for nothing
        // and (b) hand the model a context where it would fabricate
        // findings from prior reports in RAG. ScanView watches the
        // resulting marker and shows the "No health content detected"
        // popup instead of routing into DashboardView.
        if !Self.looksLikeMedicalDocument(combinedText) {
            analysisProgress = 0
            processingStatus = ""
            return Self.makeNonHealthRejectionReport(rawText: combinedText)
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

        processingStatus = "Localabs is analyzing your results…"
        var report = await runInference(extractedText: combinedText, healthMetrics: healthMetrics, mode: .lab)
        report.imagePath = firstPath
        report.additionalPagePaths = extraPaths

        // Mid-stream rejection: the model started generating but
        // realized this scan has no analyzable lab content. Clean up
        // the page images we'd already saved to disk (the heuristic
        // had passed, so we'd committed to saving) and return a
        // pageless rejection report — ScanView will show the alert
        // popup. We don't persist this to history and don't park it
        // in pendingResumeReport, since there's nothing to resume.
        if report.wasRejectedAsNonHealth {
            Self.deleteSavedScans(named: savedNames)
            report.imagePath = nil
            report.additionalPagePaths = nil
            analysisProgress = 0
            processingStatus = ""
            return report
        }

        // Only persist a report that actually finished. Three things
        // must hold:
        //   - the run wasn't cancelled (pause / background)
        //   - all 5 sections came through (no maxTokens truncation)
        //   - it isn't the non-health rejection sentinel
        // The previous gate only checked isInferenceCancelled, so a
        // multi-page run that hit the output-token cap mid-section
        // would still get saved as a half-empty "completed" report.
        // That was the bug behind "I scan 3 medical records, it
        // returns me to the upload screen but the scan is in history."
        //
        // Distinguish "resumable partial state" (mid-stream cancel OR
        // truncation with streamed tokens to continue from) from "hard
        // failure" (model produced zero tokens — prompt overflow, model
        // never loaded, etc.). Only resumable cases park a
        // pendingResumeReport; hard failures surface as a one-shot alert
        // via lastHardFailureMessage and clean up their orphan scans so
        // the same images don't accumulate on disk.
        let hasResumableState = isInferenceCancelled || !streamingText.isEmpty
        let isHardFailure = report.isIncomplete && !hasResumableState
        if !isInferenceCancelled && !report.isIncomplete && !report.wasRejectedAsNonHealth {
            // Extract structured lab values + the report's own date
            // for cross-report trends (#28) before persisting — only
            // for finished reports. The date orders trends by when the
            // bloodwork was done, not when it was scanned.
            report.labValues = await extractLabValues(from: combinedText)
            report.reportDate = Self.extractReportDate(from: combinedText)
            LocalStorageService.shared.saveReport(report)
        }
        if (isInferenceCancelled || report.isIncomplete) && hasResumableState {
            pendingResumeReport = report
        }
        if isHardFailure {
            Self.deleteSavedScans(named: savedNames)
            report.imagePath = nil
            report.additionalPagePaths = nil
            lastHardFailureMessage = report.patientSummary
            analysisProgress = 0
        }
        processingStatus = ""
        if !report.isIncomplete { analysisProgress = 1.0 }
        return report
    }

    /// Picks up a PDF, renders each page to an image, extracts text (using
    /// the embedded PDF text where available, falling back to Vision OCR
    /// per page), and runs the same Localabs pipeline as `analyzeImages`.
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
            streamingText = ""
            lastHardFailureMessage = nil
            defer { isProcessing = false }

            // Same non-health rejection gate as analyzeImages, applied
            // here BEFORE we save page images. Catches PDFs of code,
            // receipts, etc. that happen to have embedded text but
            // nothing medical to analyze.
            let combinedText = truncateForContext(combinePageTexts(pdfTextByPage))
            if !Self.looksLikeMedicalDocument(combinedText) {
                analysisProgress = 0
                processingStatus = ""
                return Self.makeNonHealthRejectionReport(rawText: combinedText)
            }

            processingStatus = "Saving PDF…"
            let savedNames = images.compactMap { saveScannedImage($0) }
            let firstPath = savedNames.first
            let extraPaths = savedNames.count > 1 ? Array(savedNames.dropFirst()) : nil
            analysisProgress = 0.22

            processingStatus = "Fetching Apple Health context…"
            let healthMetrics = await HealthKitService.shared.getHealthMetrics()
            analysisProgress = 0.25

            processingStatus = "Localabs is analyzing your results…"
            var report = await runInference(extractedText: combinedText, healthMetrics: healthMetrics, mode: .lab)
            report.imagePath = firstPath
            report.additionalPagePaths = extraPaths

            // Mid-stream rejection cleanup (mirror of analyzeImages):
            // ditch the saved PDF page images and don't persist /
            // park the rejection report.
            if report.wasRejectedAsNonHealth {
                Self.deleteSavedScans(named: savedNames)
                report.imagePath = nil
                report.additionalPagePaths = nil
                analysisProgress = 0
                processingStatus = ""
                return report
            }

            // Same triple-gate as analyzeImages: skip persistence for
            // any run that didn't make it to all 5 sections, so a
            // truncated multi-page PDF doesn't end up in History.
            // Resumable-state distinction mirrors analyzeImages — see
            // its comment for the full rationale.
            let hasResumableState = isInferenceCancelled || !streamingText.isEmpty
            let isHardFailure = report.isIncomplete && !hasResumableState
            if !isInferenceCancelled && !report.isIncomplete && !report.wasRejectedAsNonHealth {
                report.labValues = await extractLabValues(from: combinedText)
                report.reportDate = Self.extractReportDate(from: combinedText)
                LocalStorageService.shared.saveReport(report)
            }
            if (isInferenceCancelled || report.isIncomplete) && hasResumableState {
                pendingResumeReport = report
            }
            if isHardFailure {
                Self.deleteSavedScans(named: savedNames)
                report.imagePath = nil
                report.additionalPagePaths = nil
                lastHardFailureMessage = report.patientSummary
                analysisProgress = 0
            }
            processingStatus = ""
            if !report.isIncomplete { analysisProgress = 1.0 }
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
    /// Localabs cite information by page when the user later asks
    /// "where was the cholesterol value?" type questions, and they
    /// disambiguate cases where the same value appears on multiple pages.
    /// Single-page input gets no marker.
    /// Hard cap on OCR text length so the prompt fits inside LlamaContext's
    /// context window with margin for the system prompt + output budget.
    ///
    /// Token accounting (rough, 1 token ≈ 3 chars for medical text), now
    /// sized against n_ctx=6144:
    ///   behavior + section instructions + Health + Profile ≈ 1250 tokens
    ///   OCR @ 5000 chars                                    ≈ 1670 tokens
    ///   output budget (`maxTokens` in runInference)         ≈ 1800 tokens
    ///   ────────────────────────────────────────────────────────────────
    ///   total                                               ≈ 4720 tokens
    /// Leaves ~1400 tokens of headroom — enough for the model to comfortably
    /// finish all 5 sections (the 1300-token output budget that came before
    /// was triggering MEDICATION NOTES truncation, which marked the report
    /// `isIncomplete` and stranded the user on the Resume CTA).
    private func truncateForContext(_ raw: String) -> String {
        let maxChars = 5000
        guard raw.count > maxChars else { return raw }
        let cut = String(raw.prefix(maxChars))
        return cut + "\n\n[Note: OCR text was truncated to fit Localabs's context window. If important details are missing, scan fewer pages or use a higher-resolution photo of the relevant section.]"
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
        // Inline `[Page N]` markers (instead of the previous
        // `--- Page N ---` divider blocks). The dashed dividers
        // were reading like document separators to the model — it
        // would emit a complete 5-section analysis for page 1,
        // then on hitting the next divider restart with a fresh
        // PATIENT SUMMARY for page 2, and the parser would
        // overwrite earlier sections with later ones. Quieter
        // inline markers preserve citation ability without looking
        // like "new document starts here."
        return nonEmpty
            .map { "[Page \($0.index + 1)]\n\($0.text)" }
            .joined(separator: "\n\n")
    }

    /// Removes a set of page images we'd already committed to disk
    /// during analyzeImages / analyzePDF before the mid-stream
    /// refusal kicked in. Without this, every false-positive heuristic
    /// pass that the model then rejects would leave orphan JPEGs in
    /// `Documents/scans/` that nothing references.
    static func deleteSavedScans(named filenames: [String]) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let scansDir = docs.appendingPathComponent("scans")
        for name in filenames {
            try? FileManager.default.removeItem(at: scansDir.appendingPathComponent(name))
        }
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

    /// Re-runs Localabs on a previously-saved report's raw OCR text. Used
    /// to refresh older reports against the current prompt (e.g., to give
    /// pre-markdown-prompt reports their bullet/bold/emoji formatting).
    /// Preserves the report's id, timestamp, and image paths so history
    /// stays continuous.
    /// `freshStart: true` (the default — user tapped Regenerate on
    /// Dashboard) resets analysisProgress to 0 so the bar fills from
    /// empty. `freshStart: false` (resume-from-pause via
    /// resumeFromPaused) keeps the prior position so the bar doesn't
    /// visibly walk backwards while the new run ramps up.
    ///
    /// `continueFromPartial`, when non-nil, threads the partial LLM
    /// output the user paused mid-stream into the prompt so the model
    /// continues from there rather than re-emitting the same opening
    /// tokens. Currently used only by the resume-from-pause path.
    func regenerateReport(from existing: StructuredReport, freshStart: Bool = true, continueFromPartial: String? = nil) async -> StructuredReport {
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
        lastHardFailureMessage = nil
        // Fresh regens (from the Dashboard CTA) zero the bar so it
        // visibly fills from 0%. Without this, a previous completed
        // run leaves analysisProgress at 1.0 and the max() lines
        // below pin it there for the whole regen — bar shows 100%
        // from the start.
        if freshStart {
            analysisProgress = 0
            streamingText = ""
        }
        analysisProgress = max(analysisProgress, 0.20)
        defer { isProcessing = false }

        processingStatus = "Fetching Apple Health context…"
        let healthMetrics = await HealthKitService.shared.getHealthMetrics()
        analysisProgress = max(analysisProgress, 0.25)

        processingStatus = "Localabs is regenerating your report…"
        var fresh = await runInference(
            extractedText: sourceText,
            healthMetrics: healthMetrics,
            mode: .lab,
            continueFromPartial: continueFromPartial
        )
        // Preserve continuity with the existing record.
        fresh.id = existing.id
        fresh.timestamp = existing.timestamp
        fresh.imagePath = existing.imagePath
        fresh.additionalPagePaths = existing.additionalPagePaths

        // Resumable-state distinction (see analyzeImages for the full
        // rationale). For regen the save condition was previously just
        // `!isInferenceCancelled`, which would happily overwrite a
        // good existing report with a hard-failure shell. The
        // `!isHardFailure` clause preserves the prior stored copy when
        // the retry produces zero tokens.
        let hasResumableState = isInferenceCancelled || !streamingText.isEmpty
        let isHardFailure = fresh.isIncomplete && !hasResumableState
        if !isInferenceCancelled && !isHardFailure {
            LocalStorageService.shared.saveReport(fresh)
        }
        if (isInferenceCancelled || fresh.isIncomplete) && hasResumableState {
            pendingResumeReport = fresh
        }
        if isHardFailure {
            lastHardFailureMessage = fresh.patientSummary
            analysisProgress = 0
        }
        processingStatus = ""
        if !fresh.isIncomplete { analysisProgress = 1.0 }
        return fresh
    }

    /// Apple Health-only weekly review (no scan).
    func generateWeeklyReview() async -> StructuredReport {
        isProcessing = true
        defer { isProcessing = false }

        processingStatus = "Reading Apple Health data…"
        let healthMetrics = await HealthKitService.shared.getHealthMetrics()

        processingStatus = "Localabs is reviewing your week…"
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

    /// Cheap, fully-deterministic pre-flight: does the OCR text look
    /// like a medical document worth handing to the model? Accepts
    /// EITHER a lab report (lab values + units + reference ranges)
    /// OR a clinical encounter note (chief complaint, diagnosis,
    /// plan, ICD-10, etc.). Rejects truly non-medical content
    /// (random photos, app screenshots, recipes) so the model isn't
    /// asked to invent findings from nothing.
    ///
    /// Previous version rejected clinical notes outright as a
    /// hallucination defense, but that broke the dermatology-PDF
    /// use case the user actually has. The fabrication defense now
    /// lives in the prompt (explicit "never fabricate", explicit
    /// "orders are not results", explicit "focus on the diagnosis
    /// not the vitals"), which lets this gate be permissive.
    private static func looksLikeMedicalDocument(_ text: String) -> Bool {
        let lowered = text.lowercased()

        // Lab units. "mmHg" and "cells/mm" used to be in here but
        // they're vitals/cytology indicators that appear in clinical
        // notes too — kept them out so a clinical note's BP reading
        // doesn't single-handedly trip the gate.
        let labUnits = [
            "mg/dl", "mmol/l", "ng/ml", "meq/l", "pg/ml", "iu/l", "u/l",
            "miu/l", "g/dl", "mg/l", "ng/dl", "miu/ml", "mcg/dl", "μg/dl",
            "10^3", "10^9", "10^6", "k/ul", "k/μl", "/μl",
            "x10^", "fl/cell"
        ]
        let unitHits = labUnits.reduce(0) { $0 + (lowered.contains($1) ? 1 : 0) }

        // Lab-specific vocabulary. Two or more hits combined ≈ "this
        // page is talking about labs even without a unit string."
        let labTerms = [
            "reference range", "normal range", "lab result", "test result",
            "specimen", "ordering provider", "ordering physician",
            "collection date", "report date", "lab id", "mrn",
            "lipid panel", "cholesterol", "hdl", "ldl", "triglycerides",
            "glucose", "hemoglobin", "hba1c", "a1c", "creatinine", "bun",
            "sodium", "potassium", "chloride", "calcium", "magnesium",
            "phosphate", "vitamin d", "vitamin b12", "ferritin", "iron",
            "thyroid", "tsh", "t3", "t4", "white blood cell", "red blood cell",
            "platelet", "wbc", "rbc", "albumin", "bilirubin",
            "alkaline phosphatase", "alt", "ast",
            "psa", "estradiol", "testosterone", "cortisol", "insulin",
            "c-reactive", "crp", "esr", "complete blood count",
            "cbc", "metabolic panel", "lab report", "blood test",
            "urinalysis", "biopsy", "pathology"
        ]
        let termHits = labTerms.reduce(0) { $0 + (lowered.contains($1) ? 1 : 0) }

        // Numeric-range-with-unit patterns ("100-200 mg/dL", "<200
        // mg/dL", ">=240 mg/dL"). Lab reference ranges almost always
        // print like this, while general-purpose text almost never
        // does.
        let rangePattern = #"(?i)(\d+\s*-\s*\d+|<\s*\d+|>=?\s*\d+)\s*(mg|mmol|ng|meq|pg|iu|u|g|mcg)"#
        let rangeHits: Int = {
            guard let regex = try? NSRegularExpression(pattern: rangePattern) else { return 0 }
            let nsRange = NSRange(text.startIndex..., in: text)
            return regex.numberOfMatches(in: text, range: nsRange)
        }()

        // Clinical-note signals — encounter-note markers indicate the
        // doc is a visit summary / referral / progress note. ACCEPT
        // these now (the prompt handles them safely with explicit
        // anti-fabrication + anti-vitals-lead rules); they used to
        // bounce out, which broke the dermatology-PDF use case.
        let clinicalNoteMarkers = [
            "chief complaint", "history of present illness", "(hpi)",
            "review of systems", "(ros)", "physical examination",
            "assessment and plan", "icd-10", "icd 10",
            "electronically signed", "encounter type",
            "attending provider", "clinical encounter",
            "past medical history", "social history",
            "labs ordered", "laboratory orders placed",
            "follow-up:", "follow up in",
            "diagnosis:", "impression:",
        ]
        let clinicalNoteHits = clinicalNoteMarkers.reduce(0) { $0 + (lowered.contains($1) ? 1 : 0) }

        // Accept if EITHER lab-report signals land OR clinical-note
        // signals land (2+ markers — single markers are too noisy).
        // Below all of those is genuinely non-medical content
        // (screenshots, recipes, random photos), which is refused.
        let isLabReport = rangeHits >= 1 || unitHits >= 2 || termHits >= 2
        let isClinicalNote = clinicalNoteHits >= 2
        return isLabReport || isClinicalNote
    }

    /// Exact phrase the analysis prompt instructs the model to emit
    /// when the OCR text doesn't actually contain analyzable lab
    /// content. Anchored on the leading ⚠️ + "This image" so it
    /// can't false-match a real multi-page analysis that happens to
    /// say something like "the second page doesn't appear to contain
    /// lab values for triglycerides…" — the model rarely emits ⚠️
    /// unprompted, which makes this snippet effectively unique to
    /// our refusal output.
    static let midStreamRefusalSnippet = "⚠️ This image doesn't appear to contain lab report content"

    /// Builds the canonical "we refused this scan" report. The first
    /// line carries `nonHealthRejectionMarker` (invisible to the user
    /// once ScanView swallows it), followed by a human-readable
    /// explanation that's shown in the popup body. Centralizing this
    /// here means every code path that detects a non-lab scan produces
    /// an identically-shaped report, so the UI's marker check works
    /// the same regardless of which entry point caught it.
    static func makeNonHealthRejectionReport(rawText: String) -> StructuredReport {
        let body = """
        Localabs couldn't find any medical content in this scan — no lab values, no clinical findings, no diagnosis. To prevent invented results, the analysis was stopped.

        Try again with a printed lab result (e.g. "180 mg/dL — normal range 100–200") or a clinical note (visit summary with chief complaint, diagnosis, plan).
        """
        return StructuredReport(
            patientSummary: "\(StructuredReport.nonHealthRejectionMarker)\n\(body)",
            rawText: rawText
        )
    }

    /// `continueFromPartial`, when non-nil, primes the prompt with
    /// the partial model output the user paused mid-stream. The
    /// model picks up generating tokens *after* the partial instead
    /// of restarting from scratch — that's what makes Resume feel
    /// like continuation rather than a fresh re-run.
    private func runInference(extractedText: String, healthMetrics: HealthKitService.HealthMetrics, mode: AnalysisMode, continueFromPartial: String? = nil) async -> StructuredReport {
        // Belt-and-suspenders: analyzeImages / analyzePDF already
        // gate the heuristic and bail before invoking runInference,
        // but if anything ever calls runInference directly with a
        // non-lab text (and we're in lab mode), produce the same
        // rejection shape ScanView knows how to handle.
        if mode == .lab, !Self.looksLikeMedicalDocument(extractedText) {
            return Self.makeNonHealthRejectionReport(rawText: extractedText)
        }

        let profile = UserProfile.load()
        // Past-report RAG context is deliberately NOT included in the
        // analysis prompt. The lab-report translation is supposed to
        // be a translation of THIS document and only this document —
        // letting prior scans bleed in here is what was producing
        // "your cholesterol is..." text when the current OCR was
        // partially unreadable. Profile demographics + recent Health
        // averages are kept because they're THE USER (not a separate
        // document) and they personalize phrasing without supplying
        // substitutable lab values.

        let behaviorPrompt = mode == .weekly
            ? "The user is requesting their weekly health check-in review. Analyze their Apple Health data provided below."
            : """
            The user just scanned a medical document. The text below was extracted using Apple's VisionKit OCR. The document could be:
            (a) A LAB REPORT — has lab values with units (mg/dL, mmol/L, ng/mL, etc.) accompanied by reference ranges.
            (b) A CLINICAL ENCOUNTER NOTE — visit summary with chief complaint, diagnosis (often ICD-10 coded), assessment, treatment plan, follow-up. May list labs that the doctor ORDERED for the future but typically does NOT contain lab result values.
            (c) A combination of both.

            FIRST identify which it is from the OCR content, then summarize what THIS document says.

            CRITICAL RULES BEFORE YOU ANSWER:
            - MULTI-PAGE SCANS ARE ONE DOCUMENT. The OCR text may contain `[Page 1]`, `[Page 2]`, etc. markers — these are just page boundaries inside the SAME report. Produce ONE cohesive 5-section analysis covering ALL pages together. Do NOT restart PATIENT SUMMARY when you reach the next page marker. Treat the whole stream as one document; values on page 2 + page 3 belong in the same sections as page 1.
            - Your ENTIRE analysis is about THE OCR TEXT below and only that text. You have NO access to prior reports, prior chats, conversation history, or anything outside this single document. Do not say "consistent with your earlier panel," do not carry numbers or diagnoses from anywhere else. If a fact isn't in the OCR text, it doesn't exist for this analysis.
            - NEVER FABRICATE. Every numeric value and every diagnosis you cite must appear verbatim, character-for-character, in the OCR text above. If you cannot point to the exact characters in the OCR, do not write it. NEVER copy any specific value, lab name, drug name, or diagnosis name from THIS instruction text into your output — the examples below are abstract placeholders to teach you the SHAPE of the document, not content to reproduce. If the OCR doesn't contain a specific number or diagnosis, omit it. Do not pad with fabricated specifics.
            - DISTINGUISH ORDERS FROM RESULTS. Clinical notes routinely list labs the doctor ORDERED (phrasing like "Laboratory orders placed today:" followed by a list of test acronyms). Orders are NOT results — do not pretend the test came back with a value. Reference the orders only as part of the PLAN, not as findings.
            - FOCUS ON THE DOCUMENT'S PRIMARY SUBJECT. For a clinical note, that's the chief diagnosis (with its ICD-10 code if present) and the clinical decision/treatment plan. For a lab report, that's the abnormal LAB VALUES. Vitals (BP, HR, BMI, RR, Temp, SpO2, weight, height) are background context — do NOT lead with them, do NOT make them the main subject of PATIENT SUMMARY. Only mention vitals if they're clinically abnormal AND directly relevant to the document's primary subject.
            - The "Reference-Only User Context" block (further down) exists ONLY to help you pick appropriate reference ranges. DO NOT restate any value from that block in your output, do NOT use Apple Health metrics or profile fields AS FINDINGS, and never make them the subject of a bullet. The user already knows their own age, sex, blood type, medications, family history, and Health averages.
            - If the OCR text is empty, partially unreadable, or doesn't contain any medical content at all, your VERY FIRST line of PATIENT SUMMARY must be exactly: "\(Self.midStreamRefusalSnippet) I can analyze. Please retake with a printed lab result or clinical note." Then STOP — do not write anything else, do not fill the other sections. The app watches for that exact phrase (including the ⚠️) and will halt generation when it sees it.
            - REFUSAL PHRASING IS ONLY FOR THE WHOLE-IMAGE-EMPTY CASE. Never use phrases like "this image doesn't appear to contain", "no lab report content", "cannot analyze this image", "not enough medical data", or any variation, INSIDE any of the 5 sections. If a SPECIFIC section has nothing to populate (e.g. MEDICATION NOTES on a report that lists no medications), write a single short, neutral bullet describing the absence — for example "- No medications are listed in this report." or "- No specialized terms in this report needed defining."
            - If the OCR is partially legible, analyze only what IS legible and explicitly note in PATIENT SUMMARY which fields were unreadable. Never paper over unreadable values with plausible-sounding text.
            """

        let prompt = """
        <start_of_turn>user
        You are an empathetic, highly trained medical assistant.
        \(behaviorPrompt)

        ╔══ Medical Document OCR Text (the ONLY content to analyze) ══╗
        "\(extractedText)"
        ╚════════════════════════════════════════════════════════════╝

        Reference-Only User Context (use SILENTLY to pick appropriate reference ranges. NEVER quote, restate, or make any of these values a finding in your output.):
        \(profile.promptContextBullets)
        - Resting HR (30-day avg): \(healthMetrics.avgRestingHR.map { "\($0) bpm" } ?? "Unknown")
        - Sleep (30-day avg): \(healthMetrics.avgSleepHours.map { "\($0) hours" } ?? "Unknown")
        - HRV (30-day avg): \(healthMetrics.avgHRV.map { "\($0) ms" } ?? "Unknown")
        - Daily steps (30-day avg): \(healthMetrics.avgSteps.map { String(format: "%.0f", $0) } ?? "Unknown")
        - Daily walking/running distance (30-day avg): \(healthMetrics.avgWalkingDistanceMiles.map { String(format: "%.2f mi", $0) } ?? "Unknown")
        - Walking speed (30-day avg): \(healthMetrics.avgWalkingSpeedMPH.map { String(format: "%.2f mph", $0) } ?? "Unknown")
        - Daily exercise minutes (30-day avg): \(healthMetrics.avgExerciseMinutes.map { String(format: "%.0f min", $0) } ?? "Unknown")

        Provide the 5 sections, each starting with the numbered header on its own line:

        1. PATIENT SUMMARY
        2. QUESTIONS FOR YOUR DOCTOR
        3. TARGETED DIETARY ADVICE
        4. MEDICAL GLOSSARY
        5. MEDICATION NOTES

        Within each section, write for a phone screen — short, scannable, easy to read. Specifically:

        - Default to bullet points, not paragraphs. Each bullet should be a single short sentence (one line on a phone). Lines starting with `- ` will render as bullets.
        - When you must use prose, keep paragraphs to 2 sentences max. No walls of text.
        - PATIENT SUMMARY is a SUMMARY OF THE DOCUMENT — 2 to 4 short bullets, each citing a specific finding pulled from the OCR text. Lead with the most clinically significant content the document is PRIMARILY about (the diagnosis for a clinical note, the most abnormal lab value for a lab report). NEVER lead with vitals.

          HARD RULE: every PATIENT SUMMARY bullet MUST reference a specific finding from the OCR — a diagnosis, a lab value with units, a clinical finding from the physical exam, or a treatment from the plan. Bullets that just describe vitals (BP, HR, BMI, Temp) or restate Reference-Only User Context are INVALID — rewrite them.

          The templates below show the SHAPE of acceptable bullets — they are NOT content for you to copy. Replace every bracketed placeholder with the corresponding text from the OCR.

          ALLOWED SHAPES for a CLINICAL NOTE (each leads with the actual subject of THIS document, pulled from the OCR):
          - Diagnosis: **[the diagnosis as written in the OCR, with ICD-10 code if present]**, [one-line plain-language definition].
          - [Clinical detail describing onset, duration, or progression as stated in the OCR].
          - [Relevant comorbidity or family history detail if the OCR mentions it].
          - Plan: [the treatment/medication/follow-up steps the OCR lists].

          ALLOWED SHAPES for a LAB REPORT (each cites a specific lab value verbatim from the OCR):
          - **[Lab name as written in OCR]** is [elevated/low/normal] at **[value] [unit]** vs. normal range [range from OCR].
          - All [grouping] markers ([list of lab names from OCR]) are within reference range.
          - **[Lab name]** is [direction] at **[value] [unit]** — [brief, factual implication].

          FORBIDDEN PATTERNS — never produce a bullet that:
          - Uses any bracketed placeholder name, lab name, drug name, or diagnosis from the SHAPE templates above as if it were a real OCR finding. (Placeholders are the SHAPE, not the answer.)
          - Cites a specific lab value (number + unit) that does not appear verbatim in the OCR text. If you cannot point to the exact characters in the OCR, omit the value.
          - Leads with vitals (BP, HR, BMI, Temp, SpO2, RR) as the main subject.
          - Restates the Reference-Only User Context (age, sex, blood type, Apple Health metrics) as a finding.
          - Refers to prior reports, prior visits, or earlier scans (you have no access to anything outside the OCR text).
        - Use **bold** for lab values, drug names, medical terms, and important numbers.
        - Use *italics* sparingly, only for tone or emphasis.
        - Add emoji rarely and only when it genuinely aids comprehension (✅ normal, ⚠️ worth discussing, 💊 medications, 🥗 dietary). Max 1–2 per section. Never decorative.

        Section-budgeting: keep each of the 5 sections to roughly 3–5 bullets, ~80–120 words. Do NOT spend most of your output on the first 1–2 sections and rush the rest. MEDICATION NOTES in particular: if the report mentions medications, list each one with timing/dose; if the report genuinely has no medication info, say so in a single short bullet — do not pad. Reserve enough budget that every section gets equal treatment.

        Do NOT wrap the section headers themselves in asterisks. Keep them as plain text on their own line so they parse cleanly.
        <end_of_turn>
        <start_of_turn>model
        """

        guard let context = llamaContext else {
            return StructuredReport(
                patientSummary: "Localabs is not loaded. Open Profile and download \(selectedModel.displayName) (\(selectedModel.humanSize)) to enable on-device analysis.",
                rawText: extractedText
            )
        }

        // Resume-from-pause path: append the partial response the
        // model produced before being interrupted so it continues
        // generating where it left off instead of starting over. The
        // model treats the prompt as everything-so-far and emits the
        // *next* token from there. The streamed UI keeps the partial
        // text visible during the continuation, so the user sees one
        // smooth stream rather than the cards resetting.
        let promptWithPartial: String
        var collected: String
        if let partial = continueFromPartial, !partial.isEmpty {
            promptWithPartial = prompt + partial
            collected = partial
            streamingText = partial
        } else {
            promptWithPartial = prompt
            collected = ""
            streamingText = ""
        }
        // Output ceiling. Sized so MEDICATION NOTES gets adequate
        // room even on dense multi-page reports — the model tended
        // to over-spend tokens on PATIENT SUMMARY / DIETARY ADVICE
        // and arrive at MEDICATION NOTES with only a sentence or
        // two of budget left (or never reach it at all), ending
        // generation with that section empty. That tripped
        // StructuredReport.isIncomplete and stranded the user on
        // the Resume CTA instead of pushing into Dashboard.
        //
        // 1800 paired with n_ctx=6144 leaves comfortable headroom
        // for all 5 sections (5 × ~120 words ≈ 800 tokens of
        // content + 5 headers + the title line). Model still
        // terminates at end-of-turn, so light reports don't pay
        // any latency for the bigger ceiling.
        let maxTokens = 1800
        var tokenCount = 0
        // Surface prompt size in the Xcode console — useful for diagnosing
        // tokenize-overflow / slow-decode complaints. Approximate token
        // count assumes ~4 chars/token for English text + medical jargon.
        print("[InferenceEngine] Prompt: \(promptWithPartial.count) chars (~\(promptWithPartial.count / 4) tokens) before Localabs run.")
        let stream = context.predict(prompt: promptWithPartial, maxTokens: maxTokens)
        for await piece in stream {
            // Bail if the user paused (or the app got backgrounded /
            // parent Task cancelled). Keep `streamingText` populated so
            // ScanView's paused state can show whatever sections had
            // streamed in already; preserve OCR text in rawText so the
            // Resume button can re-run against the same source.
            if isInferenceCancelled || Task.isCancelled {
                var partial = StructuredReport.parse(from: collected)
                partial.rawText = extractedText
                if partial.patientSummary.isEmpty {
                    partial.patientSummary = "Paused before any analysis was generated. Tap Resume to start the analysis."
                }
                return partial
            }
            collected += piece
            streamingText = collected
            tokenCount += 1

            // Early-stop: the heuristic passed (or wouldn't have run)
            // and we started generating, but the model has decided it
            // can't actually analyze this scan. Bail before it burns
            // another 25s filling sections with hedged guesses.
            // Window guard: only check during the first PATIENT
            // SUMMARY phase. After ~120 tokens the model is well into
            // a real analysis and the phrase wouldn't legitimately
            // appear, so we stop wasting CPU on the contains() check.
            if mode == .lab,
               tokenCount < 120,
               collected.contains(Self.midStreamRefusalSnippet) {
                streamingText = ""
                analysisProgress = 0
                processingStatus = ""
                return Self.makeNonHealthRejectionReport(rawText: extractedText)
            }

            // Cap at 0.95 so the bar doesn't visibly hit 100% before save
            // completes — leaves the final bump for the post-loop write.
            // Also clamp with max() against the current progress so a
            // resume-from-pause doesn't visibly walk the bar backwards:
            // the new run restarts the LLM from token 0, but the bar
            // stays at the user's prior position until streaming
            // catches up.
            let proposed = min(0.25 + Double(tokenCount) / Double(maxTokens) * 0.70, 0.95)
            analysisProgress = max(analysisProgress, proposed)
        }

        // Empty output usually means llama_tokenize bailed because the
        // prompt overflowed n_ctx (multi-page scans + system prompt +
        // output budget). Don't save a blank report — preserve the OCR
        // text and let the caller route this to an error alert via
        // lastHardFailureMessage. The copy intentionally avoids
        // suggesting "Resume" because hard failures route around the
        // Resume CTA — re-running the same prompt would just hit the
        // same overflow.
        if collected.isEmpty {
            return StructuredReport(
                patientSummary: "Analysis didn't complete — your scan may be too long for Localabs's context window. Try again with fewer pages, or use a higher-resolution photo of just the section you care about.",
                rawText: extractedText
            )
        }

        var parsed = StructuredReport.parse(from: collected)
        if parsed.rawText.isEmpty { parsed.rawText = collected }
        return parsed
    }

    // MARK: - Lab-value extraction (#28)

    /// Pulls structured lab measurements out of OCR text via a focused,
    /// strict-format model pass — separate from the user-facing
    /// analysis so neither prompt pollutes the other. Returns the
    /// values for cross-report trend comparison. Runs only for
    /// completed reports (the caller gates on that), so it adds a
    /// second short generation only on successful scans.
    ///
    /// The model emits pipe-delimited lines (NAME | VALUE | UNIT |
    /// RANGE) — far more reliable from a 4B model than JSON. We parse
    /// defensively and drop any line we can't read as a number, so a
    /// malformed line never produces a bogus value (the cardinal rule:
    /// never fabricate a measurement the report doesn't contain).
    func extractLabValues(from ocrText: String) async -> [LabValue] {
        guard let context = llamaContext else { return [] }
        let trimmed = String(ocrText.prefix(3000))  // leave room for output
        guard !trimmed.isEmpty else { return [] }

        // PASS 1 — transcription only. Copy name/value/unit and the
        // reference range IF the report prints one (empty otherwise).
        // Deliberately does NOT ask the model to fill in ranges or judge
        // direction: a 4B model conflates "extract" with "skip rows I
        // can't fully complete", and was dropping rangeless rows (e.g.
        // HDL with no printed range). Pure transcription keeps every row.
        let prompt = """
        <start_of_turn>user
        You are a precise data extractor. From the lab report text below, list EVERY lab measurement that has a numeric value. Output ONE per line in EXACTLY this pipe-delimited format and nothing else:
        NAME | VALUE | UNIT | RANGE

        Rules:
        - Copy the test name, number, unit, and the report's reference range EXACTLY as written. NEVER invent a value.
        - If the unit or range is not printed for a row, leave that field EMPTY but keep the pipes — still output the row.
        - Only include measurements that have a number. Ignore prose, advice, and instructions.
        - If there are no lab measurements at all, output exactly: NONE

        Examples:
        LDL Cholesterol | 145 | mg/dL | <100
        HDL Cholesterol | 38 | mg/dL |
        HbA1c | 6.4 | % | 4.0-5.6

        Lab report text:
        \(trimmed)

        Output:
        <end_of_turn>
        <start_of_turn>model
        """

        var collected = ""
        // Greedy/deterministic decoding: extraction must be reproducible
        // (same report → same values). Translation + chat keep the
        // default sampler.
        for await piece in context.predict(prompt: prompt, maxTokens: 400, deterministic: true) {
            if isInferenceCancelled || Task.isCancelled { break }
            collected += piece
        }
        print("[LabExtract] raw model output:\n\(collected)\n[LabExtract] end")

        // Merge in a deterministic structural line scan for recall — it
        // catches any "name number unit/range" row the model dropped, no
        // hardcoded disease knowledge.
        var values = Self.parseLabValues(from: collected)
        let present = Set(values.map { $0.joinKey })
        let scanned = Self.scanLabLines(in: ocrText).filter { !present.contains($0.joinKey) }
        values.append(contentsOf: scanned)

        // PASS 2 — enrich with medical knowledge (range when the report
        // omitted one, + concern direction), age/sex aware. Separated
        // from transcription so the model isn't juggling two jobs.
        return await enrichLabValues(values)
    }

    /// Second extraction pass: given the extracted test names + the
    /// patient's age/sex, ask the model for each test's normal range
    /// (age/sex-adjusted) and which direction is clinically worse —
    /// pure medical knowledge, no transcription. Fills a value's range
    /// only when the report didn't print one (the lab's printed range
    /// wins), and sets the concern direction.
    func enrichLabValues(_ values: [LabValue]) async -> [LabValue] {
        guard let context = llamaContext, !values.isEmpty else { return values }

        let profile = UserProfile.load()
        var demoParts: [String] = []
        if !profile.age.trimmingCharacters(in: .whitespaces).isEmpty {
            demoParts.append("age \(profile.age.trimmingCharacters(in: .whitespaces))")
        }
        let sex = profile.biologicalSex.trimmingCharacters(in: .whitespaces)
        if !sex.isEmpty { demoParts.append(sex.lowercased()) }
        let demoLine = demoParts.isEmpty ? "" : " for a \(demoParts.joined(separator: ", ")) patient"

        let namesBlock = values.map { $0.canonicalName }.joined(separator: "\n")
        let prompt = """
        <start_of_turn>user
        You are a medical reference assistant. For each lab test below, give its normal reference range\(demoLine) and which direction is clinically worse. Output ONE per line in EXACTLY this format and nothing else:
        NAME | RANGE | WORSE

        - Copy each NAME back exactly as given.
        - RANGE: the standard reference range as a short string (e.g. <100, 70-100, >40), adjusted for the patient's age and sex where it matters (e.g. HDL is >40 for men but >50 for women; creatinine differs by sex).
        - WORSE: HIGH if a higher value is worse, LOW if a lower value is worse, MID if both unusually high and low are concerning.

        Examples:
        LDL Cholesterol | <100 | HIGH
        HDL Cholesterol | >40 | LOW
        eGFR | >60 | LOW
        Creatinine | 0.6-1.2 | HIGH
        TSH | 0.4-4.0 | MID

        Tests:
        \(namesBlock)

        Output:
        <end_of_turn>
        <start_of_turn>model
        """

        var collected = ""
        for await piece in context.predict(prompt: prompt, maxTokens: 300, deterministic: true) {
            if isInferenceCancelled || Task.isCancelled { break }
            collected += piece
        }
        print("[LabEnrich] raw model output:\n\(collected)\n[LabEnrich] end")

        // Parse NAME | RANGE | WORSE → keyed by normalized name.
        var meta: [String: (range: String?, dir: ConcernDirection?)] = [:]
        for rawLine in collected.split(separator: "\n") {
            let parts = rawLine
                .split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 2, !parts[0].isEmpty else { continue }
            let range = parts[1].isEmpty ? nil : parts[1]
            let dir = parts.count > 2 ? ConcernDirection.from(token: parts[2]) : nil
            meta[LabValue.normalizeKey(parts[0])] = (range, dir)
        }

        return values.map { value in
            var v = value
            guard let m = meta[v.joinKey] else { return v }
            // Report's printed range wins; only fill in when empty.
            if (v.referenceRange?.isEmpty ?? true), let r = m.range { v.referenceRange = r }
            if let d = m.dir { v.concernDirection = d }
            return v
        }
    }

    /// Units that reliably signal "the number before/after me is a lab
    /// result." Used by scanLabLines to tell lab values apart from
    /// other numbers on the page (dates, page numbers, addresses).
    /// Lowercased, punctuation-normalized.
    private static let knownLabUnits: Set<String> = [
        "mg/dl", "g/dl", "mg/l", "ng/dl", "ng/ml", "pg/ml", "mcg/dl", "ug/dl",
        "%", "mmol/l", "umol/l", "miu/l", "uiu/ml", "µiu/ml", "iu/l", "u/l",
        "meq/l", "ml/min", "mm/hr", "mmhg", "fl", "pg", "g/l", "k/ul", "m/ul",
        "10^3/ul", "10^6/ul", "cells/ul", "/ul", "mg/dl.", "ratio"
    ]

    /// GENERAL deterministic lab-line parser. For each line, finds a
    /// plain number, then accepts it as a lab result if it's followed
    /// by EITHER a known unit OR a reference-range pattern (e.g.
    /// "70-100", "<100", ">40"). The range signal is structural, not
    /// vocabulary-based, so this catches values whose unit ISN'T in
    /// our list — as long as the report prints a reference range,
    /// which nearly all do. The text before the number becomes the
    /// test name. Catalog matching only supplies a canonical name when
    /// one exists. Space-separated layouts (PDF text, most OCR) are
    /// handled; fused "6.4%" tokens fall to the catalog backstop.
    static func scanLabLines(in text: String) -> [LabValue] {
        var result: [LabValue] = []
        var seen = Set<String>()
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let tokens = line.split(separator: " ").map(String.init)
            guard tokens.count >= 2 else { continue }
            for i in 1..<tokens.count {
                guard let value = plainNumber(tokens[i]) else { continue }

                let nextTok = (i + 1 < tokens.count ? tokens[i + 1] : "")
                    .lowercased()
                    .trimmingCharacters(in: CharacterSet(charactersIn: "()[],;"))
                let unitKnown = knownLabUnits.contains(nextTok)
                // Any token after the value that looks like a reference
                // range (number-number, <number, >number).
                let hasRange = tokens.indices.contains(where: { $0 > i && looksLikeRange(tokens[$0]) })
                guard unitKnown || hasRange else { continue }

                let name = tokens[0..<i].joined(separator: " ")
                    .trimmingCharacters(in: CharacterSet(charactersIn: " :.-\t"))
                guard name.count >= 2, name.contains(where: \.isLetter) else { continue }

                // Unit: the known unit if present, else the following
                // token when it's a plausible unit (has a letter, short,
                // not itself a range) so unlisted units still display.
                let unit: String
                if unitKnown {
                    unit = nextTok
                } else if nextTok.contains(where: \.isLetter), nextTok.count <= 10, !looksLikeRange(nextTok) {
                    unit = nextTok
                } else {
                    unit = ""
                }

                // No clinical catalog — join on the name as written.
                // Capture a printed reference range if one is on the
                // line, but make no concern-direction judgment (that's
                // the model's job).
                let rangeTok = tokens.first(where: { looksLikeRange($0) })
                let candidate = LabValue(
                    canonicalName: name,
                    rawName: name,
                    value: value,
                    unit: unit,
                    referenceRange: rangeTok,
                    concernDirection: nil
                )
                guard seen.insert(candidate.joinKey).inserted else { continue }
                result.append(candidate)
                break  // one value per line
            }
        }
        return result
    }

    /// True when a token reads as a reference range: "<100", ">40",
    /// "≤5", "≥1", or a number-dash-number span like "70-100" /
    /// "3.5-5.0" (hyphen or en/em dash).
    static func looksLikeRange(_ token: String) -> Bool {
        let t = token.trimmingCharacters(in: CharacterSet(charactersIn: "()[],;"))
        if let first = t.first, "<>≤≥".contains(first),
           t.dropFirst().contains(where: \.isNumber) {
            return true
        }
        for sep in ["-", "–", "—"] {
            if let r = t.range(of: sep) {
                let before = t[..<r.lowerBound]
                let after = t[r.upperBound...]
                if before.contains(where: \.isNumber) && after.contains(where: \.isNumber) {
                    return true
                }
            }
        }
        return false
    }

    /// Parse the report's collection/draw date from the OCR text so
    /// trends order by WHEN THE BLOODWORK WAS DONE, not when it was
    /// scanned. Deterministic (NSDataDetector + keyword scoring), no
    /// LLM. Strategy:
    ///   - find every date in the text,
    ///   - skip ones that are a date of birth (preceded by birth/DOB),
    ///   - skip future dates,
    ///   - score by nearby keywords: collection/draw/specimen highest,
    ///     then report/result/printed, then any other date,
    ///   - return the highest-scoring (tie-break: most recent).
    /// nil when no usable date is found; the report then falls back to
    /// scan time via `effectiveDate`.
    static func extractReportDate(from text: String) -> Date? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return nil
        }
        let ns = text as NSString
        let matches = detector.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }

        let cutoff = Date().addingTimeInterval(86_400)  // allow 1 day of clock skew
        let collectKeywords = ["collect", "drawn", "draw", "specimen", "service date", "accession"]
        let reportKeywords = ["report", "result", "printed", "received", "date"]
        let dobKeywords = ["birth", "dob", "d.o.b", "born"]

        var best: (date: Date, score: Int)?
        for m in matches {
            guard let d = m.date, d <= cutoff else { continue }
            let start = max(0, m.range.location - 40)
            let ctx = ns.substring(with: NSRange(location: start, length: m.range.location - start)).lowercased()
            if dobKeywords.contains(where: { ctx.contains($0) }) { continue }

            let score: Int
            if collectKeywords.contains(where: { ctx.contains($0) }) { score = 3 }
            else if reportKeywords.contains(where: { ctx.contains($0) }) { score = 2 }
            else { score = 1 }

            if let current = best {
                if score > current.score || (score == current.score && d > current.date) {
                    best = (d, score)
                }
            } else {
                best = (d, score)
            }
        }
        return best?.date
    }

    /// A token that is ENTIRELY a number (optional single decimal),
    /// after stripping surrounding punctuation. Rejects ranges like
    /// "70-100" and fused tokens like "6.4%" so we don't misread them.
    static func plainNumber(_ token: String) -> Double? {
        let t = token.trimmingCharacters(in: CharacterSet(charactersIn: "()[]{},;:"))
        guard !t.isEmpty, t.contains(where: \.isNumber) else { return nil }
        guard t.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        return Double(t)
    }


    /// Parse the transcription output (NAME | VALUE | UNIT | RANGE)
    /// into LabValues, deduping by normalized name. Concern direction
    /// is left nil here — it's supplied by the enrichment pass.
    static func parseLabValues(from output: String) -> [LabValue] {
        var result: [LabValue] = []
        var seen = Set<String>()
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.uppercased() == "NONE" { continue }
            let parts = line
                .split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 2 else { continue }
            let rawName = parts[0]
            guard !rawName.isEmpty, rawName.uppercased() != "NAME" else { continue }
            // Keep only digits, decimal point, and leading minus.
            let valueStr = parts[1].filter { "0123456789.-".contains($0) }
            guard let value = Double(valueStr) else { continue }
            let unit = parts.count > 2 ? parts[2] : ""
            let range = (parts.count > 3 && !parts[3].isEmpty) ? parts[3] : nil

            let candidate = LabValue(
                canonicalName: rawName,
                rawName: rawName,
                value: value,
                unit: unit,
                referenceRange: range,
                concernDirection: nil
            )
            // Dedup by normalized name so a panel that lists a marker
            // twice doesn't double-count.
            guard seen.insert(candidate.joinKey).inserted else { continue }
            result.append(candidate)
        }
        return result
    }

    // MARK: - Follow-Up Chat

    struct ChatTurn: Sendable {
        let isUser: Bool
        let content: String
    }

    /// Builds a labelled recent-symptoms block for a chat prompt, or
    /// returns an empty string when the user hasn't logged anything
    /// recently (so the caller can interpolate it inline and have the
    /// whole section vanish cleanly). The `label` is the human-
    /// readable instruction that precedes the bullet list — each
    /// chat surface phrases it slightly differently (follow-up vs.
    /// trends vs. metric) but they all share this formatting + the
    /// "use silently, don't restate as findings" contract that the
    /// profile context already follows.
    private static func symptomSection(label: String) -> String {
        let block = SymptomEntry.promptContextBlock()
        guard !block.isEmpty else { return "" }
        return """


        \(label)
        \(block)
        """
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
        ocrText: String,
        healthMetrics: HealthKitService.HealthMetrics
    ) -> AsyncStream<String> {
        let profile = UserProfile.load()

        let systemHeader = """
        You are an empathetic medical assistant. The user has a lab report and is asking about specific text they highlighted.

        Context from their full report analysis:
        "\(String(reportContext.prefix(500)))"

        The user highlighted this specific text from their lab report:
        "\(selectedText)"

        User's medical context:
        \(profile.promptContextBullets)\(Self.symptomSection(label: "Symptoms the user has logged recently (last 2 weeks). Use SILENTLY as background context — e.g. to connect the highlighted value to how they've been feeling. Do NOT list these back as findings unless the user asks."))

        User's recent Apple Health data (30-day averages — use only if relevant to the question):
        - Resting HR: \(healthMetrics.avgRestingHR.map { "\($0) bpm" } ?? "Unknown")
        - Sleep: \(healthMetrics.avgSleepHours.map { "\($0) hours" } ?? "Unknown")
        - HRV: \(healthMetrics.avgHRV.map { "\($0) ms" } ?? "Unknown")
        - Daily steps: \(healthMetrics.avgSteps.map { String(format: "%.0f", $0) } ?? "Unknown")
        - Daily walking distance: \(healthMetrics.avgWalkingDistanceMiles.map { String(format: "%.2f mi", $0) } ?? "Unknown")
        - Walking speed: \(healthMetrics.avgWalkingSpeedMPH.map { String(format: "%.2f mph", $0) } ?? "Unknown")
        - Daily exercise minutes: \(healthMetrics.avgExerciseMinutes.map { String(format: "%.0f min", $0) } ?? "Unknown")

        Format your reply with care for readability:
        - Use **bold** for medical terms, lab values, and important numbers.
        - Use *italics* sparingly for tone or emphasis.
        - When the answer compares multiple values or ranges (e.g. several lab markers and their normal ranges, or the user's value vs. typical reference values), format the comparison as a Markdown table:
          | Test | Your Value | Normal Range |
          |---|---|---|
          | Glucose | 95 mg/dL | 70–100 mg/dL |
        - Use bullet points (lines starting with `- `) for short lists.
        - Add an emoji only when it genuinely aids comprehension (✅ normal, ⚠️ worth discussing, 💊 medications). Max 1–2 per reply.

        Keep prose answers to 2–4 sentences. Use simple language. If the highlighted text contains a medical term, define it. If it's a lab value, explain whether it's normal and what it means.

        Memory: within this chat you can reference anything the user said earlier in the conversation. You do NOT have persistent memory across different chats — the user's profile (loaded above) is the only thing that carries between sessions. Don't promise to "remember" things long-term; if the user says something they want saved, tell them they can tap the + button next to the message field to add it to their profile.
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
                continuation.yield("Localabs isn't loaded yet. Download \(model.displayName) in Profile to get a real answer about “\(preview)…”.")
                continuation.finish()
            }
        }

        return context.predict(prompt: prompt, maxTokens: 400)
    }

    /// Streams the answer to a Trends-tab question. Different prompt
    /// shape from askFollowUp: there's no specific lab-report
    /// excerpt or highlighted-text selection — the user is asking
    /// about their broader health trends, so the system block leads
    /// with HealthKit metrics + RAG over past reports + profile. The
    /// model is told to synthesize across all three when answering.
    func askAboutTrends(
        question: String,
        history: [ChatTurn] = [],
        healthMetrics: HealthKitService.HealthMetrics
    ) -> AsyncStream<String> {
        let profile = UserProfile.load()
        // Scans are secondary context here — cap at 3 reports (was 5) so
        // the trends block stays the dominant signal in the prompt.
        let ragContext = LocalStorageService.shared.buildRAGContext(maxReports: 3)

        let systemHeader = """
        You are an empathetic medical assistant. The user is in the Health Trends tab and wants to understand their Apple Health data over time — activity, sleep, vitals, mobility, cardio recovery. THIS IS THE PRIMARY CONTEXT for your answer.

        ╔══ PRIMARY: User's Apple Health trends (30-day averages) ══╗
        - Resting HR: \(healthMetrics.avgRestingHR.map { "\($0) bpm" } ?? "Unknown")
        - HRV: \(healthMetrics.avgHRV.map { "\($0) ms" } ?? "Unknown")
        - Sleep: \(healthMetrics.avgSleepHours.map { "\($0) hours" } ?? "Unknown")
        - Daily steps: \(healthMetrics.avgSteps.map { String(format: "%.0f", $0) } ?? "Unknown")
        - Daily walking/running distance: \(healthMetrics.avgWalkingDistanceMiles.map { String(format: "%.2f mi", $0) } ?? "Unknown")
        - Walking speed: \(healthMetrics.avgWalkingSpeedMPH.map { String(format: "%.2f mph", $0) } ?? "Unknown")
        - Daily exercise minutes: \(healthMetrics.avgExerciseMinutes.map { String(format: "%.0f min", $0) } ?? "Unknown")
        ╚════════════════════════════════════════════════════════════╝

        SECONDARY context — the user's personal health profile (for personalizing recommendations to their age/sex/conditions):
        \(profile.promptContextBullets)\(Self.symptomSection(label: "SECONDARY context — symptoms the user has logged recently (last 2 weeks). Connect these to the trends when relevant, e.g. \"the headaches you logged line up with your elevated resting HR.\" Use silently; don't just list them back."))

        TERTIARY context — the user's past lab reports (reference only; bring them up *only* when a trend specifically connects to a past lab finding, e.g. "your HRV drop lines up with the elevated cortisol in your March panel"):\(ragContext)

        How to answer:
        - LEAD with the Apple Health trends. They are why the user is here.
        - Use the profile to personalize (age-appropriate targets, etc.) but don't make it the main subject.
        - Reference past labs only when they materially connect to the question. If a trend question has no lab connection, don't shoehorn one in.
        - Suggest concrete, actionable lifestyle moves the user could discuss with their doctor: sleep targets, walking minutes, dietary shifts.
        - Do NOT prescribe medications, dosages, or specific medical treatments.
        - Flag anything that warrants doctor follow-up explicitly with a ⚠️.
        - Format with **bold** for medical terms / metric values / numbers, *italics* sparingly, bullet points for short lists, and Markdown tables only when comparing 3+ values across categories.
        - Keep prose answers to 3–6 sentences unless the user explicitly asks for more depth.

        Memory: you can reference anything the user said earlier in this conversation, but you don't have persistent memory across different chats — only the user's profile (loaded above) carries between sessions. If the user says something save-worthy, tell them they can tap the + button next to the message field to add it to their profile.
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
            return AsyncStream { continuation in
                continuation.yield("Localabs isn't loaded yet. Download \(model.displayName) in Profile to ask about your trends.")
                continuation.finish()
            }
        }

        return context.predict(prompt: prompt, maxTokens: 500)
    }

    /// Streams the answer to a question scoped to a single Apple Health
    /// metric (the user is in the Metric Detail sheet's chat). The
    /// system prompt orders context strictly:
    ///   1. The focus metric itself — its value, unit, range window,
    ///      delta, clinical range, and explanation. This is the
    ///      subject of the conversation.
    ///   2. Other Apple Health metrics — siblings the model can
    ///      cross-reference (e.g. "your low HRV is consistent with
    ///      your short sleep duration").
    ///   3. Past lab reports — only invoked when a connection is
    ///      genuinely there ("your elevated walking HR could relate
    ///      to the iron-deficiency findings in your March panel").
    /// Profile bullets ride along as personalization, not as the
    /// subject.
    func askAboutMetric(
        question: String,
        history: [ChatTurn] = [],
        metricLabel: String,
        metricValue: String,
        metricUnit: String,
        metricRangeDays: Int,
        metricStatusLabel: String?,
        metricTypicalRange: String?,
        metricExplanation: String?,
        metricDelta: String?,
        otherHealthMetrics: HealthKitService.HealthMetrics
    ) -> AsyncStream<String> {
        let profile = UserProfile.load()
        // Past scans are tertiary here — keep the slice small so the
        // metric block stays dominant in the context window.
        let ragContext = LocalStorageService.shared.buildRAGContext(maxReports: 2)

        // The metric block is the heart of the prompt: everything the
        // user can see on the detail screen, fed in verbatim so the
        // model and the screen agree on the facts.
        var metricLines: [String] = [
            "- Metric: \(metricLabel)",
            "- User's \(metricRangeDays)-day average: \(metricValue) \(metricUnit)"
        ]
        if let delta = metricDelta {
            metricLines.append("- Change: \(delta)")
        }
        if let status = metricStatusLabel {
            metricLines.append("- Status vs. population norms: \(status)")
        }
        if let range = metricTypicalRange {
            metricLines.append("- Typical range: \(range)")
        }
        if let explanation = metricExplanation {
            metricLines.append("- What it measures: \(explanation)")
        }
        let metricBlock = metricLines.joined(separator: "\n        ")

        let systemHeader = """
        You are an empathetic medical assistant. The user is looking at a single Apple Health metric in detail and wants to understand it.

        ╔══ PRIMARY: The metric the user is asking about ══╗
        \(metricBlock)
        ╚═══════════════════════════════════════════════════╝

        SECONDARY — other Apple Health trends (cross-reference only when relevant):
        - Resting HR: \(otherHealthMetrics.avgRestingHR.map { "\($0) bpm" } ?? "Unknown")
        - HRV: \(otherHealthMetrics.avgHRV.map { "\($0) ms" } ?? "Unknown")
        - Sleep: \(otherHealthMetrics.avgSleepHours.map { "\($0) hours" } ?? "Unknown")
        - Daily steps: \(otherHealthMetrics.avgSteps.map { String(format: "%.0f", $0) } ?? "Unknown")
        - Daily walking/running distance: \(otherHealthMetrics.avgWalkingDistanceMiles.map { String(format: "%.2f mi", $0) } ?? "Unknown")
        - Walking speed: \(otherHealthMetrics.avgWalkingSpeedMPH.map { String(format: "%.2f mph", $0) } ?? "Unknown")
        - Daily exercise minutes: \(otherHealthMetrics.avgExerciseMinutes.map { String(format: "%.0f min", $0) } ?? "Unknown")

        Personal health profile (use to personalize, not as subject):
        \(profile.promptContextBullets)\(Self.symptomSection(label: "Symptoms the user has logged recently (last 2 weeks). Cross-reference with the focus metric only when relevant. Use silently; don't just list them back."))

        TERTIARY context — past lab reports (only mention if the metric question genuinely connects to a past lab finding):\(ragContext)

        How to answer:
        - The focus metric IS the topic. Answer about it directly first.
        - Bring in another Health metric only when it materially helps interpret the focus metric (e.g. low HRV + short sleep → recovery pattern).
        - Reference past labs only when there's a real connection. If not, don't force one.
        - Suggest concrete, actionable next steps the user can discuss with their doctor.
        - Do NOT prescribe medications, dosages, or specific medical treatments.
        - Flag anything that warrants doctor follow-up with ⚠️.
        - Format with **bold** for numbers / medical terms, bullet points for short lists.
        - Keep prose answers to 2–5 sentences unless the user asks for more depth.

        Memory: only the user's profile (loaded above) carries between chats — within this conversation you can reference earlier turns, but new chats start fresh. If the user says something worth saving permanently, tell them to tap the + button next to the message field to add it to their profile.
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
            return AsyncStream { continuation in
                continuation.yield("Localabs isn't loaded yet. Download \(model.displayName) in Profile to ask about your \(metricLabel) trend.")
                continuation.finish()
            }
        }

        return context.predict(prompt: prompt, maxTokens: 450)
    }
}
