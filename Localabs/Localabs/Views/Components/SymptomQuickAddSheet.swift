import SwiftUI

/// Compact sheet for logging one symptom. Mirrors the
/// `ProfileQuickAddSheet` pattern — narrow scope, low friction,
/// auto-dismiss after save so the user can keep moving.
///
/// Reachable from the SymptomLogView toolbar "+" (new entry) or
/// from a row's swipe-Edit action (edit existing entry).
struct SymptomQuickAddSheet: View {
    /// Pre-existing entry when opened in edit mode. Nil for fresh.
    let editing: SymptomEntry?

    @Environment(\.dismiss) private var dismiss

    @State private var text: String = ""
    @State private var intensity: SymptomEntry.Intensity = .moderate
    @State private var timestamp: Date = Date()
    @State private var selectedTags: Set<String> = []
    @State private var customTag: String = ""
    @State private var showSavedConfirmation: Bool = false
    @FocusState private var tagFieldFocused: Bool

    /// Seeded once at init — the recent-tags chip row doesn't need
    /// to react to live changes inside the sheet (the user can't
    /// add new entries from within this sheet, so the recent set
    /// can't change underneath them).
    private let recentTags: [String]

    /// Common symptom tags offered as suggestions so a brand-new
    /// user (with no logged history yet) still gets one-tap chips.
    /// Merged after the user's own recent tags, deduped.
    private static let presetTags = [
        "Headache", "Fatigue", "Nausea", "Pain", "Dizziness",
        "Fever", "Cough", "Insomnia", "Anxiety", "Shortness of breath"
    ]

    init(editing: SymptomEntry? = nil) {
        self.editing = editing
        self.recentTags = SymptomEntry.recentTags(limit: 8)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        "What are you feeling?",
                        text: $text,
                        axis: .vertical
                    )
                    .lineLimit(2...6)
                } header: {
                    Text("Symptom")
                } footer: {
                    Text("A sentence or two. Stays on this device — Localabs uses it as context for your next doctor visit, never sends it anywhere.")
                }

                Section {
                    intensityPicker
                } header: {
                    Text("Intensity")
                }

                Section {
                    DatePicker(
                        "When",
                        selection: $timestamp,
                        in: ...Date(),
                        displayedComponents: [.date, .hourAndMinute]
                    )
                }

                // Single, stable Section — the text field is ALWAYS
                // the last child so its view identity never changes
                // as chips appear/disappear above it. The previous
                // version swapped between two different Sections
                // depending on whether the field was empty, which
                // destroyed and recreated the TextField on the first
                // keystroke and dropped the keyboard.
                Section {
                    if !displayTags.isEmpty {
                        SymptomTagFlow(spacing: 8) {
                            ForEach(displayTags, id: \.self) { tag in
                                tagChip(tag)
                            }
                        }
                    }

                    HStack {
                        TextField("Add a tag…", text: $customTag)
                            .focused($tagFieldFocused)
                            .submitLabel(.done)
                            .onSubmit(addCustomTag)
                        Button("Add", action: addCustomTag)
                            .disabled(trimmedCustomTag.isEmpty)
                    }
                } header: {
                    Text("Tags")
                } footer: {
                    Text("Optional. Tap a suggestion or type your own. Tags help Localabs group recurring symptoms across visits.")
                }

                if showSavedConfirmation {
                    Section {
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Logged")
                            Spacer()
                        }
                    }
                    .transition(.opacity)
                }
            }
            .navigationTitle(editing == nil ? "Log a Symptom" : "Edit Symptom")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                        .fontWeight(.semibold)
                }
            }
            .onAppear { seedFromEditing() }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Intensity picker

    private var intensityPicker: some View {
        HStack(spacing: 12) {
            ForEach(SymptomEntry.Intensity.allCases, id: \.rawValue) { level in
                Button {
                    intensity = level
                } label: {
                    VStack(spacing: 4) {
                        Text(level.emoji)
                            .font(.system(size: 28))
                        Text(level.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(intensity == level
                                  ? Color.accentColor.opacity(0.18)
                                  : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .sensoryFeedback(.selection, trigger: intensity)
            }
        }
    }

    // MARK: - Tag chips

    /// Chips shown above the text field: the user's selected tags
    /// (sticky on top), then their own recent tags, then common
    /// presets — deduped case-insensitively so "Headache" /
    /// "headache" don't both appear. Presets guarantee a new user
    /// with no history still gets one-tap suggestions.
    private var displayTags: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for tag in Array(selectedTags).sorted() + recentTags + Self.presetTags {
            if seen.insert(tag.lowercased()).inserted {
                ordered.append(tag)
            }
        }
        return ordered
    }

    private func tagChip(_ tag: String) -> some View {
        let isOn = selectedTags.contains(tag)
        return Button {
            if isOn { selectedTags.remove(tag) } else { selectedTags.insert(tag) }
        } label: {
            Text(tag)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(isOn
                              ? Color.accentColor.opacity(0.20)
                              : Color(.secondarySystemBackground))
                )
                .foregroundStyle(isOn ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private var trimmedCustomTag: String {
        customTag.trimmingCharacters(in: .whitespaces)
    }

    private func addCustomTag() {
        let tag = trimmedCustomTag
        guard !tag.isEmpty else { return }
        selectedTags.insert(tag)
        customTag = ""
    }

    // MARK: - Save

    private var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func seedFromEditing() {
        guard let entry = editing else { return }
        text = entry.text
        intensity = entry.intensity
        timestamp = entry.timestamp
        selectedTags = Set(entry.tags)
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let entry = SymptomEntry(
            id: editing?.id ?? UUID(),
            text: trimmed,
            intensity: intensity,
            timestamp: timestamp,
            tags: Array(selectedTags).sorted(),
            linkedReportID: editing?.linkedReportID
        )
        SymptomEntry.save(entry)
        withAnimation(.easeInOut(duration: 0.15)) {
            showSavedConfirmation = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            dismiss()
        }
    }
}

/// Lightweight flow layout for tag chips — wraps to next row when
/// the next chip wouldn't fit. SwiftUI's stock layouts don't ship a
/// FlowLayout, so this is a minimal one tailored to the chip row.
private struct SymptomTagFlow: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let containerWidth = proposal.width ?? .infinity
        return arrange(subviews: subviews, containerWidth: containerWidth).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let arrangement = arrange(subviews: subviews, containerWidth: bounds.width)
        for (subview, frame) in zip(subviews, arrangement.frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func arrange(
        subviews: Subviews,
        containerWidth: CGFloat
    ) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var rowOriginX: CGFloat = 0
        var rowOriginY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowOriginX + size.width > containerWidth && rowOriginX > 0 {
                rowOriginY += rowHeight + spacing
                rowOriginX = 0
                rowHeight = 0
            }
            frames.append(CGRect(
                x: rowOriginX,
                y: rowOriginY,
                width: size.width,
                height: size.height
            ))
            rowOriginX += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, rowOriginX - spacing)
        }
        return (frames, CGSize(width: maxX, height: rowOriginY + rowHeight))
    }
}
