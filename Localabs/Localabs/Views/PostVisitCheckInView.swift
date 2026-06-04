import SwiftUI

/// Post-visit check-in (#34). Surfaced the evening of an appointment
/// (via VisitService's notification) and from the Home visit card once
/// the visit time has passed. A short, guided flow to capture what
/// changed at the visit — new/changed medications, new instructions or
/// diagnoses, and the next appointment — so the app's context stays
/// current without the user having to remember to update it later.
///
/// The USER is the source of truth here: they type what the doctor
/// said. Nothing is AI-inferred and nothing is added silently — every
/// medication still goes through the editor, every note is confirmed on
/// Done. Informational, never a diagnosis or a prescription.
struct PostVisitCheckInView: View {
    @Environment(\.dismiss) private var dismiss

    /// The visit being logged (the upcoming appointment whose time has
    /// passed). Optional — the flow still works for an ad-hoc check-in.
    let visit: Appointment?

    @State private var showMedSheet = false
    @State private var newInstructions = ""
    @State private var medsAddedThisSession = 0

    // Next appointment
    @State private var scheduleNext = false
    @State private var nextDate = Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date()
    @State private var nextNote = ""

    var body: some View {
        NavigationStack {
            Form {
                introSection
                medicationsSection
                instructionsSection
                summaryScanSection
                nextVisitSection
                disclaimerSection
            }
            .navigationTitle("After Your Visit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { finish() }
                        .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showMedSheet) {
                MedicationEditSheet(sourceReportID: nil)
                    .onDisappear { medsAddedThisSession = Medication.active.count }
            }
        }
    }

    // MARK: - Sections

    private var introSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("How did your visit go?")
                    .font(.headline)
                Text(visitSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }

    private var medicationsSection: some View {
        Section {
            Button {
                showMedSheet = true
            } label: {
                Label("Add a medication from this visit", systemImage: "pills.fill")
            }
        } header: {
            Text("New or changed medications")
        } footer: {
            Text(medsAddedThisSession > 0
                 ? "Added to your Meds tab — reminders and dates are set there, and Localabs factors it into future analyses."
                 : "Prescribed or changed something today? Add it so you get reminders and Localabs knows what you're taking.")
        }
    }

    private var instructionsSection: some View {
        Section {
            TextField(
                "e.g. Recheck A1C in 3 months; start low-sodium diet",
                text: $newInstructions,
                axis: .vertical
            )
            .lineLimit(2...5)
        } header: {
            Text("New instructions or diagnoses")
        } footer: {
            Text("Saved to your health profile so Localabs factors it into how it reads your results.")
        }
    }

    private var summaryScanSection: some View {
        Section {
            Button {
                // Return to the Home screen, where the document scanner
                // lives. Detected medications in the summary then surface
                // as one-tap adds (#33).
                dismiss()
            } label: {
                Label("Scan your after-visit summary", systemImage: "doc.viewfinder")
            }
        } footer: {
            Text("Got a printout? Scan it from the Home tab — Localabs will pull out any medications it lists.")
        }
    }

    private var nextVisitSection: some View {
        Section {
            Toggle("Schedule my next visit", isOn: $scheduleNext.animation())
            if scheduleNext {
                DatePicker(
                    "Date",
                    selection: $nextDate,
                    in: Date()...,
                    displayedComponents: [.date, .hourAndMinute]
                )
                TextField("What it's for (optional)", text: $nextNote)
            }
        } header: {
            Text("Next appointment")
        } footer: {
            Text(scheduleNext
                 ? "Localabs will check in with you again the evening after this one."
                 : "Set your next visit and the prep + check-in loop starts over.")
        }
    }

    private var disclaimerSection: some View {
        Section {
            Label {
                Text("This keeps your records current for you — it isn't medical advice or a diagnosis.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private var visitSubtitle: String {
        guard let visit else {
            return "Log anything that changed so your records stay up to date."
        }
        let f = DateFormatter()
        f.dateStyle = .medium
        let base = "Your visit on \(f.string(from: visit.date))"
        return visit.note.isEmpty ? "\(base) — log anything that changed." : "\(base) (\(visit.note))."
    }

    /// Commit the check-in: save typed instructions to the profile, then
    /// either schedule the next visit or clear the completed one (and its
    /// notification). The medications were already saved by the editor.
    private func finish() {
        let instructions = newInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instructions.isEmpty {
            var profile = UserProfile.load()
            _ = profile.add(instructions, to: .medicalConditions)
            profile.save()
        }

        // Archive this visit into the Past visits history (#4) so the hub
        // can show what's already been handled. Only record a meaningful
        // check-in — a known appointment, or something the user logged.
        if visit != nil || !instructions.isEmpty || medsAddedThisSession > 0 {
            VisitHistory.add(
                PastVisit(
                    date: visit?.date ?? Date(),
                    note: visit?.note ?? "",
                    preVisitQuestions: VisitPrepQuestions.load(),
                    instructions: instructions
                )
            )
        }

        Task { @MainActor in
            if scheduleNext {
                let appt = Appointment(date: nextDate, note: nextNote.trimmingCharacters(in: .whitespacesAndNewlines))
                appt.save()
                await VisitService.schedule(for: appt)
            } else {
                // The logged visit is done — clear it so the Home card
                // and notification stop pointing at a past appointment.
                Appointment.clear()
                VisitService.cancel()
            }
            dismiss()
        }
    }
}
