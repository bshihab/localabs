import SwiftUI

/// The liquid-glass action menu that pops up from a tapped scan
/// highlight (#31). Shared by the document viewer and the dashboard
/// scan preview.
///
/// - "Ask Localabs about this" is always available (host-presented chat).
/// - The personal actions — Add to Meds, the "in your trends" status,
///   and the recheck-reminder toggle — only show for the user's OWN
///   reports. On a report tagged as someone else's, the menu is just
///   "Ask Localabs" so a relative's meds/markers never land in the
///   user's own data.
struct EntityActionMenu: View {
    let entity: HighlightEntity
    /// False when the report is tagged as someone else's — hides the
    /// personal "add to my data" actions.
    let isOwnReport: Bool
    let onAsk: () -> Void
    /// Opens the Meds editor (host-presented) so the user can set the
    /// dose/schedule when adding a medication.
    let onAddMedication: (DetectedMedication) -> Void
    /// Bumped when the recheck toggle changes so the label/switch updates.
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

            if isOwnReport {
                personalActions
            }
        }
        .padding(14)
        .frame(width: 252)
        .glassEffect(
            .regular.tint(.blue.opacity(0.12)),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }

    @ViewBuilder
    private var personalActions: some View {
        let _ = version
        switch entity {
        case .medication(let med):
            if isMedAdded(med) {
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
            // Lab values are already tracked in cross-report trends
            // automatically — this is just status, no toggle.
            Label("In your Health Trends", systemImage: "chart.line.uptrend.xyaxis")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            // The actionable control: a reminder to re-scan this marker.
            Toggle(isOn: recheckBinding(lv)) {
                Label(
                    RecheckStore.isSet(forMarker: lv.canonicalName)
                        ? "Recheck reminder set"
                        : "Remind me to recheck",
                    systemImage: "bell.badge"
                )
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(RecheckStore.isSet(forMarker: lv.canonicalName) ? .green : .blue)
            }
            .tint(.blue)
        }
    }

    // MARK: - Bindings / helpers

    private func recheckBinding(_ lv: LabValue) -> Binding<Bool> {
        Binding(
            get: { RecheckStore.isSet(forMarker: lv.canonicalName) },
            set: { on in
                let marker = lv.canonicalName
                if on {
                    // Re-enabling clears any prior opt-out.
                    RecheckStore.setOptedOut(marker, false)
                    let reminder = RecheckReminder(
                        marker: marker,
                        dueDate: Calendar.current.date(
                            byAdding: .day,
                            value: RecheckStore.defaultIntervalDays,
                            to: Date()
                        ) ?? Date()
                    )
                    RecheckStore.save(reminder)
                    Task { await RecheckService.arm(reminder) }
                } else {
                    // Remember the opt-out so a re-scan won't re-add it.
                    RecheckStore.setOptedOut(marker, true)
                    if let existing = RecheckStore.reminder(forMarker: marker) {
                        RecheckStore.remove(id: existing.id)
                        RecheckService.removeNotification(id: existing.id)
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
