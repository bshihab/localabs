import SwiftUI
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers
import VisionKit

struct ScanView: View {
    @EnvironmentObject var engine: InferenceEngine
    /// Pages captured from the document camera, in scan order. Populated
    /// by `DocumentCameraView` once the user taps Save in the native
    /// scanner UI; the picker can deliver one OR many pages.
    @State private var capturedPages: [UIImage] = []
    @State private var report: StructuredReport?
    @State private var showCamera = false
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showPDFPicker = false
    @State private var navigateToDashboard = false
    @State private var showPermissionAlert = false
    /// Drives the "No health content detected" alert. Set when the
    /// analysis pipeline returns a `wasRejectedAsNonHealth` report;
    /// dismissing the alert clears `report` so ScanView snaps back
    /// to the idle upload view.
    @State private var showNonHealthAlert = false

    var body: some View {
        NavigationStack {
            ZStack {
                // ScanView is the home of any in-flight, paused, or
                // truncated-and-waiting-to-resume analysis. The
                // processing view stays on screen for all three states
                // so the Resume / Discard controls are reachable; only
                // genuine idle (nothing in flight, nothing parked)
                // flips back to the upload buttons.
                //
                // `pendingResumeReport != nil` is what catches a
                // multi-page scan that hit the output-token ceiling
                // mid-stream: not paused, not processing, but also
                // not "done" — without this, the user would drop
                // straight to upload view even though there's a
                // half-finished report waiting to be resumed.
                if engine.isProcessing || engine.isPaused || engine.pendingResumeReport != nil {
                    processingView
                        .transition(.opacity)
                } else {
                    uploadView
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: engine.isProcessing)
            .animation(.easeInOut(duration: 0.3), value: engine.isPaused)
            .animation(.easeInOut(duration: 0.3), value: engine.pendingResumeReport != nil)
            .navigationTitle("")
            .fullScreenCover(isPresented: $showCamera) {
                // VNDocumentCameraViewController is the same scanner
                // Apple Notes and Files use: native multi-page capture,
                // automatic edge detection, perspective correction, and
                // a Save / Retake flow that's already familiar to the
                // user. Returns one OR many pages as UIImage in scan
                // order — no need for our own multi-shot wrapper.
                DocumentCameraView(pages: $capturedPages)
                    .ignoresSafeArea()
            }
            .sheet(isPresented: $showPDFPicker) {
                PDFDocumentPicker { url in
                    Task {
                        let result = await engine.analyzePDF(at: url)
                        handleAnalysisResult(result)
                    }
                }
                .ignoresSafeArea()
            }
            .alert("Camera Access Required", isPresented: $showPermissionAlert) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Please enable camera access in Settings to scan lab reports.")
            }
            // "No health content detected" popup. Fires whenever
            // analyzeImages / analyzePDF returns a rejection report
            // (the heuristic refused to send something that doesn't
            // look like a lab report to the model). Dismissing clears
            // `report` so the view flips back to the upload buttons.
            .alert("No medical content detected", isPresented: $showNonHealthAlert) {
                Button("OK", role: .cancel) {
                    report = nil
                }
            } message: {
                Text("Localabs couldn't find any medical content in this scan — no lab values, no clinical findings, no diagnosis. To prevent invented results, the analysis was stopped.\n\nTry again with a printed lab result (e.g. cholesterol values with reference ranges) or a clinical note (visit summary with diagnosis and plan).")
            }
            // Hard-failure popup. Fires when a run finishes with no
            // resumable state — model produced zero tokens (prompt
            // overflow, model never loaded, etc.). Without this, the
            // user would see the screen snap back to the upload view
            // with no explanation. Dismissing clears the engine's
            // failure flag + local report state so the next scan
            // starts from a clean slate.
            .alert(
                "Analysis didn't complete",
                isPresented: Binding(
                    get: { engine.lastHardFailureMessage != nil },
                    set: { isPresented in
                        if !isPresented {
                            engine.lastHardFailureMessage = nil
                            report = nil
                        }
                    }
                )
            ) {
                Button("OK", role: .cancel) {
                    engine.lastHardFailureMessage = nil
                    report = nil
                }
            } message: {
                Text(engine.lastHardFailureMessage ?? "")
            }
            .onChange(of: pickerItems) { _, newItems in
                handlePickerItemsChange(newItems)
            }
            .onChange(of: capturedPages) { _, pages in
                handleCapturedPagesChange(pages)
            }
            .navigationDestination(isPresented: $navigateToDashboard) {
                if let report = report {
                    // `.id(report.id)` forces SwiftUI to build a
                    // fresh DashboardView instance whenever the
                    // pushed report changes. Without this, the
                    // dashboard could reuse its @State (including
                    // a stale `report` value) across consecutive
                    // scans — making a brand-new multi-page scan
                    // appear to display the prior scan's text.
                    DashboardView(initialReport: report)
                        .id(report.id)
                }
            }
        }
    }

