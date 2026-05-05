import SwiftUI

struct OnboardingView: View {
    @AppStorage("onboarding_complete") var onboardingComplete = false
    @Environment(\.dismiss) var dismiss
    @State private var step = 0
    @State private var profile = UserProfile.load()
    @State private var agreed = false
    
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            
            switch step {
            case 0: welcomeStep
            case 1: healthDetailsStep
            case 2: clinicalDetailsStep
            case 3: privacyStep
            default: EmptyView()
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: step)
    }
    
    // MARK: - Step 0: Welcome
    private var welcomeStep: some View {
        VStack(spacing: 0) {
            Spacer()
            
            Text("Welcome to\nMedGemma")
                .font(.system(size: 34, weight: .bold))
                .multilineTextAlignment(.center)
                .padding(.bottom, 48)
            
            featureRow(icon: "shield.checkmark.fill", color: .blue, title: "Total Privacy", subtitle: "Your medical data stays on your device. Zero information is sent to the cloud.")
            featureRow(icon: "bolt.fill", color: .orange, title: "On-Device Intelligence", subtitle: "Analyzes lab reports instantly using a local AI engine optimized for Apple Metal GPU.")
            featureRow(icon: "heart.fill", color: .red, title: "Health Integration", subtitle: "Cross-references your Apple Health vitals against your paper lab reports.")
            
            Spacer()
            
            Button("Continue") { step = 1 }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
        }
    }
    
    // MARK: - Step 1: Health Details
    private var healthDetailsStep: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    stepHeader(step: 1, title: "Health Details")
                    
                    GroupBox {
                        LabeledContent("Age") {
                            TextField("25", text: $profile.age)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                        }
                        Divider()
                        LabeledContent("Biological Sex") {
                            Picker("", selection: $profile.biologicalSex) {
                                Text("Not Set").tag("")
                                Text("Male").tag("Male")
                                Text("Female").tag("Female")
                                Text("Other").tag("Other")
                            }
                            .labelsHidden()
                        }
                        Divider()
                        LabeledContent("Blood Type") {
                            Picker("", selection: $profile.bloodType) {
                                Text("Not Set").tag("")
                                ForEach(["A+", "A-", "B+", "B-", "AB+", "AB-", "O+", "O-"], id: \.self) { type in
                                    Text(type).tag(type)
                                }
                            }
                            .labelsHidden()
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.top, 20)
            }
            
            navigationButtons(back: nil, next: { step = 2 }, nextDisabled: profile.age.isEmpty || profile.biologicalSex.isEmpty)
        }
    }
    
    // MARK: - Step 2: Clinical Details
    private var clinicalDetailsStep: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    stepHeader(step: 2, title: "Clinical Details")
                    
                    GroupBox {
                        LabeledContent("Tobacco / E-Cig") {
                            Picker("", selection: $profile.smoking) {
                                Text("Not Set").tag("")
                                Text("Never").tag("Never")
                                Text("Former").tag("Former")
                                Text("Current").tag("Current")
                            }
                            .labelsHidden()
                        }
                        Divider()
                        LabeledContent("Alcohol Use") {
                            Picker("", selection: $profile.alcohol) {
                                Text("Not Set").tag("")
                                Text("None").tag("None")
                                Text("Rarely").tag("Rarely")
                                Text("Occasionally").tag("Occasionally")
                                Text("Daily").tag("Daily")
                            }
                            .labelsHidden()
                        }
                        Divider()
                        LabeledContent("Family History") {
                            Picker("", selection: $profile.familyHistory) {
                                Text("Not Set").tag("")
                                Text("None Known").tag("None Known")
                                Text("Heart Disease").tag("Heart Disease")
                                Text("Diabetes").tag("Diabetes")
                                Text("Cancer").tag("Cancer")
                                Text("Other").tag("Other")
                            }
                            .labelsHidden()
                        }
                    }
                    .padding(.horizontal)
                    
                    GroupBox("Medical Conditions") {
                        TextField("e.g. Chronic migraines, surgeries...", text: $profile.medicalConditions, axis: .vertical)
                            .lineLimit(3...6)
                    }
                    .padding(.horizontal)
                    
                    GroupBox("Current Medications") {
                        TextField("e.g. Lisinopril 10mg, Metformin 500mg...", text: $profile.medications, axis: .vertical)
                            .lineLimit(3...6)
                    }
                    .padding(.horizontal)
                }
                .padding(.top, 20)
            }
            
            navigationButtons(back: { step = 1 }, next: { step = 3 })
        }
    }
    
    // MARK: - Step 3: Privacy & Safety
    private var privacyStep: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.red)
                        .padding(.top, 40)
                        .padding(.horizontal)
                    
                    Text("Privacy & Safety")
                        .font(.system(size: 34, weight: .bold))
                        .padding(.horizontal)
                    
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("1. **100% On-Device:** MedGemma runs entirely on your phone's processor. Your health data is NEVER sent to the cloud.")
                            Text("2. **Not a Doctor:** MedGemma is an experimental AI. It is not a substitute for professional medical advice, diagnosis, or treatment.")
                        }
                        .font(.subheadline)
                    }
                    .padding(.horizontal)
                    
                    Toggle("I understand and agree to the terms above.", isOn: $agreed)
                        .padding(.horizontal, 24)
                        .font(.subheadline.weight(.semibold))
                }
            }
            
            Button("Complete Setup") {
                profile.onboardingComplete = true
                profile.save()
                
                // Small delay to ensure UserDefaults writes complete before UI transitions
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    onboardingComplete = true
                    dismiss()
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!agreed)
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }
    
    // MARK: - Helpers
    
    private func featureRow(icon: String, color: Color, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.12))
                    .frame(width: 48, height: 48)
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundColor(color)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 17, weight: .semibold))
                Text(subtitle).font(.system(size: 15)).foregroundStyle(.secondary).lineSpacing(2)
            }
            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 20)
    }
    
    private func stepHeader(step: Int, title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("STEP \(step) OF 3")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(1.5)
            Text(title)
                .font(.system(size: 34, weight: .bold))
        }
        .padding(.horizontal)
    }
    
    private func navigationButtons(back: (() -> Void)?, next: @escaping () -> Void, nextDisabled: Bool = false) -> some View {
        HStack(spacing: 12) {
            if let back = back {
                Button("Back") { back() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(width: 100)
            }
            Button("Continue") { next() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(nextDisabled)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 40)
    }
}
