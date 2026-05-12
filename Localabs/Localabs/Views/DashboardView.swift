import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var engine: InferenceEngine
    /// Bound from ContentView when Dashboard is shown as a tab so the
    /// "paused analysis" badge can switch the user back to Scan tab.
    /// Nil when Dashboard is pushed onto a NavigationStack (post-scan,
    /// History detail) — in those routes we don't show the badge.
    var selectedTab: Binding<Int>?
    var initialReport: StructuredReport?
    @State private var report: StructuredReport?
    @State private var healthMetrics: HealthKitService.HealthMetrics?
    @State private var isRegenerating = false

    var body: some View {
        NavigationStack {
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
                                value: currentReport != nil ? "Analyzed" : "Pending",
                                color: currentReport != nil ? .green : .secondary
                            )
                            StatusBadge(label: "Health Sync", value: "Active", color: .blue)
                        }
                    }
                    .padding(.horizontal)

                    summaryCard
                        .padding(.horizontal)

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

                    healthMetricsCard
                        .padding(.horizontal)
                        .padding(.bottom, 100)
                }
            }
            .scrollContentBackground(.hidden)
            .background(.background)
            .task {
                healthMetrics = await HealthKitService.shared.getHealthMetrics()
                if report == nil { report = initialReport }
            }
        }
    }

    private var currentReport: StructuredReport? {
        report ?? initialReport
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Empathetic Translation")
                    .font(.system(size: 20, weight: .bold))
                Spacer()
                // Hide the regenerate icon when the report is incomplete —
                // the orange "Resume Analysis" banner above already
                // surfaces that action much more prominently.
                if let report = currentReport, !report.isIncomplete {
                    Button {
                        Task { await regenerate() }
                    } label: {
                        if isRegenerating {
                            ProgressView().scaleEffect(0.85)
                        } else {
                            Image(systemName: "arrow.clockwise.circle.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(.blue, .blue.opacity(0.18))
                                .symbolRenderingMode(.hierarchical)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isRegenerating)
                    .accessibilityLabel("Regenerate report")
                }
            }

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

    private var healthMetricsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Apple Health")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.blue)

            if let metrics = healthMetrics {
                if metrics.isEmpty {
                    // Honest empty state — no demo numbers. Covers
                    // both "user hasn't connected Apple Health" and
                    // "connected but no recent data was found in the
                    // 30-day window we query."
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No Apple Health data yet")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text("Connect Apple Health in Profile to bring resting HR, HRV, and sleep into your reports.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    // Each pill renders an em-dash when its metric is
                    // missing rather than zeroing out — keeps partial
                    // permissions readable instead of misleading.
                    HStack {
                        MetricPill(
                            value: metrics.avgRestingHR.map { "\(Int($0))" } ?? "—",
                            unit: "bpm",
                            label: "Resting HR"
                        )
                        Spacer()
                        MetricPill(
                            value: metrics.avgSleepHours.map { String(format: "%.1f", $0) } ?? "—",
                            unit: "h",
                            label: "Avg Sleep"
                        )
                        Spacer()
                        MetricPill(
                            value: metrics.avgHRV.map { "\(Int($0))" } ?? "—",
                            unit: "ms",
                            label: "HRV"
                        )
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
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
