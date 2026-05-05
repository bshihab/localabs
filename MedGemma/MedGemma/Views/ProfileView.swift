import SwiftUI

struct ProfileView: View {
    @EnvironmentObject var engine: InferenceEngine
    @AppStorage("onboarding_complete") var onboardingComplete = false
    @State private var profile = UserProfile.load()
    @State private var showOnboarding = false
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // AI Engine Status Card
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("OFFLINE AI ENGINE")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.blue)
                                .tracking(1.5)
                            
                            Text("MedGemma requires a 2.5GB local weights file to analyze lab results entirely on-device.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineSpacing(2)
                            
                            if engine.isModelLoaded {
                                HStack {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                    Text("Model Loaded & Ready")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundColor(.green)
                                }
                                .padding(.vertical, 8)
                                .padding(.horizontal, 14)
                                .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                            } else if engine.loadingProgress > 0 && engine.loadingProgress < 100 {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text("Downloading Weights...")
                                            .font(.caption.weight(.semibold))
                                        Spacer()
                                        Text("\(Int(engine.loadingProgress))%")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                    ProgressView(value: engine.loadingProgress, total: 100)
                                        .tint(.blue)
                                }
                            } else {
                                Button {
                                    Task { await engine.initializeModel() }
                                } label: {
                                    Label("Download MedGemma 4B", systemImage: "arrow.down.circle.fill")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                            }
                        }
                    }
                    .padding(.horizontal)
                    
                    // Core Info Card
                    GroupBox {
                        VStack(spacing: 0) {
                            profileRow(label: "Age", value: profile.age.isEmpty ? "Not set" : profile.age)
                            Divider()
                            profileRow(label: "Biological Sex", value: profile.biologicalSex.isEmpty ? "Not set" : profile.biologicalSex)
                        }
                    }
                    .padding(.horizontal)
                    
                    // Known Conditions Card
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("KNOWN CONDITIONS")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.blue)
                                .tracking(1.5)
                            Text(profile.medicalConditions.isEmpty ? "None reported." : profile.medicalConditions)
                                .font(.body)
                        }
                    }
                    .padding(.horizontal)
                    
                    // Current Medications Card
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("CURRENT MEDICATIONS")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.blue)
                                .tracking(1.5)
                            Text("List your daily medications so MedGemma can cross-reference them against your lab results.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineSpacing(2)
                            
                            TextField("e.g. Lisinopril 10mg, Metformin 500mg...", text: $profile.medications, axis: .vertical)
                                .lineLimit(3...6)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: profile.medications) { _, _ in
                                    profile.save()
                                }
                        }
                    }
                    .padding(.horizontal)
                    
                    // Edit Profile & Reset
                    Button {
                        showOnboarding = true
                    } label: {
                        Label("Edit Health Profile", systemImage: "pencil")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .padding(.horizontal)
                    
                    Button(role: .destructive) {
                        UserProfile.reset()
                        LocalStorageService.shared.clearHistory()
                        onboardingComplete = false
                    } label: {
                        Label("Reset App & Erase Data", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .padding(.horizontal)
                    .padding(.bottom, 100)
                }
                .padding(.top, 8)
            }
            .navigationTitle("Medical Profile")
            .sheet(isPresented: $showOnboarding) {
                OnboardingView()
            }
        }
    }
    
    private func profileRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.body.weight(.medium))
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
    }
}
