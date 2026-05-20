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
    /// Drives a validation alert when Save is tapped with a value
    /// that doesn't fit the selected field (e.g. letters in the age
    /// field, or somehow a non-allowed picker value).
    @State private var validationMessage: String?

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
                    // Render the right input control for the field's
                    // data type:
                    //   - Picker for closed-set fields (biological
                    //     sex / smoking / alcohol / blood type) so
                    //     the user can't type "blue" for blood type
                    //     or "male-ish" for biological sex.
                    //   - Numeric TextField with the number keypad
                    //     for age (still validated on Save in case
                    //     the user pastes letters in).
                    //   - Free-text TextField for medical conditions
                    //     / medications / family history.
                    if let options = selectedField.allowedValues {
                        Picker(selectedField.displayName, selection: $inputValue) {
                            ForEach(options, id: \.self) { option in
                                Text(option).tag(option)
                            }
                        }
                        .pickerStyle(.menu)
                    } else if selectedField.isNumeric {
                        TextField(selectedField.placeholder, text: $inputValue)
                            .keyboardType(.numberPad)
                    } else if selectedField.isMultiLine {
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
                // When the user switches to a Picker-style field,
                // snap inputValue to a valid option. Without this,
                // the prefilled chat text (e.g. "I'm 35 years old")
                // wouldn't match any allowed value and the Picker
                // would render with no selection highlighted.
                .onChange(of: selectedField) { _, newField in
                    if let options = newField.allowedValues,
                       !options.contains(inputValue) {
                        inputValue = options.first ?? ""
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
                // If the user opens the sheet directly onto a picker
                // field, ensure inputValue is a valid option from
                // the start (covers the case where the prefilled
                // chat text didn't match any allowed value).
                if let options = selectedField.allowedValues,
                   !options.contains(inputValue) {
                    inputValue = options.first ?? ""
                }
            }
            .alert(
                "Invalid entry",
                isPresented: Binding(
                    get: { validationMessage != nil },
                    set: { if !$0 { validationMessage = nil } }
                ),
                presenting: validationMessage
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
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
        // Pre-flight validation. The right input control already
        // makes the wrong shape hard to enter (number-pad for age,
        // Picker for closed-set fields) — this is the belt to the
        // suspenders for cases like pasting letters into the age
        // field or somehow ending up with a value outside the
        // picker's allowed set.
        let trimmed = inputValue.trimmingCharacters(in: .whitespacesAndNewlines)

        if selectedField.isNumeric {
            guard let n = Int(trimmed), (1...120).contains(n) else {
                validationMessage = "Age has to be a whole number between 1 and 120."
                return
            }
        }
        if let allowed = selectedField.allowedValues, !allowed.contains(trimmed) {
            validationMessage = "Pick one of the allowed options for \(selectedField.displayName)."
            return
        }
        if trimmed.isEmpty {
            validationMessage = "Type a value before saving."
            return
        }

        var profile = UserProfile.load()
        let changed = profile.add(trimmed, to: selectedField)
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
