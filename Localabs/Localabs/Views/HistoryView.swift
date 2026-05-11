import SwiftUI

struct HistoryView: View {
    @State private var reports: [StructuredReport] = []
    @State private var selectedReport: StructuredReport?

    var body: some View {
        NavigationStack {
            Group {
                if reports.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(reports) { report in
                                Button {
                                    selectedReport = report
                                } label: {
                                    historyRow(report: report)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        delete(report: report)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 12)
                        .padding(.bottom, 80)
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Report History")
            .navigationDestination(item: $selectedReport) { report in
                DashboardView(initialReport: report)
            }
        }
        .onAppear {
            reports = LocalStorageService.shared.getHistory()
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

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func delete(report: StructuredReport) {
        LocalStorageService.shared.deleteReport(id: report.id)
        reports.removeAll { $0.id == report.id }
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
