import SwiftUI
import UIKit

struct HistoryView: View {
    @State private var reports: [StructuredReport] = []
    @State private var selectedReport: StructuredReport?
    /// Drives the iOS Edit / Done toggle. Active mode hides the
    /// swipe-to-delete affordance and replaces tap-to-navigate with
    /// tap-to-select; the toolbar grows a Share button.
    @State private var editMode: EditMode = .inactive
    @State private var selection: Set<UUID> = []
    @State private var shareItems: [Any] = []
    @State private var showShareSheet = false

    var body: some View {
        NavigationStack {
            Group {
                if reports.isEmpty {
                    emptyState
                } else {
                    reportsList
                }
            }
            .navigationTitle("Report History")
            .navigationDestination(item: $selectedReport) { report in
                DashboardView(initialReport: report)
            }
            .toolbar {
                if !reports.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(editMode.isEditing ? "Done" : "Edit") {
                            withAnimation {
                                editMode = editMode.isEditing ? .inactive : .active
                                if !editMode.isEditing { selection.removeAll() }
                            }
                        }
                    }
                    if editMode.isEditing {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                shareSelected()
                            } label: {
                                Label(
                                    "Share\(selection.isEmpty ? "" : " (\(selection.count))")",
                                    systemImage: "square.and.arrow.up"
                                )
                            }
                            .disabled(selection.isEmpty)
                        }
                    }
                }
            }
            .environment(\.editMode, $editMode)
            .sheet(isPresented: $showShareSheet) {
                ShareSheet(items: shareItems)
            }
        }
        .onAppear {
            reports = LocalStorageService.shared.getHistory()
        }
    }

    // MARK: - Reports list

    /// A `List` (rather than a custom ScrollView) so we get
    /// `.swipeActions` and `EditButton`-driven multi-select for free.
    /// The glass card look is preserved by clearing the default list
    /// row background and hiding separators.
    private var reportsList: some View {
        List(selection: $selection) {
            ForEach(reports) { report in
                rowContent(for: report)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            delete(report: report)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .tag(report.id)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    /// In normal mode the row is a NavigationLink into the Dashboard;
    /// in Edit mode the List takes over tap handling (toggles selection
    /// via the binding) so we drop the NavigationLink to avoid double
    /// behavior.
    @ViewBuilder
    private func rowContent(for report: StructuredReport) -> some View {
        if editMode.isEditing {
            historyRow(report: report)
        } else {
            Button {
                selectedReport = report
            } label: {
                historyRow(report: report)
            }
            .buttonStyle(.plain)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            ZStack {
                Circle()
                    .fill(.secondary.opacity(0.12))
                    .frame(width: 80, height: 80)
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
            }
            Text("No Reports Yet")
                .font(.system(size: 22, weight: .bold))
            Text("Scanned lab reports will appear here\nso you can review them anytime.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
            Spacer()
        }
    }

    private func historyRow(report: StructuredReport) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(.blue.opacity(0.16))
                    .frame(width: 44, height: 44)
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.blue)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(formatDate(report.timestamp))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(String(report.patientSummary.prefix(80)) + "…")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            Spacer()

            if !editMode.isEditing {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: - Actions

    private func delete(report: StructuredReport) {
        LocalStorageService.shared.deleteReport(id: report.id)
        reports.removeAll { $0.id == report.id }
        selection.remove(report.id)
    }

    /// Builds the share payload (translation text + scan images) for
    /// each selected report, then opens the system share sheet. Sharing
    /// multiple reports concatenates the text and includes every page
    /// image across all selections, so the recipient gets one bundle.
    private func shareSelected() {
        let chosen = reports.filter { selection.contains($0.id) }
        guard !chosen.isEmpty else { return }

        var items: [Any] = []
        let translations = chosen.map(translationText(for:)).joined(separator: "\n\n———\n\n")
        items.append(translations)

        for report in chosen {
            for url in report.allImageURLs {
                if let img = UIImage(contentsOfFile: url.path) {
                    items.append(img)
                }
            }
        }

        shareItems = items
        showShareSheet = true
    }

    /// Plain-text rendering of a single report — what gets dropped into
    /// Messages / Mail / Notes / etc. when the user shares. Includes
    /// the date header and every non-empty section.
    private func translationText(for report: StructuredReport) -> String {
        var lines: [String] = []
        lines.append("Localabs Report — \(formatDate(report.timestamp))")
        lines.append("")
        appendSection(&lines, title: "PATIENT SUMMARY", body: report.patientSummary)
        appendSection(&lines, title: "QUESTIONS FOR YOUR DOCTOR", body: report.doctorQuestions)
        appendSection(&lines, title: "TARGETED DIETARY ADVICE", body: report.dietaryAdvice)
        appendSection(&lines, title: "MEDICAL GLOSSARY", body: report.medicalGlossary)
        appendSection(&lines, title: "MEDICATION NOTES", body: report.medicationNotes)
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func appendSection(_ lines: inout [String], title: String, body: String) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lines.append(title)
        lines.append(trimmed)
        lines.append("")
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        let calendar = Calendar.current

        if calendar.isDateInToday(date) {
            formatter.dateFormat = "'Today at' h:mm a"
        } else if calendar.isDateInYesterday(date) {
            formatter.dateFormat = "'Yesterday at' h:mm a"
        } else {
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
        }

        return formatter.string(from: date)
    }
}

/// UIKit bridge for the system share sheet. Used here for multi-select
/// sharing from History — the activity controller picks up Strings as
/// the body and UIImages as attachments, so iOS lays them out the way
/// the destination (Messages, Mail, etc.) expects.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
