import SwiftUI

/// The app's medical disclaimer + Terms of Use (#32). Shown as the
/// "read the full terms" link from onboarding's acceptance step and
/// always reachable from Profile. States the core protections:
/// informational-only, not a diagnosis, emergency carve-out, no warranty,
/// and the on-device privacy stance.
struct LegalView: View {
    @Environment(\.dismiss) private var dismiss
    /// When true, shows a Done button (presented as a sheet). False when
    /// pushed in a navigation stack.
    var showsDoneButton = true

    private let privacyURL = URL(string: "https://localabs.app/privacy")!
    private let termsURL = URL(string: "https://localabs.app/terms")!

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    emergencyCallout

                    section(
                        "Medical Disclaimer",
                        """
                        Localabs is an informational tool, not a medical device. It helps you read and understand your own lab reports and health data in plain language. It does not provide a medical diagnosis, and it is not a substitute for professional medical advice, diagnosis, or treatment.

                        Always seek the advice of your physician or another qualified health provider with any questions about a medical condition or your results. Never disregard professional medical advice, or delay seeking it, because of something you read in Localabs.

                        Localabs may be wrong. It runs a small AI model that can misread a scan or misstate a value. Confirm anything important with your doctor and your original report.
                        """
                    )

                    section(
                        "No Doctor–Patient Relationship",
                        "Using Localabs does not create a doctor–patient relationship between you and Localabs, its developers, or anyone affiliated with it. Localabs does not practice medicine and does not prescribe medications."
                    )

                    section(
                        "Your Privacy",
                        """
                        Localabs runs entirely on your device. Your scans, lab values, medications, symptoms, and health data are stored locally and are not sent to any server — the AI never sees the cloud.

                        You are responsible for the security of your device. Read our full Privacy Policy for details.
                        """
                    )

                    section(
                        "Reminders & Notifications",
                        "Medication reminders, recheck reminders, and visit check-ins are conveniences, not a guarantee. Do not rely on them for time- or dose-critical medications. Notification delivery is controlled by iOS and may be delayed or missed."
                    )

                    section(
                        "No Warranty",
                        "Localabs is provided \u{201C}as is,\u{201D} without warranties of any kind, express or implied, including fitness for a particular purpose. We do not warrant that the app or its output is accurate, complete, or error-free."
                    )

                    section(
                        "Limitation of Liability",
                        "To the maximum extent permitted by law, Localabs and its developers are not liable for any harm, loss, or damages arising from your use of, or reliance on, the app or its output. You use Localabs at your own risk."
                    )

                    links

                    Text("Last updated: June 2026")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                }
                .padding()
            }
            .scrollContentBackground(.hidden)
            .background(.background)
            .navigationTitle("Terms & Disclaimer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsDoneButton {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }.fontWeight(.semibold)
                    }
                }
            }
        }
    }

    // MARK: - Pieces

    private var emergencyCallout: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "cross.case.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Color.red, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text("In an emergency, call 911")
                    .font(.system(size: 16, weight: .bold))
                Text("Localabs is not for medical emergencies. If you think you may have a medical emergency, call your doctor or emergency services immediately.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.red.opacity(0.10))
        )
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 18, weight: .bold))
            Text(body)
                .font(.system(size: 15))
                .foregroundStyle(.primary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var links: some View {
        VStack(alignment: .leading, spacing: 10) {
            Link(destination: privacyURL) {
                Label("Read the full Privacy Policy", systemImage: "lock.shield")
                    .font(.system(size: 15, weight: .medium))
            }
            Link(destination: termsURL) {
                Label("Read the full Terms of Use", systemImage: "doc.text")
                    .font(.system(size: 15, weight: .medium))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }
}
