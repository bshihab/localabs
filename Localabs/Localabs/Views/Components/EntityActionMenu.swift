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
            let added = isMedAdded(med)
            Toggle(isOn: medBinding(med)) {
                Label(added ? "Added to Meds" : "Add to Meds", systemImage: "pills.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(added ? .green : .orange)
            }
            .tint(.orange)

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

    private func medBinding(_ med: DetectedMedication) -> Binding<Bool> {
        Binding(
            get: { isMedAdded(med) },
            set: { on in
                if on {
                    // Quick-add as "as needed" (no reminder times) with the
                    // dose we detected — the user can set a schedule later
                    // in the Meds tab.
                    Medication.save(Medication(name: med.name, dose: med.dose))
                } else {
                    for existing in Medication.loadAll()
                    where existing.name.caseInsensitiveCompare(med.name) == .orderedSame {
                        let id = existing.id
                        Medication.delete(id: id)
                        Task { @MainActor in await MedicationService.cancel(medID: id) }
                    }
                }
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
