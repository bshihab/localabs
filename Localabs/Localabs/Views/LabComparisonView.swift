import SwiftUI

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

            Text(trajectoryText)
                .font(.callout)
                .foregroundStyle(.secondary)

            if trend.isWorseningStreak() {
                Label("Trending the wrong way across your last \(trend.points.count) reports", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
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
