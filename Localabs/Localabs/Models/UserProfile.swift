import Foundation

struct UserProfile: Codable, Equatable {
    /// Legacy free-text age. Kept as a fallback for profiles created
    /// before date-of-birth existed; `dateOfBirth` is now the primary
    /// source so the age stays current without yearly edits.
    var age: String = ""
    /// Date of birth — the canonical source of age. Optional so older
    /// profiles (and users who skip it) decode/work via the `age`
    /// fallback. `ageYears` derives the current age from this.
    var dateOfBirth: Date?
    var biologicalSex: String = ""
    /// Free-form text when `biologicalSex == "Other"` — captures the
    /// user's own description instead of just storing the literal word.
    /// Empty otherwise.
    var biologicalSexOther: String = ""
    var bloodType: String = ""
    var smoking: String = ""
    var alcohol: String = ""
    /// Free-form text — captures relatives, conditions, ages of onset.
    /// e.g. "Mom: breast cancer at 50, Dad: heart attack at 65". A
    /// picker is too restrictive for the meaningful detail here
    /// (maternal vs paternal side, multiple conditions per relative).
    var familyHistory: String = ""
    var medicalConditions: String = ""
    var medications: String = ""
    var onboardingComplete: Bool = false

    private static let storageKey = "localabs_user_profile"

