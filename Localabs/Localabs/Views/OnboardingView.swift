import SwiftUI

struct OnboardingView: View {
    @AppStorage("onboarding_complete") var onboardingComplete = false
    @Environment(\.dismiss) var dismiss
    @State private var step = 0
    @State private var profile = UserProfile.load()
    @State private var agreed = false
    @State private var showLegal = false

    /// Bridges the optional `dateOfBirth` to the DatePicker. Defaults
    /// to 30 years ago for display; the set only fires when the user
    /// actually picks a date, so `dateOfBirth` stays nil (and Next
    /// stays disabled) until they choose one.
    private var onboardingDOBBinding: Binding<Date> {
        Binding(
            get: { profile.dateOfBirth ?? Calendar.current.date(byAdding: .year, value: -30, to: Date()) ?? Date() },
            set: { profile.dateOfBirth = $0 }
        )
    }

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

            Text("Welcome to\nLocalabs")
                .font(.system(size: 34, weight: .bold))
                .multilineTextAlignment(.center)
                .padding(.bottom, 48)

            featureRow(icon: "checkmark.shield.fill", color: .blue, title: "Total Privacy", subtitle: "Your medical data stays on your device. Zero information is sent to the cloud.")
            featureRow(icon: "bolt.fill", color: .orange, title: "On-Device Intelligence", subtitle: "Analyzes lab reports instantly using a local AI engine optimized for Apple Metal GPU.")
            featureRow(icon: "heart.fill", color: .red, title: "Health Integration", subtitle: "Cross-references your Apple Health vitals against your paper lab reports.")

            Spacer()