    // MARK: - Upload (idle) view

    private var uploadView: some View {
        VStack(spacing: 0) {
            Spacer()

            ZStack {
                Circle()
                    .fill(.blue.opacity(0.12))
                    .frame(width: 96, height: 96)
                Image(systemName: "doc.text.viewfinder")
                    .font(.system(size: 44))
                    .foregroundStyle(.blue)
            }
            .padding(.bottom, 24)

            Text("Upload Report")
                .font(.system(size: 34, weight: .bold))
                .padding(.bottom, 8)

            Text("Ingest lab results securely using your\nCamera or Photo Library.")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, 40)

            Spacer()

            VStack(spacing: 8) {
                GlassEffectContainer(spacing: 12) {
                    VStack(spacing: 12) {
                        Button {
                            requestCameraAndOpen()
                        } label: {
                            // Reframed as "Scan Document" so users know
                            // the camera supports multi-page capture in
                            // one session — matches the document-scanner
                            // UX (same one Notes uses) the button now
                            // opens.
                            Label("Scan Document", systemImage: "doc.viewfinder.fill")
                                .font(.system(size: 17, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(!engine.isModelLoaded)

                        // Up to 10 photos for a multi-page report. iOS's
                        // built-in picker handles the multi-select UI.
                        PhotosPicker(
                            selection: $pickerItems,
                            maxSelectionCount: 10,
                            matching: .images
                        ) {
                            Label("Choose from Photos", systemImage: "photo.on.rectangle")
                                .font(.system(size: 17, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(.glass)
                        .disabled(!engine.isModelLoaded)

                        Button {
                            showPDFPicker = true
                        } label: {
                            Label("Choose a PDF", systemImage: "doc.fill")
                                .font(.system(size: 17, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(.glass)
                        .disabled(!engine.isModelLoaded)
                    }
                }

                if !engine.isModelLoaded {
                    Text("Download \(engine.selectedModel.displayName) in Profile first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }

    // MARK: - Processing (live-fill) view

    /// True when the engine has an analysis the user can pick back up
    /// — either paused or truncated. Drives the Resume/Discard bottom
    /// CTAs so the truncation case (multi-page scan that hit the
    /// output-token ceiling) gets the same recovery affordance the
    /// paused case has.
    private var needsResume: Bool {
        engine.isPaused || engine.pendingResumeReport != nil
    }

    /// Title shown on the processing card. Differentiates between
    /// active streaming, an explicit user pause, and a run that ran
    /// out of token budget — so the user knows which state they're
    /// in without having to read the body copy.
    private var processingHeadline: String {
        if engine.isPaused { return "Paused" }
        if engine.pendingResumeReport != nil { return "Incomplete" }
        return "Analyzing"
    }

    private var processingView: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(processingHeadline)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(needsResume ? Color.orange : Color.primary)
                            Spacer()
                            // Live percentage tied to engine.analysisProgress.
                            // Using monospaced digits keeps it from twitching
                            // as the percent changes width.
                            Text("\(Int(engine.analysisProgress * 100))%")
                                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .contentTransition(.numericText(value: engine.analysisProgress))
                        }
                        Text(statusLine)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    // Pause toggle only while a run is actively
                    // streaming. Hidden while paused (action moves to
                    // the dedicated bottom buttons) AND while we're
                    // showing a truncated-needs-resume state — there's
                    // nothing to pause.
                    if engine.isProcessing && !needsResume {
                        Button {
                            engine.pauseInference()
                        } label: {
                            Image(systemName: "pause.circle.fill")
                                .font(.system(size: 26))
                                .foregroundStyle(.blue, .blue.opacity(0.18))
                                .symbolRenderingMode(.hierarchical)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Pause analysis")
                    }
                }

                // Determinate progress bar — replaces the previous
                // indeterminate spinner. Fills as each pipeline phase
                // completes (OCR per page → save → Health → Localabs
                // streaming → final save). Tints orange while paused so
                // the frozen state reads at a glance.
                ProgressView(value: engine.analysisProgress)
                    .tint(needsResume ? .orange : .blue)
                    .animation(.easeOut(duration: 0.25), value: engine.analysisProgress)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            // Cards fill in live as Localabs streams each section.
            // While paused, the cards stay populated with whatever
            // streamed in before the pause — the user can still scroll
            // through partial content.
            LiveReportSectionsView(streamingText: engine.streamingText)
                .padding(.horizontal, 20)
                .padding(.bottom, needsResume ? 12 : 24)

            // Resume + Discard pinned to the bottom of the recoverable
            // states (paused OR truncated mid-stream). Resume is the
            // prominent CTA; Discard is a small destructive link so
            // accidental taps stay safe.
            if needsResume {
                VStack(spacing: 10) {
                    Button {
                        Task {
                            // Route the regen result through the same
                            // handler analyzeImages uses so a successful
                            // resume actually pushes Dashboard. Without
                            // this routing the result was discarded and
                            // ScanView snapped back to the upload view
                            // — the "saved to History but never showed
                            // me the translation" bug.
                            if let result = await engine.resumeFromPaused() {
                                handleAnalysisResult(result)
                            }
                        }
                    } label: {
                        Label("Resume Analysis", systemImage: "play.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.glassProminent)

                    Button(role: .destructive) {
                        // Engine call deletes the stored incomplete
                        // report + clears streamingText / isPaused /
                        // pendingResumeReport. We also wipe ScanView's
                        // local @State (the in-memory report + image
                        // picker selections) so the user lands back on
                        // a genuinely blank upload screen instead of
                        // one carrying stale state from the discarded
                        // run.
                        engine.discardPausedAnalysis()
                        report = nil
                        pickerItems = []
                        capturedPages = []
                        navigateToDashboard = false
                    } label: {
                        Text("Discard analysis")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red.opacity(0.85))
                    .padding(.bottom, 4)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }

    /// Subhead under the "Analyzing / Paused" header. Switches between
    /// the live processingStatus, a generic running message, and a
    /// paused-state hint so the user always knows what state we're in.
    private var statusLine: String {
        if engine.isPaused {
            return "Tap Resume to continue, or Discard to start over."
        }
        return engine.processingStatus.isEmpty
            ? "Localabs is generating your report…"
            : engine.processingStatus
    }

    /// Multi-photo path. Loads each picked PhotosPickerItem into a UIImage
    /// via ImageIO's thumbnail API (downsamples to 2048pt during decode so
    /// the full-resolution bitmap never gets allocated), drops failures
    /// rather than aborting the whole batch, then funnels through
    /// analyzeImages. The downsampling is what fixed multi-photo scans
    /// freezing the app the moment Localabs started — five 12MP photos
    /// at full res were ~180MB of decoded bitmap held alongside the 4B
    /// model + KV cache, which pushed iPhones into memory-pressure
    /// suspension.
    private func handlePickerItemsChange(_ newItems: [PhotosPickerItem]) {
        guard !newItems.isEmpty else { return }
        Task {
            var images: [UIImage] = []
            for item in newItems {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                if let img = InferenceEngine.downsampledImage(from: data) {
                    images.append(img)
                }
            }
            pickerItems = []
            if !images.isEmpty {
                let result = await engine.analyzeImages(images)
                handleAnalysisResult(result)
            }
        }
    }

    /// Multi-page camera path. `VNDocumentCameraViewController` lets
    /// the user capture multiple pages in one session (each page gets
    /// auto-edge-detected and perspective-corrected); on Save we get
    /// the full `[UIImage]` array. Same downstream pipeline as the
    /// photo picker — analyzeImages handles 1-to-N pages identically.
    private func handleCapturedPagesChange(_ pages: [UIImage]) {
        guard !pages.isEmpty else { return }
        Task {
            let result = await engine.analyzeImages(pages)
            handleAnalysisResult(result)
            // Clear after the await returns so re-opening the scanner
            // starts from an empty buffer. Done on MainActor implicitly
            // because we're in an @State-bound async context.
            capturedPages = []
        }
    }

    /// Single routing point for every analysis result, regardless of
    /// the entry path (PDF picker, photo picker, or camera). Three
    /// outcomes:
    ///   1. Rejection (non-health content) → show alert, stay on
    ///      upload view, never persist anything.
    ///   2. Incomplete (paused / interrupted) → stay on ScanView so
    ///      the in-place Resume/Discard buttons can take over.
    ///   3. Completed → push DashboardView with the new report.
    private func handleAnalysisResult(_ result: StructuredReport) {
        if result.wasRejectedAsNonHealth {
            // Don't even keep the rejected report around — the alert
            // is the only feedback the user needs, and leaving it in
            // `report` would risk navigating to DashboardView on the
            // next state change.
            report = nil
            showNonHealthAlert = true
            return
        }
        report = result
        if !result.isIncomplete && !engine.isPaused {
            navigateToDashboard = true
        }
    }

    private func requestCameraAndOpen() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            showCamera = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        showCamera = true
                    } else {
                        showPermissionAlert = true
                    }
                }
            }
        case .denied, .restricted:
            showPermissionAlert = true
        @unknown default:
            showPermissionAlert = true
        }
    }
}

// MARK: - Live-fill section cards

/// Renders the five report sections as cards that fill in as Localabs streams.
/// On every token, we re-parse the partial text via StructuredReport.parse —
/// since the parser is header-anchored, partial input correctly attributes
/// each chunk to its section. Whichever section currently has the latest
/// text is the "active" one (gets a pulsing dot + tinted glass + auto-scroll).
/// Internal so DashboardView can reuse the same streaming-card UI
/// when the user taps Regenerate — we want regenerate to feel like a
/// fresh scan rather than a single opaque spinner.
struct LiveReportSectionsView: View {
    let streamingText: String

    private var partial: StructuredReport {
        StructuredReport.parse(from: streamingText)
    }

    /// The section being filled right now: the last in declaration order
    /// that has any content. If nothing has streamed yet, default to the
    /// first one so the visual cursor sits there waiting.
    private var activeSection: ReportSection {
        for section in ReportSection.allCases.reversed() {
            if !text(for: section).isEmpty { return section }
        }
        return .summary
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 14) {
                    ForEach(ReportSection.allCases) { section in
                        LiveSectionCard(
                            section: section,
                            text: cleanText(for: section),
                            state: state(for: section)
                        )
                        .id(section)
                    }
                }
            }
            .onChange(of: activeSection) { _, new in
                // Keep the section Localabs is currently writing in view —
                // user shouldn't have to scroll to see fresh content.
                withAnimation(.easeInOut(duration: 0.45)) {
                    proxy.scrollTo(new, anchor: .top)
                }
            }
        }
    }

    private func text(for section: ReportSection) -> String {
        switch section {
        case .summary:     return partial.patientSummary
        case .questions:   return partial.doctorQuestions
        case .diet:        return partial.dietaryAdvice
        case .glossary:    return partial.medicalGlossary
        case .medications: return partial.medicationNotes
        }
    }

    /// Strip a trailing line that looks like an in-progress section header
    /// (e.g., "2." or "2. QUESTIONS FOR YOUR" before "DOCTOR" arrives) so
    /// the previous section's card doesn't briefly show the next header
    /// while the LLM tokenizes it.
    private func cleanText(for section: ReportSection) -> String {
        let raw = text(for: section)
        let lines = raw.components(separatedBy: "\n")
        guard let last = lines.last else { return raw }

        let stripped = last.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "#", with: "")
            .trimmingCharacters(in: .whitespaces)

        let startsWithListMarker = stripped.range(
            of: #"^\d+[\.\)]"#, options: .regularExpression
        ) != nil
        let isShortAndAllCapsish = stripped.count < 40
            && stripped.uppercased() == stripped
            && stripped.contains(where: { $0.isLetter })

        if startsWithListMarker && isShortAndAllCapsish {
            return lines.dropLast().joined(separator: "\n")
        }
        return raw
    }

    private func state(for section: ReportSection) -> LiveSectionState {
        if !text(for: section).isEmpty {
            return section == activeSection ? .active : .complete
        }
        return .pending
    }
}

enum ReportSection: Int, CaseIterable, Identifiable {
    case summary, questions, diet, glossary, medications
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .summary:     return "Patient Summary"
        case .questions:   return "Questions for Your Doctor"
        case .diet:        return "Dietary Advice"
        case .glossary:    return "Medical Glossary"
        case .medications: return "Medication Notes"
        }
    }

    var icon: String {
        switch self {
        case .summary:     return "person.text.rectangle.fill"
        case .questions:   return "questionmark.bubble.fill"
        case .diet:        return "leaf.fill"
        case .glossary:    return "book.fill"
        case .medications: return "pills.fill"
        }
    }

    var tint: Color {
        switch self {
        case .summary:     return .blue
        case .questions:   return .purple
        case .diet:        return .green
        case .glossary:    return .orange
        case .medications: return .pink
        }
    }
}

enum LiveSectionState {
    case pending, active, complete
}

struct LiveSectionCard: View {
    let section: ReportSection
    let text: String
    let state: LiveSectionState

    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: section.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(state == .pending ? Color.secondary : section.tint)
                Text(section.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(state == .pending ? Color.secondary : Color.primary)
                Spacer()
                if state == .active {
                    Circle()
                        .fill(section.tint)
                        .frame(width: 8, height: 8)
                        .scaleEffect(pulse ? 1.4 : 0.85)
                        .opacity(pulse ? 0.55 : 1.0)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                                pulse = true
                            }
                        }
                        .transition(.opacity)
                }
            }

            Group {
                if !text.isEmpty {
                    // Markdown-aware renderer (lives in SectionCard.swift)
                    // splits per-line so partial selection works and the
                    // user can grab one sentence without grabbing the
                    // whole card.
                    MarkdownBody(text)
                        .font(.system(size: 14))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if state == .active {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.65)
                        Text("Generating…")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Waiting for Localabs…")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary.opacity(0.55))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(
            state == .active
                ? .regular.tint(section.tint.opacity(0.18))
                : .regular,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay(
            // Subtle tint glow on the active card so the eye knows where to look
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(section.tint.opacity(state == .active ? 0.45 : 0), lineWidth: 1)
        )
        .opacity(state == .pending ? 0.55 : 1.0)
        .scaleEffect(state == .pending ? 0.97 : 1.0)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: state)
        .animation(.easeOut(duration: 0.18), value: text)
    }
}

// MARK: - PDF Document Picker

/// Wraps UIDocumentPickerViewController so SwiftUI can present a PDF picker
/// as a sheet. Calls `onPicked(url)` once the user selects a file. The URL
/// it hands back is a security-scoped resource — InferenceEngine.analyzePDF
/// handles the start/stopAccessingSecurityScopedResource dance.
struct PDFDocumentPicker: UIViewControllerRepresentable {
    let onPicked: (URL) -> Void
    @Environment(\.dismiss) var dismiss

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.pdf], asCopy: false)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: PDFDocumentPicker
        init(_ parent: PDFDocumentPicker) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first {
                parent.onPicked(url)
            }
            parent.dismiss()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.dismiss()
        }
    }
}

