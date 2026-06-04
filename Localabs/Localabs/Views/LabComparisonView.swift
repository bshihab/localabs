import SwiftUI
import Charts

/// Shows how the user's lab markers have moved across reports (#28).
/// Presented as a sheet from the Dashboard "what changed" card and
/// reused as the row content in the Trends tab's lab-values section.
///
/// Intentionally text-based (trajectory rendered as "130 → 145 → 160"
/// with a status chip) rather than charted — it reads clearly at a
/// glance, needs no Charts plumbing, and keeps the view simple.
struct LabComparisonView: View {
    let trends: [LabTrend]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if trends.isEmpty {
                    emptyState
                } else {
                    List {
                        Section {
                            ForEach(trends) { LabTrendRow(trend: $0) }
                        } footer: {
                            Text("Trends compare the same marker across your scanned reports. They're informational — discuss any sustained change with your doctor. Localabs is not a diagnostic.")
                        }
                    }
                }
            }
            .navigationTitle("Lab Trends")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
                .opacity(0.6)
            Text("No lab trends yet")
                .font(.title3.weight(.semibold))
            Text("Once you've scanned two or more reports that share a lab marker — like cholesterol or A1c — Localabs will track how it's changing here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .padding(.top, 60)
        .frame(maxWidth: .infinity)
    }
}

/// One marker's row: name, the value trajectory, and a status chip.
struct LabTrendRow: View {
    let trend: LabTrend

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(trend.canonicalName)
                    .font(.body.weight(.semibold))
                Spacer()
                statusChip
            }

            chart

            HStack(spacing: 8) {
                Text(trajectoryText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let range = trend.referenceRangeLabel {
                    Spacer(minLength: 4)
                    Text("Normal: \(range)\(trend.unit.isEmpty ? "" : " \(trend.unit)")")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }

            if trend.isWorseningStreak() {
                Label("Trending the wrong way across your last \(trend.points.count) reports", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }

    /// Line + point chart of the marker over its report dates —
    /// same visual language as the Apple Health metric charts, with
    /// the lab's normal range drawn as dashed boundary lines.
    private var chart: some View {
        Chart {
            // Normal-range boundary lines (dashed, muted green). When every
            // report agrees on the range we draw two full-width rule lines.
            // When reports disagree (different labs, or an age-shifting
            // marker over a long span) we draw a STEPPED band instead, so
            // you can see the normal range change over time. Printed ranges
            // define the band; AI-filled ones are used only if nothing was
            // printed (see `bandPoints`).
            if bandVaries {
                ForEach(bandPoints) { p in
                    if let lo = p.lower {
                        LineMark(x: .value("Date", p.date),
                                 y: .value("Lower", lo),
                                 series: .value("band", "lower"))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .foregroundStyle(.green.opacity(0.5))
                            .interpolationMethod(.stepEnd)
                    }
                }
                ForEach(bandPoints) { p in
                    if let hi = p.upper {
                        LineMark(x: .value("Date", p.date),
                                 y: .value("Upper", hi),
                                 series: .value("band", "upper"))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .foregroundStyle(.green.opacity(0.5))
                            .interpolationMethod(.stepEnd)
                    }
                }
            } else {
                if let lo = trend.referenceLower {
                    RuleMark(y: .value("Lower", lo))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(.green.opacity(0.5))
                }
                if let hi = trend.referenceUpper {
                    RuleMark(y: .value("Upper", hi))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(.green.opacity(0.5))
                }
            }

            ForEach(trend.points) { point in
            AreaMark(
                x: .value("Date", point.date),
                y: .value(trend.canonicalName, point.value)
            )
            .foregroundStyle(LinearGradient(
                colors: [lineColor.opacity(0.30), lineColor.opacity(0.02)],
                startPoint: .top,
                endPoint: .bottom
            ))
            .interpolationMethod(.catmullRom)

            LineMark(
                x: .value("Date", point.date),
                y: .value(trend.canonicalName, point.value)
            )
            .foregroundStyle(lineColor)
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .interpolationMethod(.catmullRom)

            PointMark(
                x: .value("Date", point.date),
                y: .value(trend.canonicalName, point.value)
            )
            .foregroundStyle(lineColor)
            .symbolSize(28)
            }  // ForEach
        }  // Chart
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: min(trend.points.count, 4))) { value in
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    .font(.caption2)
            }
        }
        .frame(height: 90)
    }

    /// Points that define the chart's normal band. Prefer the reports
    /// that PRINTED a range (the real numbers); only fall back to the
    /// AI-filled ones if no report printed a range at all. Stepping over
    /// these is what lets the band change across time.
    private var bandPoints: [LabTrend.Point] {
        let printed = trend.points.filter { $0.rangeFromReport && ($0.lower != nil || $0.upper != nil) }
        if !printed.isEmpty { return printed }
        return trend.points.filter { $0.lower != nil || $0.upper != nil }
    }

    /// True when the band's reports don't all agree on the range — only
    /// then do we draw the stepped band instead of clean full-width lines.
    private var bandVaries: Bool {
        let los = Set(bandPoints.compactMap { $0.lower })
        let his = Set(bandPoints.compactMap { $0.upper })
        return los.count > 1 || his.count > 1
    }

    /// Chart line color follows the marker's status, matching the chip.
    private var lineColor: Color {
        switch trend.change {
        case .improved: return .green
        case .worsened: return .orange
        default:        return .blue
        }
    }

    /// "130 → 145 → 160 mg/dL"
    private var trajectoryText: String {
        let nums = trend.points.map { Self.format($0.value) }.joined(separator: " → ")
        return trend.unit.isEmpty ? nums : "\(nums) \(trend.unit)"
    }

    @ViewBuilder
    private var statusChip: some View {
        let (label, color) = chipStyle
        Text(label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.16)))
            .foregroundStyle(color)
    }

    private var chipStyle: (String, Color) {
        switch trend.change {
        case .improved: return ("Improved", .green)
        case .worsened: return ("Worsening", .orange)
        case .stable:   return ("Stable", .secondary)
        case .changed:  return ("Changed", .blue)
        case .none:     return ("—", .secondary)
        }
    }

    private static func format(_ value: Double) -> String {
        value.rounded() == value
            ? String(format: "%.0f", value)
            : String(format: "%.1f", value)
    }
}
