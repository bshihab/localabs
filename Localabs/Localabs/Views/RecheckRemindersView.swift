import SwiftUI

/// Manage recheck reminders (#31). The default interval, plus a toggle
/// for every lab marker Localabs has detected across the user's own
/// reports — flip one on to be reminded to re-scan it. Markers whose
/// reports were all deleted disappear (their reminders are cleared on
/// appear), so this list always reflects the data the user actually has.
struct RecheckRemindersView: View {
    /// Unique detected markers from the user's own reports, out-of-range
    /// ones first. Loaded on appear.
    @State private var markers: [String] = []
    @State private var intervalMonths: Int = RecheckStore.defaultIntervalMonths
    /// Bumped on each toggle so the rows re-read their reminder state.
    @State private var version = 0

    var body: some View {
        Form {
            Section {
                Picker("Default interval", selection: $intervalMonths) {
                    Text("1 month").tag(1)
                    Text("3 months").tag(3)
                    Text("6 months").tag(6)
                    Text("12 months").tag(12)
                }
                .onChange(of: intervalMonths) { _, v in
                    RecheckStore.defaultIntervalMonths = v
                }
            } header: {
                Text("Default")
            } footer: {
                Text("New recheck reminders are set this far out — the doctor's usual \u{201C}recheck in 3 months.\u{201D} Out-of-range values are reminded on by default; switch any off below.")
            }

            Section {
                if markers.isEmpty {
                    Text("No lab markers yet. Scan a report and any out-of-range values will appear here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(markers, id: \.self) { marker in
                        let _ = version
                        Toggle(isOn: binding(for: marker)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(marker)
                                    .font(.body)
                                if let r = RecheckStore.reminder(forMarker: marker) {
                                    Text("Recheck by \(r.dueDate, format: .dateTime.month().day().year())")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("Detected markers")
            } footer: {
                Text("Reminders fire as a notification on the recheck date and bring you to the Home tab to scan a fresh result. Informational \u{2014} not a substitute for your doctor's guidance.")
            }
        }
        .navigationTitle("Recheck Reminders")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
    }

    private func load() {
        let reports = LocalStorageService.shared.getHistory().filter(\.isOwnReport)
        // Drop reminders for markers no longer in any report.
        let valid = Set(reports.flatMap { $0.labValues ?? [] }.map { LabValue.normalizeKey($0.canonicalName) })
        Task { @MainActor in
            for r in RecheckStore.all() where !valid.contains(r.key) {
                await RecheckService.cancel(id: r.id)
            }
            version += 1
        }

        // Unique marker display names, out-of-range first then alpha.
        var seen = Set<String>()
        var outOfRange: [String] = []
        var normal: [String] = []
        for value in reports.flatMap({ $0.labValues ?? [] }) {
            let key = LabValue.normalizeKey(value.canonicalName)
            guard seen.insert(key).inserted else { continue }
            if value.isOutOfRange { outOfRange.append(value.canonicalName) }
            else { normal.append(value.canonicalName) }
        }
        markers = outOfRange.sorted() + normal.sorted()
    }

    private func binding(for marker: String) -> Binding<Bool> {
        Binding(
            get: { RecheckStore.isSet(forMarker: marker) },
            set: { on in
                if on {
                    RecheckStore.setOptedOut(marker, false)
                    Task { await RecheckService.schedule(marker: marker, months: RecheckStore.defaultIntervalMonths) }
                } else {
                    RecheckStore.setOptedOut(marker, true)
                    Task { await RecheckService.cancel(marker: marker) }
                }
                version += 1
            }
        )
    }
}
