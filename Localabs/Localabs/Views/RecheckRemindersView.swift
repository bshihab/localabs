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
    @State private var intervalDays: Int = RecheckStore.defaultIntervalDays
    /// Bumped on each toggle so the rows re-read their reminder state.
    @State private var version = 0

    var body: some View {
        Form {
            Section {
                Picker("Default interval", selection: $intervalDays) {
                    Text("2 weeks").tag(14)
                    Text("1 month").tag(30)
                    Text("6 weeks").tag(45)
                    Text("2 months").tag(60)
                    Text("3 months").tag(90)
                    Text("6 months").tag(180)
                    Text("1 year").tag(365)
                }
                .onChange(of: intervalDays) { _, v in
                    RecheckStore.defaultIntervalDays = v
                }
            } header: {
                Text("Default")
            } footer: {
                Text("New recheck reminders are set this far out — the doctor's usual \u{201C}recheck in 3 months.\u{201D} Markers trending the wrong way are reminded on by default; switch any off below.")
            }

            Section {
                if markers.isEmpty {
                    Text("No tracked markers yet. Scan two or more reports that share a lab marker — the same ones on your Trends tab — and they'll appear here.")
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
        // Mirror the Trends tab EXACTLY: the recheck list is built from the
        // SAME cross-report trends (own reports, 2+ readings, joined by
        // normalized name, hidden excluded, worsening sorted first). This is
        // what keeps one-off extractions — a titer that appears once, a
        // duplicate name variant, a prose line from a clinical note that got
        // mis-read as a "marker" — out of here: if it isn't a real trend on
        // the Trends tab, it can't show up as a reminder.
        let history = LocalStorageService.shared.getHistory()
        let trends = LabTrendService.trends(from: history)
        let valid = Set(trends.map { LabValue.normalizeKey($0.canonicalName) })
        // Drop any reminder whose marker is no longer a tracked trend
        // (its reports were deleted, or it was junk that never trended).
        Task { @MainActor in
            for r in RecheckStore.all() where !valid.contains(r.key) {
                await RecheckService.cancel(id: r.id)
            }
            version += 1
        }
        // trends() already sorts worsening-first, which is the order we want.
        markers = trends.map(\.canonicalName)
    }

    private func binding(for marker: String) -> Binding<Bool> {
        Binding(
            get: { RecheckStore.isSet(forMarker: marker) },
            set: { on in
                if on {
                    RecheckStore.setOptedOut(marker, false)
                    // Save to the store SYNCHRONOUSLY (so the toggle reflects
                    // on the first tap), then arm the notification in the
                    // background. Using the async schedule() here meant the
                    // store wasn't updated yet when the row re-read its
                    // state — which is why it took two taps.
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
}
