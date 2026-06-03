import SwiftUI

/// The liquid-glass action menu that pops up from a tapped scan
/// highlight (#31). Shared by the document viewer and the dashboard
/// scan preview so the actions and their "added" states stay identical.
///
/// "Ask Localabs about this" and "Add to Meds" are host-specific — the
/// viewer selects a block and opens its in-place chat, the dashboard
/// presents one — so they're passed in as closures. The Health-Trend
/// toggle is self-contained (it just writes `TrackedMarkers`).
struct EntityActionMenu: View {
    let entity: HighlightEntity
    let onAsk: () -> Void
    let onAddMedication: (DetectedMedication) -> Void
    /// Bumped when the user tracks/untracks a marker so the label flips
    /// in place between "Add to Health Trend" and "Added to Health Trends".
    @State private var version = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entity.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                if let sub = entity.subtitle {
                    Text(sub)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Button(action: onAsk) {
                rowLabel("Ask Localabs about this", "sparkles", .primary)
            }
            .buttonStyle(.plain)

            primaryAction
        }
        .padding(14)
        .frame(width: 232)
        .glassEffect(
            .regular.tint(.blue.opacity(0.12)),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch entity {
        case .medication(let med):
            let added = Medication.loadAll().contains {
                $0.name.caseInsensitiveCompare(med.name) == .orderedSame
            }
            if added {
                rowLabel("Already added to Meds", "checkmark.circle.fill", .green)
            } else {
                Button {
                    onAddMedication(med)
                } label: {
                    rowLabel("Add to Meds", "pills.fill", .orange)
                }
                .buttonStyle(.plain)
            }

        case .labValue(let lv):
            // `version` referenced so the toggle re-renders this row.
            let _ = version
            let tracked = TrackedMarkers.isTracked(lv.canonicalName)
            Button {
                if tracked {
                    TrackedMarkers.remove(lv.canonicalName)
                } else {
                    TrackedMarkers.add(lv.canonicalName)
                }
                version += 1
            } label: {
                rowLabel(
                    tracked ? "Added to Health Trends" : "Add to Health Trend",
                    tracked ? "checkmark.circle.fill" : "chart.line.uptrend.xyaxis",
                    tracked ? .green : .blue
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func rowLabel(_ text: String, _ icon: String, _ color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension HighlightEntity {
    /// Match OCR block texts to the report's important entities: every
    /// detected medication, plus lab values that are out of range. Used
    /// by both the viewer and the dashboard preview so they highlight
    /// exactly the same things. Copy-only — a block matches only when its
    /// text actually contains the entity name.
    static func match(blocks: [(id: UUID, text: String)], in report: StructuredReport) -> [UUID: HighlightEntity] {
        let meds = report.detectedMedications ?? []
        let notable = (report.labValues ?? []).filter(\.isOutOfRange)
        guard !meds.isEmpty || !notable.isEmpty else { return [:] }

        var map: [UUID: HighlightEntity] = [:]
        for block in blocks {
            let lower = block.text.lowercased()
            if let med = meds.first(where: { !$0.name.isEmpty && lower.contains($0.name.lowercased()) }) {
                map[block.id] = .medication(med)
            } else if let lv = notable.first(where: { !$0.rawName.isEmpty && lower.contains($0.rawName.lowercased()) }) {
                map[block.id] = .labValue(lv)
            }
        }
        return map
    }
}
