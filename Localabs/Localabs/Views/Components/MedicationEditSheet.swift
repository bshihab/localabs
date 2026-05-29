import SwiftUI

/// Add or edit a medication. Reachable from the Meds tab "+" (new)
/// or a Dashboard report's "Add to Meds" button (new, linked to the
/// report), and from a Meds card's Edit action (existing).
///
/// The schedule uses a frequency preset (Once/Twice/Three times/
/// Custom) that seeds sensible default times, which the user can
/// then adjust individually. Saving re-syncs the medication's
/// notification reminders.
struct MedicationEditSheet: View {
    /// Existing med when editing; nil when adding.
    let editing: Medication?
    /// Set when launched from a report's "Add to Meds" button so the
    /// new med links back to its source.
    let sourceReportID: UUID?
    /// Prefill for the name field (e.g. a drug name the user tapped
    /// in a report). Empty otherwise.
    let prefilledName: String

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var dose: String = ""
    @State private var frequency: Frequency = .onceDaily
    @State private var times: [Medication.TimeOfDay] = Frequency.onceDaily.defaultTimes
    /// Day cadence (every day / weekly / every 2 weeks) — separate
    /// from `frequency`, which is times-per-day.
    @State private var cadence: Medication.RepeatRule.Cadence = .daily
    /// Selected Calendar weekdays (1 = Sun … 7 = Sat) for weekly /
    /// biweekly cadences.
    @State private var selectedWeekdays: Set<Int> = []
    @State private var hasEndDate: Bool = false
    @State private var endDate: Date = Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date()
    @State private var notes: String = ""
    @State private var showSavedConfirmation = false

    init(editing: Medication? = nil, sourceReportID: UUID? = nil, prefilledName: String = "") {
        self.editing = editing
        self.sourceReportID = sourceReportID
        self.prefilledName = prefilledName
    }

    /// Frequency presets. "Custom" lets the user add/remove arbitrary
    /// times; the others seed common defaults the user can still nudge.
    enum Frequency: String, CaseIterable, Identifiable {
        case onceDaily, twiceDaily, threeTimes, asNeeded, custom
        var id: String { rawValue }
        var label: String {
            switch self {
            case .onceDaily:  return "Once daily"
            case .twiceDaily: return "Twice daily"
            case .threeTimes: return "3× daily"
            case .asNeeded:   return "As needed"
            case .custom:     return "Custom"
            }
        }
        var defaultTimes: [Medication.TimeOfDay] {
            switch self {
            case .onceDaily:  return [.init(hour: 8, minute: 0)]
            case .twiceDaily: return [.init(hour: 8, minute: 0), .init(hour: 20, minute: 0)]
            case .threeTimes: return [.init(hour: 8, minute: 0), .init(hour: 13, minute: 0), .init(hour: 20, minute: 0)]
            case .asNeeded:   return []
            case .custom:     return [.init(hour: 8, minute: 0)]
            }
        }
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
            Picker("Frequency", selection: $frequency) {
                ForEach(Frequency.allCases) { f in
                    Text(f.label).tag(f)
                }
            }
            .onChange(of: frequency) { _, newValue in
                // Reseed times from the preset, unless Custom
                // (which keeps whatever the user has built).
                if newValue != .custom {
                    times = newValue.defaultTimes
                } else if times.isEmpty {
                    times = [.init(hour: 8, minute: 0)]
                }
            }

            if frequency != .asNeeded {
                ForEach(times.indices, id: \.self) { idx in
                    DatePicker(
                        "Reminder \(times.count > 1 ? "\(idx + 1)" : "")",
                        selection: timeBinding(idx),
                        displayedComponents: .hourAndMinute
                    )
                }
                .onDelete(perform: timeDeleteAction)

                if frequency == .custom {
                    Button {
                        times.append(.init(hour: 12, minute: 0))
                    } label: {
                        Label("Add another time", systemImage: "plus.circle")
                    }
                }
            }
        } header: {
            Text("Schedule")
        } footer: {
            Text(frequency == .asNeeded
                 ? "Tracked without reminders. You can still log doses on the Meds tab."
                 : "A reminder notification fires daily at each time.")
        }
    }

    @ViewBuilder
    private var daysSection: some View {
        // Only meaningful when there are reminder times. An "as
        // needed" med (no times) is tracked but never scheduled, so
        // the day cadence is moot.
        if frequency != .asNeeded {
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

    /// The swipe-to-delete handler for reminder times — only enabled
    /// in Custom mode (the presets manage their own time count).
    /// Returned as an explicit, fully-typed optional closure rather
    /// than a `cond ? method : nil` ternary inline in `.onDelete`,
    /// which tripped a Swift type-checker crash ("Failed to produce
    /// diagnostic for expression") when inferred from a bare method
    /// reference.
    private var timeDeleteAction: ((IndexSet) -> Void)? {
        guard frequency == .custom else { return nil }
        return { offsets in
            times.remove(atOffsets: offsets)
            if times.isEmpty { times.append(Medication.TimeOfDay(hour: 8, minute: 0)) }
        }
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
            // Infer the frequency preset from the saved time count.
            switch med.times.count {
            case 0:  frequency = .asNeeded
            case 1:  frequency = .onceDaily
            case 2:  frequency = .twiceDaily
            case 3:  frequency = .threeTimes
            default: frequency = .custom
            }
            cadence = med.repeatRule.cadence
            selectedWeekdays = Set(med.repeatRule.weekdays)
        } else if !prefilledName.isEmpty {
            name = prefilledName
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        // "As needed" (no times) is always daily-cadence — the day
        // rule is moot without reminders. Otherwise build the rule
        // from the cadence + selected weekdays, defaulting an empty
        // weekly/biweekly selection to today's weekday as a backstop.
        let repeatRule: Medication.RepeatRule
        if frequency == .asNeeded || cadence == .daily {
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
            times: frequency == .asNeeded ? [] : times.sorted(),
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
