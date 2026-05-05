import SwiftUI

struct HistoryView: View {
    @State private var reports: [StructuredReport] = []
    @State private var selectedReport: StructuredReport?
    
    var body: some View {
        NavigationStack {
            Group {
                if reports.isEmpty {
                    // Empty State
                    VStack(spacing: 16) {
                        Spacer()
                        ZStack {
                            Circle()
                                .fill(.secondary.opacity(0.1))
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
                } else {
                    List {
                        ForEach(reports) { report in
                            Button {
                                selectedReport = report
                            } label: {
                                HStack(spacing: 14) {
                                    ZStack {
                                        Circle()
                                            .fill(.blue.opacity(0.12))
                                            .frame(width: 44, height: 44)
                                        Image(systemName: "doc.text.fill")
                                            .font(.system(size: 18))
                                            .foregroundColor(.blue)
                                    }
                                    
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(formatDate(report.timestamp))
                                            .font(.system(size: 17, weight: .semibold))
                                            .foregroundStyle(.primary)
                                        
                                        Text(String(report.patientSummary.prefix(80)) + "...")
                                            .font(.system(size: 14))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                    
                                    Spacer()
                                    
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .onDelete(perform: deleteReport)
                    }
                }
            }
            .navigationTitle("Report History")
            .navigationDestination(item: $selectedReport) { report in
                DashboardView(initialReport: report)
            }
            .toolbar {
                if !reports.isEmpty {
                    EditButton()
                }
            }
        }
        .onAppear {
            reports = LocalStorageService.shared.getHistory()
        }
    }
    
    private func deleteReport(at offsets: IndexSet) {
        for index in offsets {
            LocalStorageService.shared.deleteReport(id: reports[index].id)
        }
        reports.remove(atOffsets: offsets)
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
