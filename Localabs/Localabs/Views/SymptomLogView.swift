import SwiftUI

/// The user's symptom timeline — a running log of how they've been
/// feeling between visits. Empty by default; populated via the
/// toolbar "+" or by deep-link from elsewhere in the app.
///
/// Reachable as a sheet from the History tab's toolbar. When the
/// pre-visit prep feature ships, the prep screen will also pull
/// the most recent entries into its auto-generated question list,
/// so the data here becomes a load-bearing input for that flow.
struct SymptomLogView: View {
    @State private var entries: [SymptomEntry] = []
    @State private var showQuickAdd: Bool = false
    @State private var editingEntry: SymptomEntry?
    @State private var pendingDeleteID: UUID?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    emptyState
                } else {
                    timeline
                }
            }
            .navigationTitle("Symptoms")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editingEntry = nil
                        showQuickAdd = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                    }
                    .accessibilityLabel("Log a symptom")
                }
            }
            .sheet(isPresented: $showQuickAdd) {
                SymptomQuickAddSheet(editing: editingEntry)
                    .onDisappear { reload() }
            }
            .onAppear { reload() }
            .confirmationDialog(
                "Delete this entry?",
                isPresented: Binding(
                    get: { pendingDeleteID != nil },
                    set: { if !$0 { pendingDeleteID = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let id = pendingDeleteID {
                    Button("Delete", role: .destructive) {
                        SymptomEntry.delete(id: id)
                        pendingDeleteID = nil
                        reload()
                    }
                }
                Button("Cancel", role: .cancel) { pendingDeleteID = nil }
            }
        }
    }

    private func reload() {
        entries = SymptomEntry.loadAll()
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "heart.text.square")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
                .opacity(0.6)
            Text("No symptoms logged yet")
                .font(.title3.weight(.semibold))
            Text("Tap + to record how you're feeling. Even a short note helps Localabs surface patterns to bring up at your next doctor visit.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                editingEntry = nil
                showQuickAdd = true
            } label: {
                Label("Log a symptom", systemImage: "plus")
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

    // MARK: - Timeline

    private var timeline: some View {
        List {
            ForEach(groupedByWeek, id: \.weekStart) { week in
                Section {
                    ForEach(week.entries) { entry in
                        SymptomRow(entry: entry)
                            .contentShape(Rectangle())
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    pendingDeleteID = entry.id
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button {
                                    editingEntry = entry
                                    showQuickAdd = true
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                    }
                } header: {
                    Text(week.label)
                }
            }
        }
    }

    /// Bucket entries by ISO week-of-year, then sort descending so
    /// "This week" floats to the top. Date headers give the timeline
    /// a sense of pace — "two headaches this week" reads at a glance.
    private var groupedByWeek: [WeekGroup] {
        let calendar = Calendar.current
        var buckets: [Date: [SymptomEntry]] = [:]
        for entry in entries {
            let weekStart = calendar
                .dateInterval(of: .weekOfYear, for: entry.timestamp)?.start
                ?? entry.timestamp
            buckets[weekStart, default: []].append(entry)
        }
        return buckets
            .map { (start, items) in
                WeekGroup(
                    weekStart: start,
                    entries: items.sorted { $0.timestamp > $1.timestamp }
                )
            }
            .sorted { $0.weekStart > $1.weekStart }
    }

    private struct WeekGroup {
        let weekStart: Date
        let entries: [SymptomEntry]

        var label: String {
            let calendar = Calendar.current
            let now = Date()
            let thisWeekStart = calendar
                .dateInterval(of: .weekOfYear, for: now)?.start ?? now

            if calendar.isDate(
                weekStart,
                equalTo: thisWeekStart,
                toGranularity: .weekOfYear
            ) {
                return "This week"
            }
            if let lastWeek = calendar.date(
                byAdding: .weekOfYear,
                value: -1,
                to: thisWeekStart
            ), calendar.isDate(
                weekStart,
                equalTo: lastWeek,
                toGranularity: .weekOfYear
            ) {
                return "Last week"
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            return "Week of \(formatter.string(from: weekStart))"
        }
    }
}

private struct SymptomRow: View {
    let entry: SymptomEntry

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 2) {
                Text(entry.intensity.emoji)
                    .font(.system(size: 30))
                Text(entry.intensity.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 56)

            VStack(alignment: .leading, spacing: 6) {
                Text(entry.text)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(4)
                if !entry.tags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(entry.tags.prefix(4), id: \.self) { tag in
                            Text(tag)
                                .font(.caption2)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(Color.accentColor.opacity(0.14))
                                )
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
                Text(
                    entry.timestamp,
                    format: .dateTime
                        .weekday(.abbreviated)
                        .month()
                        .day()
                        .hour()
                        .minute()
                )
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}
