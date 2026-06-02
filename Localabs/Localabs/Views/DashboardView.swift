import SwiftUI
import UIKit

struct DashboardView: View {
    @EnvironmentObject var engine: InferenceEngine
    /// Bound from ContentView when Dashboard is shown as a tab so the
    /// "paused analysis" badge can switch the user back to Scan tab.
    /// Nil when Dashboard is pushed onto a NavigationStack (post-scan,
    /// History detail) — in those routes we don't show the badge.
    var selectedTab: Binding<Int>?
    var initialReport: StructuredReport?
    /// True only when this dashboard was pushed right after a scan
    /// completed (from ScanView). Drives a clear "Scan Another Report"
    /// button so the user doesn't have to discover the back chevron.
    /// Not shown when the dashboard is opened from History.
    var isPostScan: Bool = false
    @Environment(\.dismiss) private var dismiss
    @State private var report: StructuredReport?
    /// Same struct InferenceEngine reads when building the analysis
    /// prompt — surfacing it here keeps the dashboard's "what
    /// Apple Health informed this analysis" card honest. The card
    /// shows exactly what the AI saw, no more no less.
    @State private var healthMetrics: HealthKitService.HealthMetrics?
    @State private var isRegenerating = false
    @State private var showShareSheet = false
    @State private var shareItems: [Any] = []
    /// Confirmation gate for the Regenerate Translation CTA — replacing
    /// the existing translation is destructive (the original sections
    /// are overwritten with the new run's output), so the user gets a
    /// chance to back out before kicking off the LLM.
    @State private var showRegenConfirm = false
    /// Drives the "Add to Meds" sheet launched from the Medication
    /// Notes section, prefilled with the report link so the new med
    /// traces back to this scan.
    @State private var showAddMed = false
    /// Cross-report lab trends for this report's markers (#28),
    /// loaded on appear. Drives the "what changed" / worsening-trend
    /// card and the full comparison sheet.
    @State private var labTrends: [LabTrend] = []
    @State private var showLabTrends = false
    /// Drives the "whose report is this?" prompt when the report's
    /// printed age clearly can't be the user's.
    @State private var showOwnershipPrompt = false
    /// Loaded page images for the inline, swipeable scan preview. Empty
    /// for reports with no saved scan (e.g. a weekly Health review).
    @State private var previewImages: [UIImage] = []
    /// The page currently snapped into view in the horizontal pager.
    /// Drives the page dots and which page the viewer opens to on tap.
    @State private var scrolledPreviewPage: Int?
    /// Measured content width of the pager, used to size each page to the
    /// scan's true aspect ratio (vs. a fixed, letterboxed height).
    @State private var previewWidth: CGFloat = 0
    /// Programmatic push into the full-screen document viewer, opened at
    /// `docViewerPage` when the user taps a preview page.
    @State private var showDocViewer = false
    @State private var docViewerPage = 0

