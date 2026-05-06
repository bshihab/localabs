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

                    if let report = currentReport {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("AI INSIGHTS")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .tracking(1.5)
                                .padding(.horizontal, 20)

                            if report.imagePath != nil {
                                NavigationLink {
                                    DocumentViewerView(report: report)
                                } label: {
                                    viewScanRow
                                }
                                .buttonStyle(.plain)
                            }

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

    private var viewScanRow: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(.blue.opacity(0.16))
                    .frame(width: 40, height: 40)
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 18))
                    .foregroundStyle(.blue)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("View Original Scan")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("Tap text to highlight & ask follow-up questions")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
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
