import SwiftUI

/// Add or edit a medication. Reachable from the Meds tab "+" (new)
/// or a Dashboard report's "Add to Meds" button (new, linked to the
/// report), and from a Meds card's Edit action (existing).
///
/// The schedule is just a list of reminder times the user adds and
/// removes directly — no frequency preset. Zero times = "as needed"
/// (tracked, no reminders). Day cadence (daily/weekly/biweekly) is a
/// separate control. Saving re-syncs the medication's reminders.
struct MedicationEditSheet: View {
    /// Existing med when editing; nil when adding.
    let editing: Medication?
    /// Set when launched from a report's "Add to Meds" button so the
    /// new med links back to its source.
    let sourceReportID: UUID?
    /// Prefill for the name field (e.g. a drug name the user tapped
    /// in a report). Empty otherwise.
    let prefilledName: String
    /// Prefill for the dose field (e.g. "500 mg" detected alongside the
    /// name in a report). Empty otherwise.
    let prefilledDose: String

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var dose: String = ""
    /// Reminder times. A new med starts with one 8:00 AM time; the
    /// user adds more or deletes them all (→ "as needed").
    @State private var times: [Medication.TimeOfDay] = [.init(hour: 8, minute: 0)]
    /// Day cadence (every day / weekly / every 2 weeks).
    @State private var cadence: Medication.RepeatRule.Cadence = .daily
    /// Selected Calendar weekdays (1 = Sun … 7 = Sat) for weekly /
    /// biweekly cadences.
    @State private var selectedWeekdays: Set<Int> = []
    @State private var hasEndDate: Bool = false
    @State private var endDate: Date = Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date()
    @State private var notes: String = ""
    @State private var showSavedConfirmation = false

    init(editing: Medication? = nil, sourceReportID: UUID? = nil, prefilledName: String = "", prefilledDose: String = "") {
        self.editing = editing
        self.sourceReportID = sourceReportID
        self.prefilledName = prefilledName
        self.prefilledDose = prefilledDose
    }

    var body: some View {
        NavigationStack {
            Form {
                medicationSection
                scheduleSection
                daysSection
                durationSection
                notesSection
                if showSavedConfirmation { savedConfirmationSection }
            }
            .navigationTitle(editing == nil ? "Add Medication" : "Edit Medication")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .onAppear(perform: seed)
        }
        .presentationDetents([.large])
    }

    // The Form is split into computed sub-views. A single Form
    // literal with this many conditionals + bindings overwhelms the
    // SwiftUI type-checker (it surfaces as a misleading "ambiguous
    // toolbar" error); breaking it up keeps each expression small
    // enough to infer.

    private var medicationSection: some View {
        Section("Medication") {
            TextField("Name (e.g. Metformin)", text: $name)
            TextField("Dose (e.g. 500 mg, 1 tablet)", text: $dose)
        }
    }

    @ViewBuilder
    private var scheduleSection: some View {
        Section {
            // A plain editable list of reminder times. Add as many as
            // needed; delete them all to make the med "as needed"
            // (tracked, no reminders). No frequency preset.
            ForEach(times.indices, id: \.self) { idx in
                DatePicker(
                    "Reminder \(times.count > 1 ? "\(idx + 1)" : "")",
                    selection: timeBinding(idx),
                    displayedComponents: .hourAndMinute
                )
            }
            .onDelete { offsets in
                times.remove(atOffsets: offsets)
            }

            Button {
                times.append(Medication.TimeOfDay(hour: 12, minute: 0))
            } label: {
                Label("Add a time", systemImage: "plus.circle")
            }
        } header: {
            Text("Times")
        } footer: {
            Text(times.isEmpty
                 ? "No reminder times — this medication is tracked as needed. You can still check off doses on the Meds tab."
                 : "A reminder notification fires at each time, on the days set below.")
        }
    }

    @ViewBuilder
    private var daysSection: some View {
        // Only meaningful when there are reminder times. An "as
        // needed" med (no times) is tracked but never scheduled, so
        // the day cadence is moot.
        if !times.isEmpty {
            Section {
                Picker("Repeats", selection: $cadence) {
                    Text("Every day").tag(Medication.RepeatRule.Cadence.daily)
                    Text("Weekly").tag(Medication.RepeatRule.Cadence.weekly)
                    Text("Every 2 weeks").tag(Medication.RepeatRule.Cadence.biweekly)
                }
                .onChange(of: cadence) { _, newValue in
                    // Never leave a weekly/biweekly med with no days —
                    // default to today's weekday so it's always valid.
                    if newValue != .daily && selectedWeekdays.isEmpty {
                        selectedWeekdays = [Calendar.current.component(.weekday, from: Date())]
                    }
                }

                if cadence != .daily {
                    WeekdayCirclePicker(selected: $selectedWeekdays)
                        .padding(.vertical, 6)
                }
            } header: {
                Text("Days")
            } footer: {
                Text(cadence == .biweekly
                     ? "Pick the weekdays. Biweekly reminders are scheduled a few cycles ahead and top up each time you open the app."
                     : cadence == .weekly
                       ? "Pick the days of the week this medication is taken. The times above apply to each selected day."
                       : "Reminders fire every day at the times above.")
            }
        }
    }

