import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var engine: InferenceEngine
    var initialReport: StructuredReport?
    @State private var report: StructuredReport?
    @State private var healthMetrics: HealthKitService.HealthMetrics?
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Title
                    Text("Translation Dashboard")
                        .font(.system(size: 34, weight: .bold))
                        .padding(.horizontal)
                        .padding(.top, 8)
                    
                    // Status Badges
                    HStack(spacing: 14) {
                        StatusBadge(label: "Status", value: currentReport != nil ? "Analyzed" : "Pending", color: currentReport != nil ? .green : .secondary)
                        StatusBadge(label: "Health Sync", value: "Active", color: .blue)
                    }
                    .padding(.horizontal)
                    
                    // Patient Summary Card
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Empathetic Translation")
                                .font(.system(size: 20, weight: .bold))
                            
                            Text(currentReport?.patientSummary ?? "Your lab report has not been scanned yet. Once you scan a document, the local MedGemma AI will analyze it and provide a simple, easy-to-read summary here.")
                                .font(.system(size: 15))
                                .foregroundStyle(.secondary)
                                .lineSpacing(4)
                        }
                    }
                    .backgroundStyle(.ultraThinMaterial)
                    .padding(.horizontal)
                    
                    // Advanced AI Insight Cards
                    if let report = currentReport {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("AI INSIGHTS")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .tracking(1.5)
                                .padding(.horizontal, 20)
                            
                            // View Original Scan button
                            if report.imagePath != nil {
                                NavigationLink {
                                    DocumentViewerView(report: report)
                                } label: {
                                    GroupBox {
                                        HStack(spacing: 12) {
                                            ZStack {
                                                Circle()
                                                    .fill(.blue.opacity(0.12))
                                                    .frame(width: 40, height: 40)
                                                Image(systemName: "doc.text.magnifyingglass")
                                                    .font(.system(size: 18))
                                                    .foregroundColor(.blue)
                                            }
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text("View Original Scan")
                                                    .font(.system(size: 16, weight: .semibold))
                                                    .foregroundColor(.primary)
                                                Text("Tap text to highlight & ask follow-up questions")
                                                    .font(.system(size: 12))
                                                    .foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.system(size: 14, weight: .semibold))
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                    .backgroundStyle(.ultraThinMaterial)
                                }
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
                    
                    // Apple Health Metrics
                    GroupBox {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Apple Health Integrations")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundColor(.blue)
                            
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
                    }
                    .backgroundStyle(Color.blue.opacity(0.08))
                    .padding(.horizontal)
                    .padding(.bottom, 100)
                }
            }
            .task {
                healthMetrics = await HealthKitService.shared.getHealthMetrics()
                if report == nil { report = initialReport }
            }
        }
    }
    
    private var currentReport: StructuredReport? {
        report ?? initialReport
    }
}

// MARK: - Sub-components

struct StatusBadge: View {
    let label: String
    let value: String
    let color: Color
    
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(color)
            }
        }
        .backgroundStyle(.ultraThinMaterial)
        .frame(maxWidth: .infinity, alignment: .leading)
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
                    .foregroundColor(.blue)
                Text(unit)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.blue.opacity(0.7))
            }
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.blue.opacity(0.7))
        }
    }
}
