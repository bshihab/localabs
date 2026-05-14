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

    var body: some View {
        NavigationStack {
            if isRegenerating {
                regeneratingView
            } else {
                dashboardContent
            }
        }
        .confirmationDialog(
            "Regenerate translation?",
            isPresented: $showRegenConfirm,
            titleVisibility: .visible
        ) {
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
                        Text("Regenerating")
                            .font(.system(size: 17, weight: .semibold))
                        // Allow the status to wrap to two lines so
                        // "Localabs is regenerating your report…"
                        // doesn't truncate to "…your repo".
                        Text(engine.processingStatus.isEmpty
                             ? "Re-running Localabs against the same scan…"
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
                Text("Translation Dashboard")
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

                    // Prominent "Regenerate Translation" CTA — sits
                    // between the summary card and Ask More, sized
                    // slightly smaller than askMoreCTA so the visual
                    // hierarchy puts the document viewer first. When
                    // tapped it transforms in place into a progress
                    // bar bound to engine.analysisProgress so the user
                    // gets the same live feedback as a fresh analysis.
                    if let report = currentReport, !report.isIncomplete {
                        regenerateCTA(for: report)
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

                    // Pulled out of the AI Insights stack and moved up so
                    // it's the first action after the summary — the document
                    // viewer is where most users will spend their time.
                    // Hidden for incomplete reports (no useful content to
                    // explore until they Resume).
                    if let report = currentReport, report.imagePath != nil, !report.isIncomplete {
                        NavigationLink {
                            DocumentViewerView(report: report)
                        } label: {
                            askMoreCTA
                        }
                        .buttonStyle(.plain)
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
                        }
                        .padding(.horizontal)
                    }

                    Spacer(minLength: 100)
                }
            }
            .scrollContentBackground(.hidden)
            .background(.background)
            .task {
                healthMetrics = await HealthKitService.shared.getHealthMetrics()
                if report == nil { report = initialReport }
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

    /// Sized roughly to match the askMoreCTA card so the two read as a
    /// matched pair. Tints purple so it's visually distinct from the
    /// blue askMoreCTA below. Tapping triggers the regeneration; while
    /// in flight the card swaps to a determinate progress view bound
    /// to engine.analysisProgress so the user sees the same live
    /// feedback as a fresh scan instead of an opaque spinner.
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
            Text("Empathetic Translation")
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

    /// Prominent call-to-action that opens the interactive document viewer.
    /// Bold gradient, white text, animated SF Symbol — sits right under the
    /// summary card so it's the first thing the user reaches for after
    /// reading the AI's translation.
    private var askMoreCTA: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.22))
                    .frame(width: 52, height: 52)
                Image(systemName: "hand.point.up.left.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    // SF Symbols' built-in pulse — Apple's own subtle bounce
                    // that signals "interactive" without being distracting.
                    .symbolEffect(.pulse, options: .repeat(.continuous))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Ask More About Your Scan")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(.white)
                Text("Circle any value or section to dig deeper")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [Color.blue, Color.blue.opacity(0.82)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: Color.blue.opacity(0.28), radius: 14, y: 6)
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