// MARK: - Apple's Native Document Scanner (VNDocumentCameraViewController)

/// Wraps Apple's `VNDocumentCameraViewController` — the same scanner
/// Notes and Files use. Supports multi-page capture out of the box:
/// the user can hit the shutter multiple times to add pages, retake
/// any that came out blurry, then tap **Save** to deliver the full
/// set as a `[UIImage]`. Edge detection + perspective correction are
/// built in, so even a phone-held page becomes a clean rectangular
/// scan without any geometry work on our side.
///
/// Replaces the old `NativeCameraView` (UIImagePickerController), which
/// could only return a single un-corrected photo at a time.
struct DocumentCameraView: UIViewControllerRepresentable {
    /// Pages in capture order. Updated from `documentCameraViewController(_:didFinishWith:)`.
    @Binding var pages: [UIImage]
    @Environment(\.dismiss) var dismiss

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: DocumentCameraView
        init(_ parent: DocumentCameraView) { self.parent = parent }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            // VNDocumentCameraScan exposes pages by index; pull all of
            // them into an array in scan order so the downstream
            // pipeline can OCR + save them as a multi-page report.
            var collected: [UIImage] = []
            collected.reserveCapacity(scan.pageCount)
            for i in 0..<scan.pageCount {
                collected.append(scan.imageOfPage(at: i))
            }
            parent.pages = collected
            parent.dismiss()
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.dismiss()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            // Failures here are typically permission / hardware glitches
            // — surface a console log and dismiss; ScanView's idle state
            // takes over.
            print("[DocumentCameraView] scan failed: \(error.localizedDescription)")
            parent.dismiss()
        }
    }
}
