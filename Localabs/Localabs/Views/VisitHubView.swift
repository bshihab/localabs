import SwiftUI

/// The "Doctor Visit" notes interface, opened from the Home pane. Brings
/// the before-visit prep (#30) and after-visit check-in (#34) together in
/// one place, with the current appointment surfaced at the top. The
/// appointment + questions are persisted (Appointment / VisitPrepQuestions),
/// so this hub is where the user returns to them.
struct VisitHubView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var visit: Appointment?
    @State private var pastVisits: [PastVisit] = []
    @State private var selectedPastVisit: PastVisit?
    @State private var showPrep = false
    @State private var showCheckIn = false

    private var visitHasPassed: Bool {
        guard let visit else { return false }
        return visit.date < Date()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let visit {
                        statusCard(visit)
                    }

                    actionCard(
                        icon: "checklist",
                        color: .blue,
                        title: "Before your visit",
                        subtitle: "Prep what to bring — your trends, symptoms, medications, and questions to ask."
                    ) { showPrep = true }

                    actionCard(
                        icon: "square.and.pencil",
                        color: .green,
                        title: "After your visit",
                        subtitle: "Log new or changed meds, new instructions, and schedule your next visit.",
                        highlighted: visitHasPassed
                    ) { showCheckIn = true }

                    if !pastVisits.isEmpty {
                        pastVisitsSection
                    }

                    Label {
                        Text("Set an appointment in prep and Localabs reminds you the evening after to log what changed. Informational — not medical advice.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }
                .padding()
            }
            .scrollContentBackground(.hidden)
            .background(.background)
            .navigationTitle("Doctor Visits")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .sheet(isPresented: $showPrep, onDismiss: load) { PreVisitPrepView() }
        .sheet(isPresented: $showCheckIn, onDismiss: load) { PostVisitCheckInView(visit: visit) }
        .sheet(item: $selectedPastVisit) { past in PastVisitDetailView(visit: past) }
        .onAppear(perform: load)
    }

    // MARK: - Cards

    private func statusCard(_ visit: Appointment) -> some View {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .short
        return HStack(spacing: 12) {
            Image(systemName: visitHasPassed ? "checkmark.circle.fill" : "calendar")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(
                    LinearGradient(
                        colors: visitHasPassed
                            ? [.green, .green.opacity(0.8)]
                            : [.purple, .purple.opacity(0.8)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    in: Circle()
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(visitHasPassed ? "Your visit has passed" : "Upcoming visit")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(f.string(from: visit.date))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                if !visit.note.isEmpty {
                    Text(visit.note)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func actionCard(
        icon: String,
        color: Color,
        title: String,
        subtitle: String,
        highlighted: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(
                        LinearGradient(
                            colors: [color, color.opacity(0.78)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(
                highlighted ? .regular.tint(color.opacity(0.16)) : .regular,
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Past visits (#4)

    private var pastVisitsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Past visits")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.leading, 4)
                .padding(.top, 8)

            ForEach(pastVisits) { past in
                pastVisitCard(past)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pastVisitCard(_ past: PastVisit) -> some View {
        let f = DateFormatter()
        f.dateStyle = .medium
        return Button {
            selectedPastVisit = past
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.green)
                    .frame(width: 28)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(f.string(from: past.date))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                    if !past.note.isEmpty {
                        Text(past.note)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    Text(pastVisitPreview(past))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 3)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                VisitHistory.remove(id: past.id)
                load()
            } label: {
                Label("Delete from history", systemImage: "trash")
            }
        }
    }

    /// One-line summary of what's stored for a past visit, so the card
    /// hints at the detail behind the tap.
    private func pastVisitPreview(_ past: PastVisit) -> String {
        var parts: [String] = []
        if !past.preVisitQuestions.isEmpty {
            parts.append("\(past.preVisitQuestions.count) question\(past.preVisitQuestions.count == 1 ? "" : "s")")
        }
        if !past.instructions.isEmpty {
            parts.append("notes")
        }
        return parts.isEmpty ? "Tap to view" : "Tap to view — \(parts.joined(separator: " · "))"
    }

    private func load() {
        visit = Appointment.loadUpcoming()
        pastVisits = VisitHistory.all()
    }
}

/// Read-only detail for an archived visit (#4): what the user prepared
/// before (their questions) and what they logged after (instructions).
/// Opened by tapping a Past visits card.
struct PastVisitDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let visit: PastVisit

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Date", value: dateString)
                    if !visit.note.isEmpty {
                        LabeledContent("For", value: visit.note)
                    }
                } header: {
                    Text("Visit")
                }

                Section {
                    if visit.preVisitQuestions.isEmpty {
                        Text("No questions were saved before this visit.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(visit.preVisitQuestions.enumerated()), id: \.offset) { _, q in
                            Text(q)
                        }
                    }
                } header: {
                    Label("Before your visit", systemImage: "checklist")
                } footer: {
                    Text("The questions you prepared to ask.")
                }

                Section {
                    if visit.instructions.isEmpty {
                        Text("No instructions or notes were logged after this visit.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(visit.instructions)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Label("After your visit", systemImage: "square.and.pencil")
                } footer: {
                    Text("What you logged the doctor said — saved to your health profile.")
                }
            }
            .navigationTitle("Visit Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
    }

    private var dateString: String {
        let f = DateFormatter()
        f.dateStyle = .full
        return f.string(from: visit.date)
    }
}
