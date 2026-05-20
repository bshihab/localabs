import SwiftUI

/// Compact sheet for adding one fact to the user's profile from
/// inside a chat. Replaces the previous auto-detection feature
/// (regex scanner on user messages + `[PROFILE_ADD: …]` model
/// signals), which was too unreliable to be worth the popups.
///
/// Single tap on the "+" in any chat input bar opens this sheet
/// with the user's current draft text pre-filled — they pick a
/// field, edit the value if needed, tap Save. Writes go through
/// `UserProfile.add(_:to:)` which append-uniques multi-line fields
/// and overwrites single-value ones (the user explicitly picked
/// the field, they know they're replacing).
struct ProfileQuickAddSheet: View {
    /// Pre-filled value — typically the text the user has typed in
    /// the chat input bar at the moment they tapped "+". Empty
    /// string is fine; the user can type from scratch.
    let prefilledValue: String

    @Environment(\.dismiss) private var dismiss

    /// Default to the first multi-line field (Medical Conditions)
    /// since it's the most commonly added in our usage. The user
    /// can change via the picker.
    @State private var selectedField: UserProfile.Field = .medicalConditions
    @State private var inputValue: String = ""
    /// Brief "✓ Saved" confirmation shown before the sheet dismisses,
    /// so the user gets visible feedback that the write succeeded.
    @State private var showSavedConfirmation: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Field", selection: $selectedField) {
                        ForEach(UserProfile.Field.allCases) { field in
                            Text(field.displayName).tag(field)
                        }
                    }
                } header: {
                    Text("Where this gets saved")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(footerText(for: selectedField))
                        Text("This becomes context for every future analysis and chat — Localabs reads your profile silently so answers stay personalized. Everything stays on this device; nothing is sent to a server.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    if selectedField.isMultiLine {
                        TextField(
                            selectedField.placeholder,
                            text: $inputValue,
                            axis: .vertical
                        )
                        .lineLimit(2...6)
                    } else {
                        TextField(selectedField.placeholder, text: $inputValue)
                    }
                } header: {
                    Text(selectedField.displayName)
                } footer: {
                    if !selectedField.isMultiLine,
                       let existing = currentExistingValue,
                       !existing.isEmpty {
                        Text("Will replace your saved value: \"\(existing)\"")
                            .foregroundStyle(.orange)
                    }
                }

                if showSavedConfirmation {
                    Section {
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Added to your profile")
                                .foregroundStyle(.primary)
                            Spacer()
                        }
                    }
                    .transition(.opacity)
                }
            }
            .navigationTitle("Add to Profile")
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
            .onAppear {
                // Seed the input with whatever the user had in the
                // chat input bar when they tapped "+". They can
                // edit before saving.
                if inputValue.isEmpty { inputValue = prefilledValue }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var canSave: Bool {
        !inputValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// For single-value fields, surfaces the currently-stored value
    /// so the sheet can warn the user before they overwrite it.
    /// Multi-line fields don't show this (we always append, so no
    /// risk of clobbering).
    private var currentExistingValue: String? {
        guard !selectedField.isMultiLine else { return nil }
        let profile = UserProfile.load()
        return profile.value(for: selectedField).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Footer copy tailored per field — explains where the entry
    /// lands in the profile + how it'll be used.
    private func footerText(for field: UserProfile.Field) -> String {
        switch field {
        case .medicalConditions, .medications, .familyHistory:
            return "Adds as a new line in your profile's \(field.displayName.lowercased()) — duplicates are skipped automatically."
        case .smoking, .alcohol, .bloodType, .age, .biologicalSex:
            return "Replaces the current value in your profile."
        }
    }

    private func save() {
        var profile = UserProfile.load()
        let changed = profile.add(inputValue, to: selectedField)
        if changed {
            profile.save()
        }
        // Show a brief checkmark even if `changed` was false (e.g.
        // the user added a duplicate condition — from their POV
        // they meant to save it, so a "didn't actually change"
        // banner would feel like an error). Auto-dismiss after a
        // beat so they're not stuck on the sheet.
        withAnimation(.easeInOut(duration: 0.15)) {
            showSavedConfirmation = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            dismiss()
        }
    }
}
