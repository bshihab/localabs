import SwiftUI

/// Focused edit interface for the user's medical profile. Tapped
/// from Profile → "Edit Health Profile", this sheet shows every
/// field pre-filled with whatever the user already entered (either
/// at onboarding time or via the chat-bar quick-add) so they can
/// review and adjust in one place.
///
/// Replaces the previous behavior, where "Edit Health Profile" sent
/// the user back through the full 4-step onboarding flow — welcome
/// splash, terms toggle, and all. That made sense for a first-time
/// user but felt redundant for an edit. The actual welcome /
/// privacy / re-acceptance flow lives behind "Re-Run Onboarding"
/// for users who want it.
///
/// Auto-saves on every field change, mirroring how ProfileView's
/// inline cards already work. The Done button is purely a dismiss —
/// no separate Save action to remember to tap.
struct ProfileEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var profile: UserProfile

    init() {
        _profile = State(initialValue: UserProfile.load())
    }

    /// DatePicker needs a non-optional Date, so this bridges to the
    /// optional `dateOfBirth`: shows a sensible default (30 years ago)
    /// when unset, and writes the user's pick back. Touching the picker
    /// sets dateOfBirth, which then drives `ageYears`.
    private var dobBinding: Binding<Date> {
        Binding(
            get: { profile.dateOfBirth ?? Calendar.current.date(byAdding: .year, value: -30, to: Date()) ?? Date() },
            set: { profile.dateOfBirth = $0 }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker(
                        "Date of birth",
                        selection: dobBinding,
                        in: ...Date(),
                        displayedComponents: .date
                    )
                    if let age = profile.ageYears {
                        HStack {
                            Text("Age")
                            Spacer()
                            Text("\(age)").foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Date of Birth")
                }

                Section {
                    Picker("Biological Sex", selection: $profile.biologicalSex) {
                        Text("Not Set").tag("")
                        Text("Male").tag("Male")
                        Text("Female").tag("Female")
                        Text("Other").tag("Other")
                    }
                    if profile.biologicalSex == "Other" {
                        TextField("Describe", text: $profile.biologicalSexOther)
                    }
                } header: {
                    Text("Biological Sex")
                } footer: {
                    Text("Used together with age to pick demographic-appropriate reference bands for HRV, VO₂ max, walking speed, and other Health metrics.")
                }

                Section {
                    Picker("Blood Type", selection: $profile.bloodType) {
                        Text("Not Set").tag("")
                        ForEach(["O+", "O-", "A+", "A-", "B+", "B-", "AB+", "AB-"], id: \.self) { type in
                            Text(type).tag(type)
                        }
                    }
                } header: {
                    Text("Blood Type")
                }

                Section {
                    Picker("Tobacco / E-Cig", selection: $profile.smoking) {
                        Text("Not Set").tag("")
                        Text("Never").tag("Never")
                        Text("Former").tag("Former")
                        Text("Current").tag("Current")
                    }
                    Picker("Alcohol Use", selection: $profile.alcohol) {
                        Text("Not Set").tag("")
                        Text("None").tag("None")
                        Text("Rarely").tag("Rarely")
                        Text("Occasionally").tag("Occasionally")
                        Text("Daily").tag("Daily")
                    }
                } header: {
                    Text("Lifestyle")
                }

                Section {
                    TextField(
                        "e.g. Mom: breast cancer at 50, Dad: heart attack at 65",
                        text: $profile.familyHistory,
                        axis: .vertical
                    )
                    .lineLimit(2...6)
                } header: {
                    Text("Family History")
                } footer: {
                    Text("Free-form — list relatives, conditions, and ages of onset. Localabs reads this when interpreting your lab values.")
                }

                Section {
                    TextField(
                        "e.g. Chronic migraines, hypothyroidism, surgeries…",
                        text: $profile.medicalConditions,
                        axis: .vertical
                    )
                    .lineLimit(2...8)
                } header: {
                    Text("Medical Conditions")
                } footer: {
                    Text("Diagnoses, ongoing conditions, and significant past surgeries. New entries added from chats appear here too.")
                }

                Section {
                    TextField(
                        "e.g. Lisinopril 10mg morning, Metformin 500mg with meals…",
                        text: $profile.medications,
                        axis: .vertical
                    )
                    .lineLimit(2...8)
                } header: {
                    Text("Current Medications")
                } footer: {
                    Text("Drug name, dose, and timing. Localabs cross-references your medications when interpreting lab values that interact with them.")
                }

                Section {
                    Label {
                        Text("This profile stays on your device. Localabs reads it silently as context for every analysis and chat — none of it is sent to a server.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                    }
                }
            }
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            // Auto-save on any field change so closing the sheet
            // never loses unsaved edits. Matches how ProfileView's
            // inline cards work — there's no "Save" action to
            // remember to tap.
            .onChange(of: profile) { _, _ in
                profile.save()
            }
        }
    }
}
