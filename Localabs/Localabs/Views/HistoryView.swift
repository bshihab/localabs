import SwiftUI
import UIKit

struct HistoryView: View {
    @State private var reports: [StructuredReport] = []
    @State private var selectedReport: StructuredReport?
    /// Drives the Select / Done toggle. Active mode shows checkboxes
    /// and grows the toolbar to include both Share and Delete actions
    /// scoped to the selection.
    @State private var editMode: EditMode = .inactive
    @State private var selection: Set<UUID> = []
    @State private var shareItems: [Any] = []
    @State private var showShareSheet = false
    /// Long-press menu target — set when the user taps Rename in the
    /// context menu, drives the .alert with a TextField.
    @State private var renameTarget: StructuredReport?
    @State private var renameText: String = ""
    /// Single-report delete confirmation (from context menu). Bulk
    /// delete (from Select-mode toolbar) uses its own bool flag so
    /// we can present a confirmationDialog with the count.
    @State private var deleteTarget: StructuredReport?
    @State private var showBulkDeleteConfirmation = false

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
                        Button(editMode.isEditing ? "Done" : "Select") {
                            withAnimation {
                                editMode = editMode.isEditing ? .inactive : .active
                                if !editMode.isEditing { selection.removeAll() }
                            }
                        }
                    }
                    if editMode.isEditing {
                        // Share and Delete in the TOP-LEADING toolbar
                        // so they sit above the iOS 26 Liquid Glass
                        // tab bar rather than getting visually
                        // obscured behind it. Apple's HIG pattern is
                        // .bottomBar, but on iOS 26 the new tab bar
                        // overlaps that placement enough that the
                        // actions read as "below the tab bar" instead
                        // of "above the selection." Done stays in
                        // .topBarTrailing.
                        ToolbarItem(placement: .topBarLeading) {
                            HStack(spacing: 16) {
                                Button {
                                    shareSelected()
                                } label: {
                                    Label(
                                        "Share\(selection.isEmpty ? "" : " (\(selection.count))")",
                                        systemImage: "square.and.arrow.up"
                                    )
                                }
                                .disabled(selection.isEmpty)

                                Button(role: .destructive) {
                                    showBulkDeleteConfirmation = true
                                } label: {
                                    Label(
                                        "Delete\(selection.isEmpty ? "" : " (\(selection.count))")",
                                        systemImage: "trash"
                                    )
                                }
                                .tint(.red)
                                .disabled(selection.isEmpty)
                            }
                        }
                    }
                }
            }
            .environment(\.editMode, $editMode)
            .sheet(isPresented: $showShareSheet) {
                ShareSheet(items: shareItems)
            }
            // Rename alert. Bound to renameTarget so it presents only
            // when the user picks Rename from the context menu, and
            // dismisses by clearing the target.
            .alert(
                "Rename report",
                isPresented: Binding(
                    get: { renameTarget != nil },
                    set: { presenting in
                        if !presenting { renameTarget = nil }
                    }
                ),
                presenting: renameTarget
            ) { target in
                TextField("Title", text: $renameText)
                Button("Save") {
                    commitRename(for: target)
                }
                Button("Cancel", role: .cancel) {
                    renameTarget = nil
                }
            } message: { _ in
                Text("Give this report a short title — what you'll see in History and at the top of the dashboard.")
            }
            // Destructive confirmations use confirmationDialog (action
            // sheet) instead of alert — matches Apple's pattern in
            // Photos / Notes / Messages, where "Delete?" prompts
            // slide up from the bottom anchored to the action that
            // triggered them rather than appearing as a centered
            // modal.
            .confirmationDialog(
                deleteTarget.map { "Delete \"\($0.displayTitle)\"?" } ?? "Delete report?",
                isPresented: Binding(
                    get: { deleteTarget != nil },
                    set: { presenting in
                        if !presenting { deleteTarget = nil }
                    }
                ),
                titleVisibility: .visible,
                presenting: deleteTarget
            ) { target in
                Button("Delete Report", role: .destructive) {
                    delete(report: target)
                    deleteTarget = nil
                }
                Button("Cancel", role: .cancel) {
                    deleteTarget = nil
                }
            } message: { _ in
                Text("This report will be removed from History. This can't be undone.")
            }
            .confirmationDialog(
                "Delete \(selection.count) report\(selection.count == 1 ? "" : "s")?",
                isPresented: $showBulkDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button(
                    "Delete \(selection.count) Report\(selection.count == 1 ? "" : "s")",
                    role: .destructive
                ) {
                    deleteSelected()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The selected reports will be removed from History. This can't be undone.")
            }
        }
        .onAppear {
            reports = LocalStorageService.shared.getHistory()
        }
    }

    // MARK: - Reports list

    /// A `List` so we keep the `EditButton`-driven multi-select for
    /// free. Swipe-to-delete is gone — every destructive action is
    /// now explicit (long-press context menu OR Select-mode toolbar)
    /// to prevent accidental wipes. The glass card look is preserved
    /// by clearing the default list row background and hiding
    /// separators.
    private var reportsList: some View {
        List(selection: $selection) {
            ForEach(reports) { report in
                rowContent(for: report)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .tag(report.id)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    /// In normal mode the row is a Button that opens the dashboard
    /// AND a long-press context menu (Rename / Share / Delete). In
    /// Edit mode the List takes over tap handling for multi-select,
    /// and the context menu is suppressed to avoid two gestures
    /// fighting.
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
            .contextMenu {
                Button {
                    renameText = report.displayTitle
                    renameTarget = report
                } label: {
                    Label("Rename Report", systemImage: "pencil")
                }
                Button {
                    shareSingle(report: report)
                } label: {
                    Label("Share Report", systemImage: "square.and.arrow.up")
                }
                Button(role: .destructive) {
                    deleteTarget = report
                } label: {
                    Label("Delete Report", systemImage: "trash")
                }
            }
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

    /// History row: LLM-generated title on top, date+time as a small
    /// secondary subheading, then a 2-line preview of the patient
    /// summary so the user can pick the right report at a glance
    /// without opening it.
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

            VStack(alignment: .leading, spacing: 3) {
                Text(report.displayTitle)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(formatDate(report.timestamp))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)

                Text(previewText(for: report))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .padding(.top, 2)
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

    /// One- or two-line preview from the report's patient summary,
    /// with the surrounding markdown trimmed so the preview reads as
    /// plain prose. Strips bullet prefixes, `**bold**` markers, and
    /// leading whitespace so the row doesn't show literal `- ` /
    /// `**` characters.
    private func previewText(for report: StructuredReport) -> String {
        let raw = report.patientSummary
        guard !raw.isEmpty else { return "No summary available." }
        let stripped = raw
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "*", with: "")
        // Join the first ~120 chars of non-empty lines, removing
        // bullet prefixes — keeps the preview compact and clean.
        let lines = stripped
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { line -> String in
                if line.hasPrefix("- ") { return String(line.dropFirst(2)) }
                if line.hasPrefix("• ") { return String(line.dropFirst(2)) }
                return line
            }
        let joined = lines.joined(separator: " ")
        return joined.count > 140 ? "\(joined.prefix(140))…" : joined
    }

    // MARK: - Actions

    private func delete(report: StructuredReport) {
        LocalStorageService.shared.deleteReport(id: report.id)
        reports.removeAll { $0.id == report.id }
        selection.remove(report.id)
    }

    /// Bulk delete from the Select-mode toolbar. Removes every
    /// selected report from disk + the in-memory list, then drops
    /// out of Select mode so the user lands on a clean History.
    private func deleteSelected() {
        let toDelete = selection
        for id in toDelete {
            LocalStorageService.shared.deleteReport(id: id)
        }
        reports.removeAll { toDelete.contains($0.id) }
        selection.removeAll()
        withAnimation {
            editMode = .inactive
        }
    }

    /// Renames the report with the trimmed text the user typed in
    /// the alert TextField. Empty input keeps the existing title.
    /// Writes back to storage immediately so the change survives a
    /// restart.
    private func commitRename(for target: StructuredReport) {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let idx = reports.firstIndex(where: { $0.id == target.id }) {
            reports[idx].title = trimmed
            LocalStorageService.shared.saveReport(reports[idx])
        }
        renameTarget = nil
        renameText = ""
    }

    /// One-tap share for a single report from the context menu —
    /// same payload shape as the multi-select share, just scoped to
    /// one item.
    private func shareSingle(report: StructuredReport) {
        var items: [Any] = []
        items.append(translationText(for: report))
        for url in report.allImageURLs {
            if let img = UIImage(contentsOfFile: url.path) {
                items.append(img)
            }
        }
        shareItems = items
        showShareSheet = true
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
