import Foundation

struct UserProfile: Codable {
    var age: String = ""
    var biologicalSex: String = ""
    var bloodType: String = ""
    var smoking: String = ""
    var alcohol: String = ""
    var familyHistory: String = ""
    var medicalConditions: String = ""
    var medications: String = ""
    var onboardingComplete: Bool = false

    private static let storageKey = "medgemma_user_profile"

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
