import SwiftUI

/// Pre-visit prep mode (#30). A one-screen summary the user reviews —
/// and can bring — to a doctor's appointment: what's changed in their
/// labs, how they've been feeling, what they're taking, and a list of
/// questions to ask. It pulls together the trend (#28), symptom (#29),
/// and medication (#26/#33) data the app already holds, so prepping is
/// a glance rather than a memory exercise.
///
/// Capturing the appointment date here also seeds the post-visit
/// check-in (#34): Localabs can follow up the evening of the visit.
///
/// Everything stays informational — the questions are prompts to ask a
/// professional, never diagnoses or treatment recommendations.
struct PreVisitPrepView: View {
    @EnvironmentObject var engine: InferenceEngine
    @Environment(\.dismiss) private var dismiss

    // Appointment
    @State private var hasAppointment = false
    @State private var appointmentDate = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    @State private var appointmentNote = ""

    // Questions
    @State private var myQuestions: [String] = []
    @State private var newQuestion = ""
    @State private var suggestions: [String] = []
    @State private var isGenerating = false

    // Aggregated data, loaded once on appear.
    @State private var worsening: [LabTrend] = []
    @State private var recentSymptoms: [SymptomEntry] = []
    @State private var activeMeds: [Medication] = []

    @State private var showShare = false

