import SwiftUI

/// The liquid-glass action menu that pops up from a tapped scan
/// highlight (#31). Shared by the document viewer and the dashboard
/// scan preview so the actions and their on/off states stay identical.
///
/// "Ask Localabs about this" is host-specific (the viewer selects a
/// block and opens its in-place chat; the dashboard presents one), so
/// it's passed in. The "Add to Meds" and "Add to Health Trend" controls
/// are self-contained **toggles** — flip them on to add, off to remove —
/// so the menu always reflects, and lets the user change, the current
/// state right there.
struct EntityActionMenu: View {
    let entity: HighlightEntity
    let onAsk: () -> Void
    /// Opens the Meds editor (host-presented) so the user can set the
    /// dose/schedule when adding a medication.
    let onAddMedication: (DetectedMedication) -> Void
    /// Bumped whenever a toggle changes so the labels/switch states
    /// re-read their backing stores and update in place.
    @State private var version = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                Label("Ask Localabs about this", systemImage: "sparkles")
                    .font(.system(size: 14, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            primaryToggle
        }
        .padding(14)
        .frame(width: 248)
        .glassEffect(
            .regular.tint(.blue.opacity(0.12)),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }

    @ViewBuilder
    private var primaryToggle: some View {
        // `version` is read so flipping a toggle re-renders this row.
        let _ = version
        switch entity {
        case .medication(let med):
            if isMedAdded(med) {
                // Already tracked — show status; manage it in the Meds tab.
                Label("Added to Meds", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // Opens the editor so the user can set dose/schedule/dates.
                Button {
                    onAddMedication(med)
                } label: {
                    Label("Add to Meds", systemImage: "pills.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }

        case .labValue(let lv):
            let tracked = TrackedMarkers.isTracked(lv.canonicalName)
            Toggle(isOn: trendBinding(lv)) {
                Label(
                    tracked ? "Added to Health Trends" : "Add to Health Trend",
                    systemImage: "chart.line.uptrend.xyaxis"
                )
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tracked ? .green : .blue)
            }
            .tint(.blue)
        }
    }

    // MARK: - Bindings

    private func trendBinding(_ lv: LabValue) -> Binding<Bool> {
        Binding(
            get: { TrackedMarkers.isTracked(lv.canonicalName) },
            set: { on in
                if on { TrackedMarkers.add(lv.canonicalName) }
                else { TrackedMarkers.remove(lv.canonicalName) }
                version += 1
            }
        )
    }

    private func isMedAdded(_ med: DetectedMedication) -> Bool {
        Medication.loadAll().contains {
            $0.name.caseInsensitiveCompare(med.name) == .orderedSame
        }
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
