import Foundation

struct UserProfile: Codable {
    var age: String = ""
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
}
