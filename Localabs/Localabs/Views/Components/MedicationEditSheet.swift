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
                Section("Medication") {
                    TextField("Name (e.g. Metformin)", text: $name)
                    TextField("Dose (e.g. 500 mg, 1 tablet)", text: $dose)
                }

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
                        .onDelete(frequency == .custom ? deleteTime : nil)

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

                Section("Notes (optional)") {
                    TextField("e.g. Take with food", text: $notes, axis: .vertical)
                        .lineLimit(1...4)
                }

                if showSavedConfirmation {
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
            }
            .navigationTitle(editing == nil ? "Add Medication" : "Edit Medication")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .fontWeight(.semibold)
                }
            }
            .onAppear(perform: seed)
        }
        .presentationDetents([.large])
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

    private func deleteTime(at offsets: IndexSet) {
        times.remove(atOffsets: offsets)
        if times.isEmpty { times.append(.init(hour: 8, minute: 0)) }
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
        } else if !prefilledName.isEmpty {
            name = prefilledName
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        let med = Medication(
            id: editing?.id ?? UUID(),
            name: trimmedName,
            dose: dose.trimmingCharacters(in: .whitespacesAndNewlines),
            times: frequency == .asNeeded ? [] : times.sorted(),
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