    @ViewBuilder
    private var durationSection: some View {
        Section {
            Toggle("Set an end date", isOn: $hasEndDate.animation())
            if hasEndDate {
                DatePicker(
                    "Ends",
                    selection: $endDate,
                    in: Date()...,
                    displayedComponents: .date
                )
            }
        } header: {
            Text("Duration")
        } footer: {
            Text(hasEndDate
                 ? "After this date the medication moves to your Past list and reminders stop."
                 : "Ongoing — reminders continue until you remove or end the medication.")
        }
    }

    private var notesSection: some View {
        Section("Notes (optional)") {
            TextField("e.g. Take with food", text: $notes, axis: .vertical)
                .lineLimit(1...4)
        }
    }

    private var savedConfirmationSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Saved")
                Spacer()
            }
        }
        .transition(.opacity)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Save") { save() }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                .fontWeight(.semibold)
        }
    }

    // MARK: - Time editing

    private func timeBinding(_ idx: Int) -> Binding<Date> {
        Binding(
            get: {
                var comps = DateComponents()
                comps.hour = times[idx].hour
                comps.minute = times[idx].minute
                return Calendar.current.date(from: comps) ?? Date()
            },
            set: { newDate in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                times[idx] = .init(hour: comps.hour ?? 8, minute: comps.minute ?? 0)
            }
        )
    }

    // MARK: - Seed / save

    private func seed() {
        if let med = editing {
            name = med.name
            dose = med.dose
            times = med.times
            notes = med.notes
            if let end = med.endDate {
                hasEndDate = true
                endDate = end
            }
            cadence = med.repeatRule.cadence
            selectedWeekdays = Set(med.repeatRule.weekdays)
        } else {
            if !prefilledName.isEmpty { name = prefilledName }
            if !prefilledDose.isEmpty { dose = prefilledDose }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        // No times = "as needed", which is always daily-cadence (the
        // day rule is moot without reminders). Otherwise build the
        // rule from the cadence + selected weekdays, defaulting an
        // empty weekly/biweekly selection to today's weekday.
        let repeatRule: Medication.RepeatRule
        if times.isEmpty || cadence == .daily {
            repeatRule = .daily
        } else {
            let days = selectedWeekdays.isEmpty
                ? [Calendar.current.component(.weekday, from: Date())]
                : Array(selectedWeekdays).sorted()
            repeatRule = Medication.RepeatRule(cadence: cadence, weekdays: days)
        }

        let med = Medication(
            id: editing?.id ?? UUID(),
            name: trimmedName,
            dose: dose.trimmingCharacters(in: .whitespacesAndNewlines),
            times: times.sorted(),
            repeatRule: repeatRule,
            startDate: editing?.startDate ?? Date(),
            endDate: hasEndDate ? endDate : nil,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            sourceReportID: editing?.sourceReportID ?? sourceReportID,
            createdAt: editing?.createdAt ?? Date()
        )
        Medication.save(med)

        Task { @MainActor in
            await MedicationService.requestAuthorizationIfNeeded()
            await MedicationService.sync(med)
        }

        withAnimation(.easeInOut(duration: 0.15)) { showSavedConfirmation = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { dismiss() }
    }
}

/// A row of seven tappable day circles (S M T W T F S) that fill in
/// when selected. Binds to a set of Calendar weekdays (1 = Sunday …
/// 7 = Saturday), so the order matches Calendar's convention.
private struct WeekdayCirclePicker: View {
    @Binding var selected: Set<Int>

    // Index 0–6 maps to Calendar weekday 1–7 (Sun–Sat). The repeated
    // S/T letters (Sun/Sat, Tue/Thu) match Apple's own day pickers.
    private let symbols = ["S", "M", "T", "W", "T", "F", "S"]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<7, id: \.self) { idx in
                let weekday = idx + 1
                let isOn = selected.contains(weekday)
                Button {
                    if isOn { selected.remove(weekday) } else { selected.insert(weekday) }
                } label: {
                    Text(symbols[idx])
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(
                            Circle()
                                .fill(isOn ? Color.accentColor : Color(.tertiarySystemFill))
                        )
                        .foregroundStyle(isOn ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
                .sensoryFeedback(.selection, trigger: isOn)
            }
        }
    }
}