    var body: some View {
        NavigationStack {
            Form {
                appointmentSection
                if !worsening.isEmpty { changesSection }
                if !recentSymptoms.isEmpty { symptomsSection }
                if !activeMeds.isEmpty { medsSection }
                questionsSection
                suggestionsSection
                disclaimerSection
            }
            .navigationTitle("Visit Prep")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showShare = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share prep summary")
                }
            }
            .onAppear(perform: load)
            .sheet(isPresented: $showShare) {
                ShareSheet(items: [exportText])
            }
        }
    }

    // MARK: - Sections

    private var appointmentSection: some View {
        Section {
            Toggle("I have an appointment", isOn: $hasAppointment.animation())
            if hasAppointment {
                DatePicker(
                    "Date",
                    selection: $appointmentDate,
                    in: Date()...,
                    displayedComponents: [.date, .hourAndMinute]
                )
                TextField("What it's for (e.g. Annual physical)", text: $appointmentNote)
            }
        } header: {
            Text("Appointment")
        } footer: {
            Text(hasAppointment
                 ? "Localabs remembers this so it can check in with you the evening after your visit."
                 : "Optional — add your appointment so Localabs can follow up after the visit.")
        }
        .onChange(of: hasAppointment) { _, _ in persistAppointment() }
        .onChange(of: appointmentDate) { _, _ in persistAppointment() }
        .onChange(of: appointmentNote) { _, _ in persistAppointment() }
    }

    private var changesSection: some View {
        Section {
            ForEach(worsening) { trend in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(trend.canonicalName)
                            .font(.body.weight(.semibold))
                        Spacer()
                        if let latest = trend.latest, let first = trend.points.first {
                            Text("\(LabTrend.fmt(first.value)) → \(LabTrend.fmt(latest.value)) \(trend.unit)")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.orange)
                        }
                    }
                    if let range = trend.referenceRangeLabel {
                        Text("Normal \(range) \(trend.unit)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Label("What's changed", systemImage: "chart.line.uptrend.xyaxis")
        } footer: {
            Text("Lab markers trending in a concerning direction across your reports.")
        }
    }

    private var symptomsSection: some View {
        Section {
            ForEach(recentSymptoms) { entry in
                HStack(spacing: 10) {
                    Text(entry.intensity.emoji)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.text)
                        Text("\(entry.timestamp, format: .dateTime.month().day()) · \(entry.intensity.label)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Label("Recent symptoms", systemImage: "heart.text.square")
        } footer: {
            Text("From your symptom log over the last two weeks.")
        }
    }

    private var medsSection: some View {
        Section {
            ForEach(activeMeds) { med in
                VStack(alignment: .leading, spacing: 2) {
                    Text(med.dose.isEmpty ? med.name : "\(med.name) · \(med.dose)")
                        .font(.body.weight(.medium))
                    Text(med.scheduleSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Label("Your medications", systemImage: "pills.fill")
        } footer: {
            Text("Confirm these with your doctor — what you take, the doses, and whether anything should change.")
        }
    }

    private var questionsSection: some View {
        Section {
            ForEach(myQuestions, id: \.self) { question in
                Text(question)
            }
            .onDelete { offsets in
                myQuestions.remove(atOffsets: offsets)
                VisitPrepQuestions.save(myQuestions)
            }

            HStack(spacing: 10) {
                TextField("Add your own question", text: $newQuestion, axis: .vertical)
                    .lineLimit(1...3)
                Button {
                    addCustomQuestion()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                }
                .disabled(newQuestion.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Label("Questions to ask", systemImage: "questionmark.bubble")
        } footer: {
            Text(myQuestions.isEmpty
                 ? "Add your own, or tap a suggestion below. Your questions export with the prep."
                 : "Swipe to remove. Your questions export with the prep so you can bring them.")
        }
    }

    @ViewBuilder
    private var suggestionsSection: some View {
        let pending = suggestions.filter { !myQuestions.contains($0) }
        Section {
            ForEach(pending, id: \.self) { suggestion in
                Button {
                    addQuestion(suggestion)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "plus.circle")
                            .foregroundStyle(.blue)
                        Text(suggestion)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                    }
                }
            }

            Button {
                Task { await generateMore() }
            } label: {
                HStack(spacing: 10) {
                    // Glowing sparkles while the on-device model drafts
                    // questions — same "Localabs is thinking" language.
                    GlowingPulseIcon(
                        systemName: "sparkles",
                        tint: .yellow,
                        size: 17,
                        animated: isGenerating
                    )
                    Text(isGenerating ? "Thinking…" : "Suggest questions with Localabs")
                        .foregroundStyle(.primary)
                }
            }
            .disabled(isGenerating || !engine.isModelLoaded)
        } header: {
            Text("Suggestions")
        } footer: {
            Text(engine.isModelLoaded
                 ? "Localabs can draft questions from your trends, symptoms, and medications — on your device."
                 : "Load a model in Profile to have Localabs draft questions for you.")
        }
    }

    private var disclaimerSection: some View {
        Section {
            Label {
                Text("This summary helps you talk with your doctor — it isn't medical advice or a diagnosis.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Data

    private func load() {
        let ownHistory = LocalStorageService.shared.getHistory().filter { $0.isOwnReport }
        worsening = LabTrendService.trends(from: ownHistory).filter { trend in
            if case .worsened? = trend.change { return true }
            return trend.isWorseningStreak()
        }

        let cutoff = Calendar.current.date(byAdding: .day, value: -14, to: Date()) ?? .distantPast
        recentSymptoms = SymptomEntry.loadAll()
            .filter { $0.timestamp >= cutoff }
            .sorted { $0.timestamp > $1.timestamp }

        activeMeds = Medication.active
        myQuestions = VisitPrepQuestions.load()

        if let appt = Appointment.loadUpcoming() {
            hasAppointment = true
            appointmentDate = max(appt.date, Date())
            appointmentNote = appt.note
        }

        suggestions = seededSuggestions(ownHistory: ownHistory)
    }

    /// Deterministic starter suggestions: one per worsening marker, plus
    /// the doctor-questions Localabs already wrote for the most recent
    /// report. No inference — these are always available.
    private func seededSuggestions(ownHistory: [StructuredReport]) -> [String] {
        var out: [String] = []

        for trend in worsening {
            if let latest = trend.latest, let first = trend.points.first {
                out.append("Why has my \(trend.canonicalName) gone from \(LabTrend.fmt(first.value)) to \(LabTrend.fmt(latest.value)) \(trend.unit), and what should I do about it?")
            } else {
                out.append("What does my \(trend.canonicalName) result mean for me?")
            }
        }

        // Pull a few of the model's per-report doctor questions from the
        // most recent own report (it already tailored them to the labs).
        if let recent = ownHistory.sorted(by: { $0.effectiveDate > $1.effectiveDate }).first {
            let lines = recent.doctorQuestions
                .split(separator: "\n")
                .map { Self.cleanBullet(String($0)) }
                .filter { $0.count > 12 }
            out.append(contentsOf: lines.prefix(4))
        }

        // Dedupe (case-insensitive) preserving order.
        var seen = Set<String>()
        return out.filter { seen.insert($0.lowercased()).inserted }
    }

    /// Strip a leading list marker and markdown bold so a report's
    /// `doctorQuestions` bullet reads as a clean question string.
    private static func cleanBullet(_ line: String) -> String {
        var t = line.trimmingCharacters(in: .whitespaces)
        if let first = t.first, "-*•".contains(first) {
            t.removeFirst()
            t = t.trimmingCharacters(in: .whitespaces)
        }
        t = t.replacingOccurrences(of: "**", with: "")
        return t.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Actions

    private func addCustomQuestion() {
        let q = newQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        addQuestion(q)
        newQuestion = ""
    }

    private func addQuestion(_ q: String) {
        guard !myQuestions.contains(where: { $0.caseInsensitiveCompare(q) == .orderedSame }) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            myQuestions.append(q)
        }
        VisitPrepQuestions.save(myQuestions)
    }

    private func persistAppointment() {
        if hasAppointment {
            let appt = Appointment(date: appointmentDate, note: appointmentNote)
            appt.save()
            // Arm (or re-arm) the evening post-visit check-in (#34).
            Task { @MainActor in await VisitService.schedule(for: appt) }
        } else {
            Appointment.clear()
            Task { @MainActor in VisitService.cancel() }
        }
    }

    private func generateMore() async {
        isGenerating = true
        defer { isGenerating = false }
        let generated = await engine.generateVisitQuestions(contextSummary: llmContextSummary)
        let fresh = generated.filter { new in
            !suggestions.contains { $0.caseInsensitiveCompare(new) == .orderedSame }
                && !myQuestions.contains { $0.caseInsensitiveCompare(new) == .orderedSame }
        }
        guard !fresh.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            suggestions.append(contentsOf: fresh)
        }
    }

    // MARK: - Context + export text

    private var llmContextSummary: String {
        var blocks: [String] = []
        if !worsening.isEmpty {
            let lines = worsening.map { t -> String in
                let move = (t.latest != nil && t.points.first != nil)
                    ? "\(LabTrend.fmt(t.points.first!.value)) → \(LabTrend.fmt(t.latest!.value)) \(t.unit)"
                    : ""
                let range = t.referenceRangeLabel.map { " (normal \($0))" } ?? ""
                return "- \(t.canonicalName): \(move)\(range)"
            }
            blocks.append("Worsening lab markers:\n\(lines.joined(separator: "\n"))")
        }
        if !recentSymptoms.isEmpty {
            let lines = recentSymptoms.prefix(8).map { "- \($0.text) (\($0.intensity.label.lowercased()))" }
            blocks.append("Recent symptoms:\n\(lines.joined(separator: "\n"))")
        }
        if !activeMeds.isEmpty {
            let lines = activeMeds.map { "- \($0.promptLine)" }
            blocks.append("Current medications:\n\(lines.joined(separator: "\n"))")
        }
        return blocks.joined(separator: "\n\n")
    }

    /// Plain-text prep summary for the share sheet — something the user
    /// can text to themselves, print, or read off their phone in the room.
    private var exportText: String {
        var out = "Localabs — Visit Prep\n"

        if hasAppointment {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            out += "Appointment: \(f.string(from: appointmentDate))"
            if !appointmentNote.isEmpty { out += " — \(appointmentNote)" }
            out += "\n"
        }
        out += "\n"

        if !worsening.isEmpty {
            out += "WHAT'S CHANGED\n"
            for t in worsening {
                if let latest = t.latest, let first = t.points.first {
                    let range = t.referenceRangeLabel.map { " (normal \($0))" } ?? ""
                    out += "• \(t.canonicalName): \(LabTrend.fmt(first.value)) → \(LabTrend.fmt(latest.value)) \(t.unit)\(range)\n"
                }
            }
            out += "\n"
        }

        if !recentSymptoms.isEmpty {
            out += "RECENT SYMPTOMS\n"
            let f = DateFormatter(); f.dateFormat = "MMM d"
            for s in recentSymptoms {
                out += "• \(f.string(from: s.timestamp)): \(s.text) (\(s.intensity.label.lowercased()))\n"
            }
            out += "\n"
        }

        if !activeMeds.isEmpty {
            out += "MEDICATIONS\n"
            for m in activeMeds {
                out += "• \(m.promptLine)\n"
            }
            out += "\n"
        }

        if !myQuestions.isEmpty {
            out += "QUESTIONS FOR MY DOCTOR\n"
            for (i, q) in myQuestions.enumerated() {
                out += "\(i + 1). \(q)\n"
            }
            out += "\n"
        }

        out += "Generated by Localabs for discussion with your doctor — not medical advice."
        return out
    }
}
