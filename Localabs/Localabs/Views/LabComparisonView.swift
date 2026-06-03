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
    /// Notifies the parent (Trends tab) when the pin state changes so it
    /// can re-sort pinned markers to the top. Optional — the comparison
    /// sheet doesn't re-sort.
    var onTrackToggle: (() -> Void)? = nil
    @State private var tracked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(trend.canonicalName)
                    .font(.body.weight(.semibold))
                // Pin to follow this marker in Health Trends (#31). Filled
                // when tracked; tap toggles.
                Button {
                    if tracked {
                        TrackedMarkers.remove(trend.canonicalName)
                    } else {
                        TrackedMarkers.add(trend.canonicalName)
                    }
                    tracked.toggle()
                    onTrackToggle?()
                } label: {
                    Image(systemName: tracked ? "pin.fill" : "pin")
                        .font(.system(size: 12))
                        .foregroundStyle(tracked ? .blue : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tracked ? "Stop tracking \(trend.canonicalName)" : "Track \(trend.canonicalName)")
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
        .onAppear { tracked = TrackedMarkers.isTracked(trend.canonicalName) }
    }

    /// Line + point chart of the marker over its report dates —
    /// same visual language as the Apple Health metric charts, with
    /// the lab's normal range drawn as dashed boundary lines.
    private var chart: some View {
        Chart {
            // Normal-range boundary lines (the lab's own reference
            // range). Dashed, muted green, so the user can see at a
            // glance whether a reading is inside or outside normal.
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
