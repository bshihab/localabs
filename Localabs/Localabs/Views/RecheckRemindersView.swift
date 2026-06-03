import SwiftUI

/// Manage the "recheck this marker" reminders (#31): the default
/// interval used when the user flips a reminder on from a flagged value,
/// plus the list of upcoming rechecks with swipe-to-delete. Reached from
/// Profile.
struct RecheckRemindersView: View {
    @State private var reminders: [RecheckReminder] = []
    @State private var intervalMonths: Int = RecheckStore.defaultIntervalMonths

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
                Text("When you turn on \u{201C}Remind me to recheck\u{201D} from a flagged value on a scan, the reminder is set this far out. Doctors often say \u{201C}recheck in 3 months.\u{201D}")
            }

            Section {
                if reminders.isEmpty {
                    Text("No recheck reminders yet. Tap a flagged value on a scan and turn on \u{201C}Remind me to recheck.\u{201D}")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(reminders) { reminder in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(reminder.marker)
                                .font(.body.weight(.medium))
                            Text("Recheck by \(reminder.dueDate, format: .dateTime.month().day().year())")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { reminders[$0].id }
                        reminders.remove(atOffsets: offsets)
                        for id in ids {
                            Task { await RecheckService.cancel(id: id) }
                        }
                    }
                }
            } header: {
                Text("Upcoming rechecks")
            } footer: {
                Text("Reminders fire as a notification on the recheck date and bring you to the Home tab to scan a fresh result. Informational — not a substitute for your doctor's guidance.")
            }
        }
        .navigationTitle("Recheck Reminders")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reminders = RecheckStore.all() }
    }
}