            Button {
                step = 1
            } label: {
                Text("Continue")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.glassProminent)
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }

    // MARK: - Step 1: Health Details
    private var healthDetailsStep: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    stepHeader(
                        step: 1,
                        title: "Health Details",
                        subtitle: "Localabs uses this to personalize the on-device AI for you — age and sex shift reference ranges for many lab values, so your translations stay accurate to your body."
                    )

                    // Age lives in its OWN glass card, isolated from
                    // the Sex + Blood Type pickers below. Earlier it
                    // shared one glass-effect VStack with the two
                    // pickers, and every keystroke in Age forced the
                    // entire 3-row glass to recompute its blur — that
                    // was the source of the typing lag. With Age in
                    // its own card, only this small surface re-renders
                    // on each character.
                    VStack(spacing: 0) {
                        labeledRow("Date of Birth") {
                            DatePicker(
                                "",
                                selection: onboardingDOBBinding,
                                in: ...Date(),
                                displayedComponents: .date
                            )
                            .labelsHidden()
                        }
                    }
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .padding(.horizontal)

                    VStack(spacing: 0) {
                        labeledRow("Biological Sex") {
                            Picker("", selection: $profile.biologicalSex) {
                                Text("Not Set").tag("")
                                Text("Male").tag("Male")
                                Text("Female").tag("Female")
                                Text("Other").tag("Other")
                            }
                            .labelsHidden()
                        }
                        if profile.biologicalSex == "Other" {
                            otherTextRow(placeholder: "Describe…", text: $profile.biologicalSexOther)
                        }
                        Divider().padding(.horizontal, 16)
                        labeledRow("Blood Type") {
                            Picker("", selection: $profile.bloodType) {
                                Text("Not Set").tag("")
                                ForEach(["A+", "A-", "B+", "B-", "AB+", "AB-", "O+", "O-"], id: \.self) { type in
                                    Text(type).tag(type)
                                }
                            }
                            .labelsHidden()
                        }
                    }
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .padding(.horizontal)
                }
                .padding(.top, 20)
            }

            navigationButtons(back: nil, next: { step = 2 }, nextDisabled: profile.dateOfBirth == nil || profile.biologicalSex.isEmpty)
        }
    }

    // MARK: - Step 2: Clinical Details
    private var clinicalDetailsStep: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    stepHeader(
                        step: 2,
                        title: "Clinical Details",
                        subtitle: "Family history, medications, and lifestyle factors directly affect how the AI should weight specific lab findings. Everything you share here is folded into every analysis — and stays on your phone."
                    )

                    VStack(spacing: 0) {
                        labeledRow("Tobacco / E-Cig") {
                            Picker("", selection: $profile.smoking) {
                                Text("Not Set").tag("")
                                Text("Never").tag("Never")
                                Text("Former").tag("Former")
                                Text("Current").tag("Current")
                            }
                            .labelsHidden()
                        }
                        Divider().padding(.horizontal, 16)
                        labeledRow("Alcohol Use") {
                            Picker("", selection: $profile.alcohol) {
                                Text("Not Set").tag("")
                                Text("None").tag("None")
                                Text("Rarely").tag("Rarely")
                                Text("Occasionally").tag("Occasionally")
                                Text("Daily").tag("Daily")
                            }
                            .labelsHidden()
                        }
                    }
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .padding(.horizontal)

                    // Family history is free-form rather than a picker because
                    // the meaningful detail (maternal vs paternal side, age of
                    // onset, specific conditions per relative) doesn't fit a
                    // dropdown. The text area matches Medical Conditions and
                    // Medications below.
                    glassTextArea(
                        label: "FAMILY HISTORY",
                        placeholder: "e.g. Mom: breast cancer at 50, Dad: heart attack at 65, Grandfather: type 2 diabetes",
                        text: $profile.familyHistory
                    )
                    .padding(.horizontal)

                    glassTextArea(label: "MEDICAL CONDITIONS",
                                  placeholder: "e.g. Chronic migraines, surgeries…",
                                  text: $profile.medicalConditions)
                        .padding(.horizontal)

                    glassTextArea(label: "CURRENT MEDICATIONS",
                                  placeholder: "e.g. Lisinopril 10mg, Metformin 500mg…",
                                  text: $profile.medications)
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

                    VStack(alignment: .leading, spacing: 12) {
                        Text("1. **100% On-Device:** Localabs runs entirely on your phone's processor. Your health data is NEVER sent to the cloud.")
                        Text("2. **Not a Doctor:** Localabs is an informational AI tool, not a medical device. It does not diagnose and is not a substitute for professional medical advice. It can be wrong — confirm anything important with your doctor.")
                        Text("3. **Emergencies:** Localabs is not for medical emergencies. In an emergency, call 911 or your doctor.")
                    }
                    .font(.subheadline)
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .padding(.horizontal)

                    Button {
                        showLegal = true
                    } label: {
                        Label("Read the full Medical Disclaimer & Terms", systemImage: "doc.text")
                            .font(.subheadline.weight(.medium))
                    }
                    .padding(.horizontal, 24)

                    Toggle("I have read and agree to the Medical Disclaimer & Terms.", isOn: $agreed)
                        .padding(.horizontal, 24)
                        .font(.subheadline.weight(.semibold))
                }
            }
            .sheet(isPresented: $showLegal) { LegalView() }

            Button {
                profile.onboardingComplete = true
                profile.save()
                // Record when the user accepted the disclaimer + terms.
                UserDefaults.standard.set(Date(), forKey: "localabs_terms_accepted_at")

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    onboardingComplete = true
                    dismiss()
                }
            } label: {
                Text("Complete Setup")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.glassProminent)
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
                    .fill(color.opacity(0.16))
                    .frame(width: 48, height: 48)
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(color)
                    .shadow(color: color.opacity(0.5), radius: 7)
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

    private func stepHeader(step: Int, title: String, subtitle: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("STEP \(step) OF 3")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(1.5)
            Text(title)
                .font(.system(size: 34, weight: .bold))
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
        }
        .padding(.horizontal)
    }

    private func labeledRow<Trailing: View>(_ label: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Text(label)
                .font(.body.weight(.medium))
            Spacer()
            trailing()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    /// Free-form text input that appears under a picker when the user
    /// picks "Other". Slightly indented so it visually attaches to the
    /// row above. Multi-line so users can type something descriptive
    /// rather than fitting on one line.
    private func otherTextRow(placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text, axis: .vertical)
            .lineLimit(1...4)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .padding(.horizontal, 18)
            .padding(.bottom, 14)
    }

    private func glassTextArea(label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.blue)
                .tracking(1.5)
            TextField(placeholder, text: text, axis: .vertical)
                .lineLimit(3...6)
                .padding(12)
                // Flat tonal fill rather than nested glass — the
                // outer card is already a glass surface, and Apple's
                // HIG calls out that stacking glass over glass
                // over-blurs and reads as a single muddy plane.
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.secondary.opacity(0.08))
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// Plain HStack instead of GlassEffectContainer — the container
    /// recomputed its morph layout every time the Continue button's
    /// `disabled` state flipped, which on Step 1 happened on every
    /// keystroke in the Age field (the disabled gate watches
    /// `profile.age.isEmpty`). That manifested as visible per-character
    /// typing lag. Each button keeps its individual .glass / .glassProminent
    /// style so the visual treatment is identical — just no shared
    /// morph container.
    private func navigationButtons(back: (() -> Void)?, next: @escaping () -> Void, nextDisabled: Bool = false) -> some View {
        HStack(spacing: 12) {
            if let back = back {
                Button {
                    back()
                } label: {
                    Text("Back")
                        .font(.system(size: 17, weight: .semibold))
                        .padding(.vertical, 12)
                        .frame(width: 100)
                }
                .buttonStyle(.glass)
            }
            Button {
                next()
            } label: {
                Text("Continue")
                    .font(.system(size: 17, weight: .semibold))
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .disabled(nextDisabled)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 40)
    }
}
