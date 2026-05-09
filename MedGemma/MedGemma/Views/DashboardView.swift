import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var engine: InferenceEngine
    var initialReport: StructuredReport?
    @State private var report: StructuredReport?
    @State private var healthMetrics: HealthKitService.HealthMetrics?

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

                    // Pulled out of the AI Insights stack and moved up so
                    // it's the first action after the summary — the document
                    // viewer is where most users will spend their time.
                    if let report = currentReport, report.imagePath != nil {
                        NavigationLink {
                            DocumentViewerView(report: report)
                        } label: {
                            askMoreCTA
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal)
                    }

                    if let report = currentReport {
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
            Text("Empathetic Translation")
                .font(.system(size: 20, weight: .bold))

            Text(currentReport?.patientSummary ?? "Your lab report has not been scanned yet. Once you scan a document, the local MedGemma AI will analyze it and provide a simple, easy-to-read summary here.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .lineSpacing(4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
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
                HStack {
                    MetricPill(value: "\(Int(metrics.avgRestingHR ?? 0))", unit: "bpm", label: "Resting HR")
                    Spacer()
                    MetricPill(value: String(format: "%.1f", metrics.avgSleepHours ?? 0), unit: "h", label: "Avg Sleep")
                    Spacer()
                    MetricPill(value: "\(Int(metrics.avgHRV ?? 0))", unit: "ms", label: "HRV")
                }

                if metrics.isMockData {
                    Text("HealthKit data unavailable — showing demo values.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
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