    static func load() -> UserProfile {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let profile = try? JSONDecoder().decode(UserProfile.self, from: data)
        else {
            return UserProfile()
        }
        return profile
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    /// Whether the user has supplied enough demographics for the
    /// Trends tab to attach Typical / Borderline / Outside-typical
    /// labels to their metrics. Both age and biological sex are
    /// required: population norms for resting HR, HRV, sleep, walking
    /// speed, etc. shift meaningfully with both, so colouring a status
    /// without them would be at best generic and at worst misleading
    /// (e.g. "60–80 bpm typical" is for adults in general; an athlete
    /// in their 20s vs. a 70-year-old read those numbers differently).
    /// Users who skip these fields see no status pills at all.
    var hasDemographicsForStatusLabels: Bool {
        ageYears != nil
            && !biologicalSex.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The user's current age in years — derived from `dateOfBirth`
    /// when set (so it stays correct as time passes), otherwise parsed
    /// from the legacy `age` text. nil when neither is available.
    var ageYears: Int? {
        if let dob = dateOfBirth {
            let years = Calendar.current.dateComponents([.year], from: dob, to: Date()).year
            if let y = years, (0...130).contains(y) { return y }
        }
        let trimmed = age.trimmingCharacters(in: .whitespaces)
        if let n = Int(trimmed), (0...130).contains(n) { return n }
        return nil
    }

    /// Age as a display string ("52"), or "" when unknown.
    var ageDisplay: String { ageYears.map(String.init) ?? "" }

    /// One of the user-mutable fields on `UserProfile`. Lives here
    /// (instead of in the now-removed `ProfileSuggestion` module)
    /// because the only consumer is the manual quick-add sheet
    /// surfaced from the chat input bars — there's no more model-
    /// driven or regex-driven suggestion pipeline to feed it.
    enum Field: String, CaseIterable, Identifiable {
        case medicalConditions
        case medications
        case familyHistory
        case smoking
        case alcohol
        case bloodType
        case age
        case biologicalSex

        var id: String { rawValue }

        /// User-facing name for picker rows + button labels.
        var displayName: String {
            switch self {
            case .medicalConditions: return "Medical Conditions"
            case .medications:       return "Medications"
            case .familyHistory:     return "Family History"
            case .smoking:           return "Smoking / Vaping"
            case .alcohol:           return "Alcohol"
            case .bloodType:         return "Blood Type"
            case .age:               return "Age"
            case .biologicalSex:     return "Biological Sex"
            }
        }

        /// Short prompt used inside the TextField when the value is
        /// empty — gives the user a worked example so they know the
        /// shape of input we're expecting.
        var placeholder: String {
            switch self {
            case .medicalConditions: return "e.g. Type 2 diabetes"
            case .medications:       return "e.g. Metformin 500mg, morning"
            case .familyHistory:     return "e.g. Mom: breast cancer at 50"
            case .smoking:           return "e.g. Former smoker, quit 2020"
            case .alcohol:           return "e.g. 2–3 drinks per week"
            case .bloodType:         return "e.g. O+, A-, AB-"
            case .age:               return "e.g. 34"
            case .biologicalSex:     return "Male / Female / Other"
            }
        }

        /// Multi-line fields (conditions, medications, family
        /// history) append a new line each time the user adds an
        /// entry — that's how their UI fields are already structured.
        /// Single-value fields (age, sex, blood type, etc.) overwrite
        /// whatever was there.
        var isMultiLine: Bool {
            switch self {
            case .medications, .medicalConditions, .familyHistory: return true
            case .smoking, .alcohol, .bloodType, .age, .biologicalSex: return false
            }
        }

        /// Closed set of valid values for picker-style fields. Used
        /// by ProfileQuickAddSheet to render a Picker (instead of a
        /// free-text TextField) so the user can't type "blue" for
        /// blood type or "male-ish" for biological sex. Returns nil
        /// for free-text + numeric fields, where the sheet falls
        /// back to a TextField with appropriate keyboard type.
        var allowedValues: [String]? {
            switch self {
            case .biologicalSex:  return ["Male", "Female", "Other"]
            case .smoking:        return ["Never", "Former", "Current"]
            case .alcohol:        return ["None", "Rarely", "Occasionally", "Daily"]
            case .bloodType:      return ["O+", "O-", "A+", "A-", "B+", "B-", "AB+", "AB-"]
            default:              return nil
            }
        }

        /// True for fields that must be a number (currently only
        /// `age`). The quick-add sheet uses this to switch on a
        /// numeric keypad and to gate Save on an integer-in-range
        /// validation.
        var isNumeric: Bool {
            self == .age
        }
    }

    /// Returns the current stored value for a given field. Used by
    /// the quick-add sheet to show "Already saved" hints for single-
    /// value fields the user has already filled in.
    func value(for field: Field) -> String {
        switch field {
        case .medicalConditions: return medicalConditions
        case .medications:       return medications
        case .familyHistory:     return familyHistory
        case .smoking:           return smoking
        case .alcohol:           return alcohol
        case .bloodType:         return bloodType
        case .age:               return age
        case .biologicalSex:     return biologicalSex
        }
    }

    /// Writes a user-supplied value to a profile field. Multi-line
    /// fields append-unique so duplicate entries don't accumulate;
    /// single-value fields overwrite (the user manually picked the
    /// field, they know they're replacing). Returns true when the
    /// profile actually changed so the caller can show a brief
    /// confirmation.
    mutating func add(_ value: String, to field: Field) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        switch field {
        case .medications:       return appendUnique(value: trimmed, to: \.medications)
        case .medicalConditions: return appendUnique(value: trimmed, to: \.medicalConditions)
        case .familyHistory:     return appendUnique(value: trimmed, to: \.familyHistory)
        case .smoking:           return setOverwriting(value: trimmed, on: \.smoking)
        case .alcohol:           return setOverwriting(value: trimmed, on: \.alcohol)
        case .bloodType:         return setOverwriting(value: trimmed, on: \.bloodType)
        case .age:               return setOverwriting(value: trimmed, on: \.age)
        case .biologicalSex:     return setOverwriting(value: trimmed, on: \.biologicalSex)
        }
    }

    /// Append `value` as a new line to a multi-line field, skipping
    /// the write if the field already contains that value (case-
    /// insensitive). Prevents duplicate entries like "Diabetes" /
    /// "diabetes" from piling up.
    private mutating func appendUnique(value: String, to keyPath: WritableKeyPath<UserProfile, String>) -> Bool {
        let current = self[keyPath: keyPath]
        let needle = value.lowercased()
        let existing = current.split(separator: "\n").map { $0.lowercased() }
        if existing.contains(needle) { return false }
        self[keyPath: keyPath] = current.isEmpty ? value : "\(current)\n\(value)"
        return true
    }

    /// Overwrite a single-value field. The user manually picked the
    /// field name in the quick-add sheet — they know they're
    /// replacing the prior value. Returns true unless the new value
    /// equals what was already there.
    private mutating func setOverwriting(value: String, on keyPath: WritableKeyPath<UserProfile, String>) -> Bool {
        let current = self[keyPath: keyPath].trimmingCharacters(in: .whitespacesAndNewlines)
        if current == value { return false }
        self[keyPath: keyPath] = value
        return true
    }

    /// Formatted bullet list of every onboarding field that's been
    /// filled in. Inserted into both the lab-analysis prompt and the
    /// follow-up chat prompt so the model has the user's age, sex,
    /// blood type, family history, etc. as context — reference
    /// ranges for many lab values shift with these variables and the
    /// AI should weight findings accordingly. Empty fields are
    /// skipped rather than rendered as "None" so the prompt stays
    /// tight on users who only filled in a subset.
    var promptContextBullets: String {
        var lines: [String] = []
        if let a = ageYears { lines.append("- Age: \(a)") }
        if !biologicalSex.isEmpty {
            let sex = biologicalSex == "Other" && !biologicalSexOther.isEmpty
                ? "Other (\(biologicalSexOther))"
                : biologicalSex
            lines.append("- Biological Sex: \(sex)")
        }
        if !bloodType.isEmpty { lines.append("- Blood Type: \(bloodType)") }
        if !smoking.isEmpty { lines.append("- Tobacco / E-cig: \(smoking)") }
        if !alcohol.isEmpty { lines.append("- Alcohol: \(alcohol)") }
        if !familyHistory.isEmpty { lines.append("- Family History: \(familyHistory)") }
        if !medicalConditions.isEmpty { lines.append("- Known Medical Conditions: \(medicalConditions)") }
        if !medications.isEmpty { lines.append("- Current Daily Medications: \(medications)") }
        return lines.isEmpty ? "- No profile context provided." : lines.joined(separator: "\n        ")
    }
}
