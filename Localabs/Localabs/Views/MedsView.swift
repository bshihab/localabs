import SwiftUI

/// The Meds tab — today's dose schedule, active medications, and a
/// collapsed Past list. Reminders are driven by MedicationService;
/// this view is the management + daily check-off surface.
struct MedsView: View {
    @State private var meds: [Medication] = []
    @State private var showAddSheet = false
    @State private var editingMed: Medication?
    @State private var pendingDeleteID: UUID?
    /// Bumped on each adherence toggle to force the Today rows +
    /// streak labels to recompute (adherence lives outside `meds`).
    @State private var adherenceVersion = 0

    var body: some View {
        NavigationStack {
            Group {
                if meds.isEmpty {
                    emptyState
                } else {
                    content
                }
            }
            .navigationTitle("Meds")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editingMed = nil
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                    }
                    .accessibilityLabel("Add medication")
                }
            }
            .sheet(isPresented: $showAddSheet) {
                MedicationEditSheet(editing: editingMed)
                    .onDisappear { reload() }
            }
            .sheet(item: $editingMed) { med in
                MedicationEditSheet(editing: med)
                    .onDisappear { reload() }
            }
            .confirmationDialog(
                "Remove this medication?",
                isPresented: Binding(
                    get: { pendingDeleteID != nil },
                    set: { if !$0 { pendingDeleteID = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let id = pendingDeleteID {
                    Button("Remove", role: .destructive) {
                        Task { await MedicationService.cancel(medID: id) }
                        Medication.delete(id: id)
                        pendingDeleteID = nil
                        reload()
                    }
                }
                Button("Cancel", role: .cancel) { pendingDeleteID = nil }
            } message: {
                Text("This stops its reminders and clears its history. It won't affect any linked report.")
            }
            .onAppear { reload() }
        }
    }

    private func reload() {
        meds = Medication.loadAll()
    }

    private var activeMeds: [Medication] { meds.filter(\.isActive) }
    private var pastMeds: [Medication] { meds.filter { !$0.isActive } }

    // MARK: - Content

    private var content: some View {
        // NOTE: deliberately NOT `.id(adherenceVersion)`. Re-keying the
        // whole List on every check-off threw away each DoseRow's local
        // @State, which is what drives the 2-second "just taken → settles
        // to next dose" animation. A plain @State bump still re-evaluates
        // this body (so taken-state + streaks recompute), but keeps the
        // rows' identities — and their animation state — intact.
        let _ = adherenceVersion
        return List {
            todaySection
            activeSection
            if !pastMeds.isEmpty { pastSection }
        }
    }

    // MARK: - Today

    /// Every dose occurrence scheduled for today, grouped by part of
    /// day, each with a check-off button.
    private var todaySection: some View {
        ForEach(Medication.DayPart.allCases, id: \.rawValue) { part in
            let doses = todayDoses(in: part)
            if !doses.isEmpty {
                Section(part.label) {
                    ForEach(doses) { dose in
                        DoseRow(dose: dose) {
                            toggleDose(dose)
                        }
                    }
                }
            }
        }
    }

    /// Builds the dose occurrences for today in a given day-part,
    /// sorted by time. Only active meds that are actually due today
    /// (per their repeat rule) and have scheduled times appear.
    private func todayDoses(in part: Medication.DayPart) -> [TodayDose] {
        let today = Date()
        let cal = Calendar.current
        let now = Date()
        var result: [TodayDose] = []
        for med in activeMeds where med.isScheduled(on: today) {
            for (idx, time) in med.times.enumerated() where time.dayPart == part {
                // "Due" = the dose's scheduled time today has arrived (or
                // passed) — drives the gentle glow on the unchecked circle.
                var comps = cal.dateComponents([.year, .month, .day], from: now)
                comps.hour = time.hour
                comps.minute = time.minute
                let doseTime = cal.date(from: comps) ?? now
                result.append(TodayDose(
                    medID: med.id,
                    medName: med.name,
                    dose: med.dose,
                    time: time,
                    timeIndex: idx,
                    taken: MedicationAdherence.isTaken(medID: med.id, date: Date(), timeIndex: idx),
                    isDue: doseTime <= now,
                    nextLabel: Self.nextOccurrenceLabel(med: med, time: time)
                ))
            }
        }
        return result.sorted { $0.time < $1.time }
    }

    /// Human label for the *next* time this dose comes due after today —
    /// e.g. "Tomorrow, 12:00 PM" or "Mon, 8:00 AM". Shown once a dose has
    /// been checked off and settled, so the row reads as "done, next at…".
    /// Walks forward up to two weeks to cover weekly / biweekly schedules.
    private static func nextOccurrenceLabel(med: Medication, time: Medication.TimeOfDay) -> String {
        let cal = Calendar.current
        for offset in 1...14 {
            guard let day = cal.date(byAdding: .day, value: offset, to: Date()),
                  med.isScheduled(on: day) else { continue }
            if cal.isDateInTomorrow(day) {
                return "Tomorrow, \(time.displayString)"
            }
            let wd = DateFormatter()
            wd.dateFormat = "EEE"
            return "\(wd.string(from: day)), \(time.displayString)"
        }
        return "Next dose, \(time.displayString)"
    }

    private func toggleDose(_ dose: TodayDose) {
        let now = MedicationAdherence.isTaken(medID: dose.medID, date: Date(), timeIndex: dose.timeIndex)
        MedicationAdherence.setTaken(!now, medID: dose.medID, date: Date(), timeIndex: dose.timeIndex)
        adherenceVersion += 1
    }

    // MARK: - Active

    private var activeSection: some View {
        Section("Active medications") {
            ForEach(activeMeds) { med in
                MedCard(med: med, streak: MedicationAdherence.streak(for: med))
                    .contentShape(Rectangle())
                    .onTapGesture { editingMed = med }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDeleteID = med.id
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                        Button {
                            editingMed = med
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
            }
        }
    }

    // MARK: - Past

    private var pastSection: some View {
        Section("Past medications") {
            ForEach(pastMeds) { med in
                MedCard(med: med, streak: 0)
                    .opacity(0.6)
                    .contentShape(Rectangle())
                    .onTapGesture { editingMed = med }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDeleteID = med.id
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 18) {
            // Static soft glow — inviting on an idle empty screen without
            // any motion.
            GlowingPulseIcon(systemName: "pills.fill", tint: .orange, size: 60, animated: false)
                .opacity(0.85)
            Text("No medications yet")
                .font(.title3.weight(.semibold))
            Text("When your scans include medications, add them here for reminders — or tap + to add one yourself.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                editingMed = nil
                showAddSheet = true
            } label: {
                Label("Add a medication", systemImage: "plus")
                    .fontWeight(.semibold)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
            Spacer()
        }
        .padding(.top, 60)
        .frame(maxWidth: .infinity)
    }
}

/// One dose occurrence shown in the Today schedule.
private struct TodayDose: Identifiable {
    let medID: UUID
    let medName: String
    let dose: String
    let time: Medication.TimeOfDay
    let timeIndex: Int
    let taken: Bool
    /// Scheduled time today has arrived/passed — drives the "take me" glow.
    let isDue: Bool
    /// When this dose next comes due after today ("Tomorrow, 12:00 PM").
    let nextLabel: String
    var id: String { "\(medID.uuidString)-\(timeIndex)" }
}

private struct DoseRow: View {
    let dose: TodayDose
    let onToggle: () -> Void

    /// True for ~2 seconds right after the user checks a dose. During
    /// this window the checkmark stays a bright, slightly-enlarged green
    /// "just done" tick; once it elapses the row settles into the muted
    /// state that shows the next dose time with a grayed-out check.
    @State private var celebrating = false

    /// The dose is checked AND the celebration window has elapsed — show
    /// the "next dose" treatment.
    private var settled: Bool { dose.taken && !celebrating }

    var body: some View {
        HStack(spacing: 14) {
            Text(dose.time.displayString)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
                .opacity(settled ? 0.4 : 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(dose.medName)
                    .font(.body.weight(.medium))
                    .strikethrough(dose.taken, color: .secondary)
                    .foregroundStyle(dose.taken ? .secondary : .primary)
                if settled {
                    // Once settled, the dose is done for today — point the
                    // user at when it's next due.
                    Label(dose.nextLabel, systemImage: "clock.arrow.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !dose.dose.isEmpty {
                    Text(dose.dose)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button(action: toggle) {
                Image(systemName: dose.taken ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(dose.isDue && !dose.taken ? Color.orange : checkColor)
                    .scaleEffect(celebrating ? 1.14 : 1)
                    // Gentle glow when the dose is due and not yet taken —
                    // a quiet "take me," not an alarm.
                    .glowPulse(active: dose.isDue && !dose.taken && !celebrating, tint: .orange)
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.success, trigger: dose.taken)
        }
        .padding(.vertical, 2)
        // A dose that's already taken when the view first appears shows
        // its settled state immediately — `celebrating` starts false, so
        // there's no celebration replay on load.
        .animation(.spring(response: 0.32, dampingFraction: 0.7), value: celebrating)
        .animation(.easeInOut(duration: 0.25), value: dose.taken)
    }

    /// Green while freshly checked, gray once settled, secondary when not
    /// taken.
    private var checkColor: Color {
        if settled { return .secondary }
        return dose.taken ? .green : .secondary
    }

    private func toggle() {
        let willBeTaken = !dose.taken
        onToggle()
        if willBeTaken {
            celebrating = true
            // Hold the celebratory green tick for ~2s, then let the row
            // settle into "done — next at …".
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                withAnimation { celebrating = false }
            }
        } else {
            // Un-checking returns to the normal pending state at once.
            celebrating = false
        }
    }
}

private struct MedCard: View {
    let med: Medication
    let streak: Int

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "pill.fill")
                .font(.title3)
                .foregroundStyle(.orange)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(med.name)
                        .font(.body.weight(.semibold))
                    if !med.dose.isEmpty {
                        Text(med.dose)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(med.scheduleSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if streak > 0 {
                    Label("\(streak)-day streak", systemImage: "flame.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}