    var body: some View {
        // NOTE: no nested NavigationStack here. DashboardView is always
        // *pushed* into an existing stack (ScanView post-scan, History
        // detail), so wrapping it in its own stack created a second
        // navigation bar and left the post-scan back button as a plain
        // chevron we couldn't customize. Attaching directly to the
        // parent stack lets `.navigationBarBackButtonHidden` + the
        // custom "Scan Another" leading item below actually take effect.
        Group {
            if isRegenerating {
                regeneratingView
            } else {
                dashboardContent
            }
        }
        // Post-scan, the parent (ScanView) pushed us — replace the
        // generic "‹ Back" chevron with an explicit "Scan Another"
        // affordance so the user doesn't have to discover the back
        // gesture. From History, leave the normal back button alone.
        .navigationBarBackButtonHidden(isPostScan)
        .toolbar {
            if isPostScan {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Label("Scan Another", systemImage: "doc.text.viewfinder")
                    }
                }
            }
        }
        // .alert (centered modal) instead of .confirmationDialog
        // (bottom action sheet) so the popup reads as anchored to
        // the tap — confirmationDialog on iPhone always slides up
        // from the bottom of the screen by iOS convention, which
        // felt disconnected from the regenerate button.
        .alert("Regenerate translation?", isPresented: $showRegenConfirm) {
            Button("Regenerate", role: .destructive) {
                Task { await regenerate() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This permanently replaces the current translation. The original sections can't be recovered.")
        }
    }

    /// Mirrors ScanView's processingView during a regenerate so the
    /// user sees the same live-streaming section cards instead of a
    /// single opaque spinner. The header card carries the determinate
    /// progress + percentage; the cards below fill in as each section
    /// streams.
    private var regeneratingView: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Generating")
                            .font(.system(size: 17, weight: .semibold))
                        // Allow the status to wrap to two lines so
                        // "Localabs is regenerating your report…"
                        // doesn't truncate to "…your repo".
                        Text(engine.processingStatus.isEmpty
                             ? "Localabs is writing your translation…"
                             : engine.processingStatus)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Text("\(Int(engine.analysisProgress * 100))%")
                        .font(.system(size: 15, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText(value: engine.analysisProgress))
                }
                ProgressView(value: engine.analysisProgress)
                    .tint(.purple)
                    .animation(.easeOut(duration: 0.25), value: engine.analysisProgress)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            LiveReportSectionsView(streamingText: engine.streamingText)
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
        }
        .background(.background)
    }

    private var dashboardContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                // Use the LLM-generated title (e.g. "Lipid Panel
                // Results") so the dashboard header matches the
                // History row and the user immediately sees what the
                // report is about. Falls back to a generic header only
                // when there's no report yet (empty tab state) or the
                // model omitted a title — displayTitle handles both.
                Text(currentReport?.displayTitle ?? "Translation")
                    .font(.system(size: 34, weight: .bold))
                    .padding(.horizontal)
                    .padding(.top, 8)

                GlassEffectContainer(spacing: 14) {
                    HStack(spacing: 14) {
                        StatusBadge(
                            label: "Status",
                            value: statusValue,
                            color: statusColor
                        )
                        StatusBadge(label: "Health Sync", value: "Active", color: .blue)
                    }
                }
                .padding(.horizontal)

                summaryCard
                    .padding(.horizontal)

                // Swipeable preview of the original scan, right up top so
                // the user can see the actual document alongside the
                // translation. Swipe flips pages; tapping anywhere on a
                // page opens the full viewer (on that same page) to circle
                // values and ask follow-up questions — one integrated
                // control, no separate button. Hidden for incomplete
                // reports and reports with no saved scan.
                if let report = currentReport, !report.isIncomplete, !previewImages.isEmpty {
                    scanPreviewCard
                        .padding(.horizontal)
                }

                if !labTrends.isEmpty {
                    labTrendCard
                        .padding(.horizontal)
                }

                    // Apple Health used to inform this analysis —
                    // shows exactly the metrics InferenceEngine read
                    // when building the prompt. Hidden when the user
                    // has no Health data at all, since an empty card
                    // would just clutter the screen.
                    if let metrics = healthMetrics, !metrics.isEmpty {
                        healthUsedInAnalysisCard(metrics)
                            .padding(.horizontal)
                    }

                    // Slim "analysis is paused" badge — visible only on
                    // the Dashboard *tab*, and only when an inference
                    // is currently paused. Tapping switches to the
                    // Scan tab where the live cards live, so the
                    // user always has one obvious place to resume.
                    // In pushed contexts (post-scan, History detail)
                    // we hide this — those are dedicated views of one
                    // report and a tab-switch hint there is confusing.
                    if let tabBinding = selectedTab, engine.isPaused {
                        pausedAnalysisBadge(switchTo: tabBinding)
                            .padding(.horizontal)
                    }

                    if let report = currentReport, !report.isIncomplete {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("AI INSIGHTS")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .tracking(1.5)
                                .padding(.horizontal, 20)

                            SectionCard(
                                icon: "cross.case.fill",
                                iconColor: .red,
                                title: "Questions for Your Doctor",
                                content: report.doctorQuestions,
                                defaultExpanded: true
                            )

                            SectionCard(
                                icon: "leaf.fill",
                                iconColor: .green,
                                title: "Targeted Dietary Advice",
                                content: report.dietaryAdvice
                            )

                            SectionCard(
                                icon: "book.fill",
                                iconColor: .purple,
                                title: "Medical Glossary",
                                content: report.medicalGlossary
                            )

                            SectionCard(
                                icon: "pill.fill",
                                iconColor: .orange,
                                title: "Medication Notes",
                                content: report.medicationNotes
                            )

                            // Entry point into the Meds tab. Opens the
                            // add sheet linked to this report so a med
                            // the user sets up traces back to its
                            // source scan. We don't auto-parse drug
                            // names out of the freeform notes — the
                            // user types what they're actually taking,
                            // keeping Localabs's "never invent a
                            // medication" contract intact.
                            Button {
                                showAddMed = true
                            } label: {
                                Label("Add a medication reminder", systemImage: "bell.badge")
                                    .font(.subheadline.weight(.medium))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                            }
                            .buttonStyle(.bordered)
                            .tint(.orange)
                            .padding(.top, 4)
                        }
                        .padding(.horizontal)
                    }

                    // "Regenerate Translation" lives at the bottom now —
                    // it's a rare, destructive action (it overwrites the
                    // current translation), so it belongs below the
                    // content the user actually reads, not competing with
                    // the document preview up top.
                    if let report = currentReport, !report.isIncomplete {
                        regenerateCTA(for: report)
                            .padding(.horizontal)
                            .padding(.top, 8)
                    }

                    if isPostScan {
                        Button {
                            // Pops back to ScanView's idle state, ready
                            // for the next document.
                            dismiss()
                        } label: {
                            Label("Scan Another Report", systemImage: "doc.text.viewfinder")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.horizontal)
                        .padding(.top, 8)
                    }

                    Spacer(minLength: 100)
                }
            }
            .scrollContentBackground(.hidden)
            .background(.background)
            .task {
                if dismissIfReportDeleted() { return }
                healthMetrics = await HealthKitService.shared.getHealthMetrics()
                if report == nil { report = initialReport }
                reloadLabTrends()
                loadPreviewImages()
                maybeSuggestOwnership()
            }
            .onChange(of: currentReport?.id) { _, _ in
                reloadLabTrends()
                loadPreviewImages()
                maybeSuggestOwnership()
            }
            // Tapping a preview page pushes the full document viewer
            // opened on that same page so the user keeps their place.
            .navigationDestination(isPresented: $showDocViewer) {
                if let report = currentReport {
                    DocumentViewerView(report: report, initialPage: docViewerPage)
                }
            }
            .alert("Whose report is this?", isPresented: $showOwnershipPrompt) {
                Button("It's mine") { setReportOwnership(toOther: false) }
                Button("Someone else's") { setReportOwnership(toOther: true) }
                Button("Decide later", role: .cancel) {}
            } message: {
                Text("This report's age or sex doesn't match your profile. If it's someone else's (like a family member's), Localabs will keep it out of your health trends and chats.")
            }
            // Recompute on every appearance too, so deleting another
            // report (e.g. from History) is reflected here without
            // needing the current report to change. Also pop back if
            // THIS report was the one deleted while we were off-screen.
            .onAppear {
                if dismissIfReportDeleted() { return }
                reloadLabTrends()
            }
            .sheet(isPresented: $showLabTrends) {
                LabComparisonView(trends: labTrends)
            }
            // ALWAYS sync the local @State to the most recent
            // initialReport. The previous logic only assigned in
            // `.task` when `report == nil`, which left the view
            // showing stale content if SwiftUI happened to reuse
            // the DashboardView instance for a new report. This was
            // the bug behind "I scan a multi-page Alzheimer's doc,
            // the model generates correct Alzheimer's content, but
            // the dashboard still shows the previous lipid scan."
            .onChange(of: initialReport?.id) { _, _ in
                report = initialReport
            }
            // Share button only appears when Dashboard is showing a
            // specific report (pushed from History or post-scan). The
            // empty tab state has nothing to share, so we hide it.
            .toolbar {
                if let report = currentReport, !report.isIncomplete {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            shareItems = buildShareItems(for: report)
                            showShareSheet = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("Share translation")
                    }
                }
            }
            .sheet(isPresented: $showShareSheet) {
                // Build items inside the sheet closure so they're
                // always fresh when SwiftUI presents — the previous
                // pattern (set shareItems on tap, then flip showSheet)
                // sometimes raced and presented with stale/empty
                // items, requiring a second tap to "warm up" the
                // sheet. Lazy construction avoids the race entirely.
                if let report = currentReport {
                    ShareSheet(items: buildShareItems(for: report))
                }
            }
            .sheet(isPresented: $showAddMed) {
                MedicationEditSheet(sourceReportID: currentReport?.id)
            }
    }

    // MARK: - Scan preview

    /// The visible page index (0-based), derived from the pager's scroll
    /// position with a sensible default before the first snap settles.
    private var currentPreviewPage: Int {
        scrolledPreviewPage ?? 0
    }

    /// Aspect ratio (width / height) used to size the pager. Taken from
    /// the first page so the preview matches the real document shape
    /// instead of a fixed, letterboxed height. Falls back to US-Letter
    /// portrait when there's nothing loaded yet.
    private var previewAspect: CGFloat {
        guard let first = previewImages.first, first.size.height > 0 else { return 8.5 / 11 }
        return first.size.width / first.size.height
    }

    /// Inline preview of the scanned pages inside one blue pane. The
    /// image area is swipe-only (a horizontal paging ScrollView — more
    /// reliable nested in the dashboard's vertical ScrollView than a
    /// `.page` TabView was) so dragging never accidentally navigates
    /// away. The "Ask More" footer at the bottom is the tap target: it
    /// opens the full document viewer (on the page currently showing) to
    /// pinch-zoom, circle values, and ask follow-up questions. Only
    /// rendered when `previewImages` is non-empty (guarded at the call
    /// site).
    private var scanPreviewCard: some View {
        // Height derived from the measured width + the document's aspect
        // ratio. Before the first width measurement lands we fall back to
        // a reasonable portrait height so layout doesn't jump to zero.
        let pageHeight = previewWidth > 0 ? previewWidth / previewAspect : 460

        return VStack(spacing: 12) {
            HStack {
                Label("Original Document", systemImage: "doc.text.image")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
            }

            // Swipe-only — no tap gesture here, so tapping a page just
            // settles the scroll instead of navigating.
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(Array(previewImages.enumerated()), id: \.offset) { idx, img in
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(width: previewWidth, height: pageHeight)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .id(idx)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $scrolledPreviewPage)
            .frame(height: pageHeight)
            // Measure the pager's content width so each page can be sized
            // to exactly one viewport (clean paging) at the real aspect.
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { previewWidth = $0 }

            // Apple-style page dots (white on the blue pane).
            if previewImages.count > 1 {
                HStack(spacing: 7) {
                    ForEach(previewImages.indices, id: \.self) { i in
                        Circle()
                            .fill(i == currentPreviewPage
                                  ? Color.white
                                  : Color.white.opacity(0.4))
                            .frame(width: 7, height: 7)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: currentPreviewPage)
            }

            // The tap target — opens the viewer on the page in view.
            Button {
                docViewerPage = currentPreviewPage
                showDocViewer = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "hand.point.up.left.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .symbolEffect(.pulse, options: .repeat(.continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ask More About Your Scan")
                            .font(.system(size: 16, weight: .bold))
                        Text("Open to circle any value and dig deeper")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .foregroundStyle(.white)
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity)
                .background(
                    Color.white.opacity(0.16),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(
            LinearGradient(
                colors: [Color.blue, Color.blue.opacity(0.82)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .shadow(color: Color.blue.opacity(0.28), radius: 14, y: 6)
    }

    /// Load the saved page JPEGs for the inline preview. These are the
    /// already-downsampled scans written at intake, so decoding them for
    /// a thumbnail strip is cheap. Resets the visible page if the new
    /// report has fewer pages than wherever we were.
    private func loadPreviewImages() {
        let urls = currentReport?.allImageURLs ?? []
        var images: [UIImage] = []
        for url in urls {
            if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                images.append(image)
            }
        }
        previewImages = images
        scrolledPreviewPage = images.isEmpty ? nil : 0
    }

    // MARK: - Lab trend card (#28)

    /// Tappable card summarizing how this report's markers compare to
    /// past reports. Turns into a warning when any marker is on a
    /// sustained worsening streak. Hidden entirely when there's
    /// nothing to compare (handled at the call site).
    private var labTrendCard: some View {
        let worsening = labTrends.filter { $0.isWorseningStreak() }
        let isWarning = !worsening.isEmpty
        return Button {
            showLabTrends = true
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: isWarning ? "exclamationmark.triangle.fill" : "chart.xyaxis.line")
                        .foregroundStyle(isWarning ? .orange : .blue)
                    Text(isWarning ? "Markers trending the wrong way" : "Compared to your past reports")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                Text(labTrendSummaryLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(isWarning ? Color.orange.opacity(0.10) : Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(isWarning ? Color.orange.opacity(0.30) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var labTrendSummaryLine: String {
        let worsening = labTrends.filter { $0.isWorseningStreak() }
        if !worsening.isEmpty {
            let names = worsening.map(\.canonicalName).joined(separator: ", ")
            return "\(names) — worth discussing with your doctor. Tap to see the trend."
        }
        let improved = labTrends.filter { $0.change == .improved }.count
        let worsened = labTrends.filter { $0.change == .worsened }.count
        let stable = labTrends.filter { $0.change == .stable }.count
        var parts: [String] = []
        if improved > 0 { parts.append("\(improved) improved") }
        if worsened > 0 { parts.append("\(worsened) worsened") }
        if stable > 0 { parts.append("\(stable) stable") }
        return parts.isEmpty
            ? "\(labTrends.count) marker\(labTrends.count == 1 ? "" : "s") tracked over time"
            : parts.joined(separator: " · ")
    }

    private func reloadLabTrends() {
        // No "what changed vs your reports" card for a report that
        // isn't the user's — it isn't part of their trends at all.
        guard let report = currentReport, report.isOwnReport else { labTrends = []; return }
        let history = LocalStorageService.shared.getHistory()
        labTrends = LabTrendService.comparison(for: report, in: history)
    }

    /// Prompt the user when the report's printed age OR sex clearly
    /// can't be theirs, and they haven't already decided whose report
    /// it is. Either signal alone is enough.
    /// If the report this dashboard is showing has been deleted (e.g.
    /// from the History tab) while the view was off-screen, there's
    /// nothing left to display — pop back to whatever pushed us rather
    /// than render a phantom report (and, worse, prompt to mark a
    /// deleted report as someone else's). Skipped while a scan is still
    /// in flight, since an in-progress report isn't in history yet.
    /// Returns true if it dismissed, so callers can bail out.
    @discardableResult
    private func dismissIfReportDeleted() -> Bool {
        guard !engine.isProcessing else { return false }
        guard let id = (report ?? initialReport)?.id else { return false }
        let exists = LocalStorageService.shared.getHistory().contains { $0.id == id }
        if !exists {
            dismiss()
            return true
        }
        return false
    }

    private func maybeSuggestOwnership() {
        guard let report = currentReport, report.belongsToOther == nil else { return }
        // Never prompt about a report that no longer exists in storage
        // (deleted from History before this fired).
        guard LocalStorageService.shared.getHistory().contains(where: { $0.id == report.id }) else { return }
        let profile = UserProfile.load()

        // Age mismatch: a gap beyond ~6 years vs the date-adjusted
        // expected age isn't explained by the report's recency.
        var ageMismatch = false
        if let reportAge = report.reportPatientAge, let profileAge = profile.ageYears {
            let yearsAgo = Calendar.current.dateComponents([.year], from: report.effectiveDate, to: Date()).year ?? 0
            let expected = profileAge - max(0, yearsAgo)
            ageMismatch = abs(reportAge - expected) > 6
        }

        // Sex mismatch: report says one binary sex, profile says the
        // other. Only fires when both are Male/Female (skip "Other"
        // and unset, which can't be cleanly compared).
        var sexMismatch = false
        let profileSex = profile.biologicalSex.trimmingCharacters(in: .whitespaces).lowercased()
        if let reportSex = report.reportPatientSex?.lowercased(),
           ["male", "female"].contains(profileSex),
           ["male", "female"].contains(reportSex) {
            sexMismatch = profileSex != reportSex
        }

        if ageMismatch || sexMismatch {
            showOwnershipPrompt = true
        }
    }

    /// Persist the user's answer to the ownership prompt (or the
    /// "it's mine" case, which just records the decision so we don't
    /// ask again).
    private func setReportOwnership(toOther: Bool) {
        guard var r = currentReport else { return }
        r.belongsToOther = toOther
        report = r
        LocalStorageService.shared.saveReport(r)
        reloadLabTrends()
    }

    private var currentReport: StructuredReport? {
        report ?? initialReport
    }

    // MARK: - Status badge

    /// Reflects the *actual* state of the underlying analysis, not just
    /// "do we have a report object." Pause/resume in particular needs
    /// to surface as "Paused" rather than "Analyzed" — the report
    /// object exists but the run never finished.
    private var statusValue: String {
        if engine.isPaused { return "Paused" }
        if engine.isProcessing { return "Analyzing" }
        if let report = currentReport {
            return report.isIncomplete ? "Paused" : "Analyzed"
        }
        return "Pending"
    }

    private var statusColor: Color {
        if engine.isPaused { return .orange }
        if let report = currentReport, report.isIncomplete { return .orange }
        if engine.isProcessing { return .blue }
        if currentReport != nil { return .green }
        return .secondary
    }

    // MARK: - Report-time Apple Health snapshot

    /// "Apple Health used in this analysis" card. Shows the exact
    /// metrics InferenceEngine read when building the prompt — same
    /// struct, same averages — so the user can see at a glance what
    /// informed the empathetic translation. Cells are skipped when
    /// the underlying metric is nil, so phone-only users (no Watch)
    /// just see steps + walking + exercise without "—" filler.
    private func healthUsedInAnalysisCard(_ metrics: HealthKitService.HealthMetrics) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "heart.text.square.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.pink)
                Text("APPLE HEALTH USED IN THIS ANALYSIS")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(1.4)
            }

            Text("Localabs folded these 30-day averages from Apple Health into the report's interpretation. Metrics you haven't logged or granted access to are skipped.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ], spacing: 12) {
                if let v = metrics.avgRestingHR {
                    snapshotPill(label: "Resting HR", value: "\(Int(v))", unit: "bpm", tint: .red)
                }
                if let v = metrics.avgHRV {
                    snapshotPill(label: "HRV", value: "\(Int(v))", unit: "ms", tint: .red)
                }
                if let v = metrics.avgSleepHours {
                    snapshotPill(label: "Avg Sleep", value: String(format: "%.1f", v), unit: "h", tint: .purple)
                }
                if let v = metrics.avgSteps {
                    snapshotPill(label: "Avg Steps", value: "\(Int(v))", unit: "/day", tint: .blue)
                }
                if let v = metrics.avgWalkingDistanceMiles {
                    snapshotPill(label: "Avg Walk", value: String(format: "%.2f", v), unit: "mi/day", tint: .blue)
                }
                if let v = metrics.avgWalkingSpeedMPH {
                    snapshotPill(label: "Walk Speed", value: String(format: "%.2f", v), unit: "mph", tint: .indigo)
                }
                if let v = metrics.avgExerciseMinutes {
                    snapshotPill(label: "Exercise", value: "\(Int(v))", unit: "min/day", tint: .green)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func snapshotPill(label: String, value: String, unit: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.8)
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 20, weight: .bold).monospacedDigit())
                    .foregroundStyle(tint)
                Text(unit)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    // MARK: - Regenerate CTA

    /// Lives at the bottom of the dashboard (it's a rare, destructive
    /// overwrite). Tints purple to read as distinct from the rest of the
    /// surface. Tapping triggers the regeneration; while in flight the
    /// card swaps to a determinate progress view bound to
    /// engine.analysisProgress so the user sees the same live feedback
    /// as a fresh scan instead of an opaque spinner.
    private func regenerateCTA(for report: StructuredReport) -> some View {
        Group {
            if isRegenerating {
                regenerateProgressCard
            } else {
                Button {
                    showRegenConfirm = true
                } label: {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.22))
                                .frame(width: 44, height: 44)
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Regenerate Translation")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(.white)
                            Text("Re-run Localabs against the same scan")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.88))
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity)
                    .background(
                        LinearGradient(
                            colors: [Color.purple, Color.purple.opacity(0.82)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: Color.purple.opacity(0.28), radius: 12, y: 5)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// In-flight regenerate state — same shape/size as the resting
    /// button so the layout doesn't reflow when tapped. Shows the
    /// live percentage and the determinate progress bar bound to
    /// engine.analysisProgress.
    private var regenerateProgressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(.purple.opacity(0.18))
                        .frame(width: 44, height: 44)
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.purple)
                        .symbolEffect(.rotate, options: .repeat(.continuous))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Regenerating…")
                        .font(.system(size: 17, weight: .bold))
                    Text(engine.processingStatus.isEmpty
                         ? "Re-running Localabs against the same scan"
                         : engine.processingStatus)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text("\(Int(engine.analysisProgress * 100))%")
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: engine.analysisProgress))
            }
            ProgressView(value: engine.analysisProgress)
                .tint(.purple)
                .animation(.easeOut(duration: 0.25), value: engine.analysisProgress)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular.tint(.purple.opacity(0.18)), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: - Share

    /// Bundles a single report's translation text + scan images for
    /// the system share sheet. Mirrors the multi-report payload built
    /// by HistoryView but for one report; recipients see the section
    /// breakdown followed by the original scans as attachments.
    private func buildShareItems(for report: StructuredReport) -> [Any] {
        var items: [Any] = []
        items.append(shareText(for: report))
        for url in report.allImageURLs {
            if let img = UIImage(contentsOfFile: url.path) {
                items.append(img)
            }
        }
        return items
    }

    private func shareText(for report: StructuredReport) -> String {
        var lines: [String] = []
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        lines.append("Localabs Report — \(df.string(from: report.timestamp))")
        lines.append("")
        appendSection(&lines, title: "PATIENT SUMMARY", body: report.patientSummary)
        appendSection(&lines, title: "QUESTIONS FOR YOUR DOCTOR", body: report.doctorQuestions)
        appendSection(&lines, title: "TARGETED DIETARY ADVICE", body: report.dietaryAdvice)
        appendSection(&lines, title: "MEDICAL GLOSSARY", body: report.medicalGlossary)
        appendSection(&lines, title: "MEDICATION NOTES", body: report.medicationNotes)
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func appendSection(_ lines: inout [String], title: String, body: String) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lines.append(title)
        lines.append(trimmed)
        lines.append("")
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Summary")
                .font(.system(size: 20, weight: .bold))
                .frame(maxWidth: .infinity, alignment: .leading)

            // Renders Localabs's markdown (bold/italic/emoji) inline, line
            // by line so per-sentence selection works. Falls back to a
            // plain placeholder when no scan exists.
            if let report = currentReport {
                MarkdownBody(report.patientSummary)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
            } else {
                Text("Your lab report has not been scanned yet. Once you scan a document, Localabs will analyze it on-device and provide a simple, easy-to-read summary here.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func regenerate() async {
        guard let existing = currentReport else { return }
        isRegenerating = true
        defer { isRegenerating = false }
        report = await engine.regenerateReport(from: existing)
    }

    /// Slim, single-line hint that points the user back to the Scan
    /// tab where the paused analysis is actually preserved. Replaces
    /// the old big orange Resume banner — that banner caused two
    /// problems: it implied the dashboard was the resume venue (it
    /// wasn't — the streaming UI lives in ScanView), and it duplicated
    /// the Dashboard tab whenever the post-scan auto-push landed on
    /// top of an incomplete result.
    private func pausedAnalysisBadge(switchTo selectedTab: Binding<Int>) -> some View {
        Button {
            selectedTab.wrappedValue = 0  // Scan tab
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.orange)
                    .symbolRenderingMode(.hierarchical)
                Text("Analysis paused — open Scan tab to resume")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.tint(.orange.opacity(0.18)), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

}

// MARK: - Sub-components

struct StatusBadge: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct MetricPill: View {
    let value: String
    let unit: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.blue)
                Text(unit)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.blue.opacity(0.7))
            }
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.blue.opacity(0.7))
        }
    }
}
