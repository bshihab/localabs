import SwiftUI

struct ProfileView: View {
    @EnvironmentObject var engine: InferenceEngine
    @AppStorage("onboarding_complete") var onboardingComplete = false
    @State private var profile = UserProfile.load()
    @State private var showOnboarding = false
    @State private var confirmDelete = false
    @State private var confirmReset = false
    @State private var hasRequestedHealth = HealthKitService.shared.hasRequestedAuthorization
    @State private var healthMetrics: HealthKitService.HealthMetrics?
    @State private var isRequestingHealth = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    aiEngineCard
                        .padding(.horizontal)

                    appleHealthCard
                        .padding(.horizontal)

                    coreInfoCard
                        .padding(.horizontal)

                    knownConditionsCard
                        .padding(.horizontal)

                    medicationsCard
                        .padding(.horizontal)

                    actionButtons
                        .padding(.horizontal)
                        .padding(.bottom, 100)
                }
                .padding(.top, 12)
            }
            .scrollContentBackground(.hidden)
            .background(.background)
            .navigationTitle("Medical Profile")
            .sheet(isPresented: $showOnboarding) {
                OnboardingView()
            }
            .alert("Delete Model File?", isPresented: $confirmDelete) {
                Button("Delete", role: .destructive) { engine.deleteSelectedModel() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\(engine.selectedModel.displayName) (\(engine.selectedModel.humanSize)) will be removed from this device. You can re-download it any time.")
            }
            .alert("Reset App?", isPresented: $confirmReset) {
                Button("Erase Everything", role: .destructive) {
                    UserProfile.reset()
                    LocalStorageService.shared.clearHistory()
                    onboardingComplete = false
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes your profile, all scanned reports, and history. The downloaded model file is kept.")
            }
        }
    }

    // MARK: - Cards

    private var aiEngineCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ON-DEVICE AI ENGINE")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.blue)
                .tracking(1.5)

            Text("Localabs runs entirely on your phone. Choose a model and download it once — no cloud, no account.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineSpacing(2)

            modelPicker

            engineStatus
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(AvailableModel.allCases) { model in
                ModelPickerRow(
                    model: model,
                    isSelected: engine.selectedModel == model,
                    isDisabled: engine.isDownloading
                ) {
                    engine.selectModel(model)
                }
            }
        }
    }

    @ViewBuilder
    private var engineStatus: some View {
        if engine.isModelLoaded {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text("\(engine.selectedModel.displayName) loaded & ready")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
                Spacer()
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.glass)
            }
            .padding(12)
            .glassEffect(.regular.tint(.green.opacity(0.12)), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else if engine.isDownloading {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Downloading…")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(Int(engine.loadingProgress * 100))%")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: engine.loadingProgress)
                    .tint(.blue)
                if engine.bytesExpected > 0 {
                    Text("\(formatBytes(engine.bytesWritten)) of \(formatBytes(engine.bytesExpected))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                        .font(.caption)
                    Text("Keep Localabs open for fastest download (~5–10 min on Wi-Fi). Backgrounding the app slows it down a lot — iOS throttles transfers from inactive apps.")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                Button("Cancel", role: .destructive) {
                    engine.cancelDownload()
                }
                .buttonStyle(.glass)
                .controlSize(.regular)
            }
            .padding(14)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            VStack(spacing: 10) {
                Button {
                    engine.downloadSelectedModel()
                } label: {
                    Label("Download \(engine.selectedModel.displayName)", systemImage: "arrow.down.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.glassProminent)

                if let err = engine.downloadError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    /// Shows the user's biological-sex value, preferring the free-form
    /// `biologicalSexOther` when they picked "Other" so the row doesn't
    /// just read "Other" with no context.
    private var biologicalSexDisplay: String {
        if profile.biologicalSex == "Other", !profile.biologicalSexOther.isEmpty {
            return profile.biologicalSexOther
        }
        return profile.biologicalSex.isEmpty ? "Not set" : profile.biologicalSex
    }

    private var coreInfoCard: some View {
        VStack(spacing: 0) {
            profileRow(label: "Age", value: profile.age.isEmpty ? "Not set" : profile.age)
            Divider().padding(.horizontal, 16)
            profileRow(label: "Biological Sex", value: biologicalSexDisplay)
            Divider().padding(.horizontal, 16)
            profileRow(label: "Blood Type", value: profile.bloodType.isEmpty ? "Not set" : profile.bloodType)
        }
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    // MARK: - Apple Health card

    /// Three states:
    ///   1. Not yet requested → "Connect Apple Health" button
    ///   2. Requested + has data → green check + last-fetched values
    ///   3. Requested + no data → "Connected — no recent data found"
    ///      With an "Open Settings" button: iOS won't re-show the
    ///      permission sheet after a user declines, so the only path
    ///      to grant access later is the Settings app deep-link.
    /// We can't reliably tell if the user *granted* read access (iOS hides
    /// that for privacy), so we infer from query results.
    private var appleHealthCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "heart.text.square.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.pink)
                Text("Apple Health")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                if isRequestingHealth {
                    ProgressView().scaleEffect(0.8)
                } else if hasRequestedHealth, let metrics = healthMetrics, !metrics.isEmpty {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.green)
                }
            }

            if !hasRequestedHealth {
                Text("Lets Localabs factor your resting heart rate, sleep, and HRV into every report.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    Task { await connectAppleHealth() }
                } label: {
                    Label("Connect Apple Health", systemImage: "heart.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.glassProminent)
                .disabled(isRequestingHealth)
            } else if let metrics = healthMetrics, !metrics.isEmpty {
                healthMetricsGrid(metrics)
                // Re-link to Settings even when data IS flowing, so the
                // user can adjust which categories Localabs reads. Small
                // tertiary link rather than a prominent button.
                Button {
                    openHealthApp()
                } label: {
                    Label("Adjust permissions in Health app", systemImage: "heart.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            } else if let metrics = healthMetrics, metrics.isEmpty {
                // No data flowing despite the request having been made.
                // Two common causes: user tapped Don't Allow on the iOS
                // sheet, or Localabs is reading types they haven't
                // enabled yet. Either way, the fix is in the Health app —
                // iOS doesn't let apps re-trigger the permission sheet,
                // but users can manage permissions manually under
                // Health → Profile → Privacy → Apps and Services →
                // Localabs.
                Text("No recent Apple Health data found.")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)

                Text("If you tapped Don't Allow, or want to enable more data types, you can manage permissions in the Health app:")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 5) {
                    settingsStep(number: 1, text: "Open the **Health** app")
                    settingsStep(number: 2, text: "Tap your **profile picture** (top-right)")
                    settingsStep(number: 3, text: "Scroll to **Privacy** and tap **Apps and Services**")
                    settingsStep(number: 4, text: "Tap **Localabs** and turn on the toggles")
                }
                .padding(.leading, 2)

                Button {
                    openHealthApp()
                } label: {
                    Label("Open Health App", systemImage: "heart.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.glassProminent)
                .padding(.top, 2)
            } else {
                ProgressView("Reading from Apple Health…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .task(id: hasRequestedHealth) {
            // Refresh whenever auth state flips. First load on appear if
            // already authorized in a previous session.
            if hasRequestedHealth {
                healthMetrics = await HealthKitService.shared.getHealthMetrics()
            }
        }
    }

    private func healthMetricsGrid(_ m: HealthKitService.HealthMetrics) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
            GridRow {
                metricCell(label: "Resting HR", value: m.avgRestingHR.map { "\(Int($0)) bpm" } ?? "—")
                metricCell(label: "Sleep", value: m.avgSleepHours.map { String(format: "%.1f hrs", $0) } ?? "—")
            }
            GridRow {
                metricCell(label: "HRV", value: m.avgHRV.map { "\(Int($0)) ms" } ?? "—")
                metricCell(label: "Window", value: "30 days")
            }
        }
    }

    private func metricCell(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.8)
            Text(value)
                .font(.system(size: 16, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func connectAppleHealth() async {
        isRequestingHealth = true
        defer { isRequestingHealth = false }
        _ = await HealthKitService.shared.requestAuthorization()
        hasRequestedHealth = HealthKitService.shared.hasRequestedAuthorization
        healthMetrics = await HealthKitService.shared.getHealthMetrics()
    }

    /// Opens the iOS Health app. iOS gates HealthKit permission to a
    /// one-time prompt, so a user who declined has to re-grant access
    /// from inside the Health app itself (Profile → Privacy → Apps →
    /// Localabs). The Settings-app deep-link only lands on Localabs's
    /// own privacy page, which doesn't expose the HealthKit toggles —
    /// users kept getting stuck there. `x-apple-health://` is the
    /// public Health-app URL scheme; `open()` doesn't require
    /// LSApplicationQueriesSchemes (only `canOpenURL` does), so we
    /// skip the canOpenURL probe and let iOS no-op silently on the
    /// rare device that lacks Health.
    private func openHealthApp() {
        if let url = URL(string: "x-apple-health://") {
            UIApplication.shared.open(url)
        }
    }

    /// One row in the "open Settings and do this" walkthrough. Renders
    /// the number in a small filled circle, then the description with
    /// `**markdown bold**` for the parts the user should look for.
    private func settingsStep(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.pink))
            Text(LocalizedStringKey(text))
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var knownConditionsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("KNOWN CONDITIONS")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.blue)
                .tracking(1.5)
            Text(profile.medicalConditions.isEmpty ? "None reported." : profile.medicalConditions)
                .font(.body)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var medicationsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CURRENT MEDICATIONS")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.blue)
                .tracking(1.5)
            Text("List your daily medications so Localabs can cross-reference them against your lab results.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineSpacing(2)

            TextField("e.g. Lisinopril 10mg, Metformin 500mg…", text: $profile.medications, axis: .vertical)
                .lineLimit(3...6)
                .padding(12)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .onChange(of: profile.medications) { _, _ in
                    profile.save()
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button {
                showOnboarding = true
            } label: {
                Label("Edit Health Profile", systemImage: "pencil")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.glass)

            Button(role: .destructive) {
                confirmReset = true
            } label: {
                Label("Reset App & Erase Data", systemImage: "trash")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.glass)
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
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        // Whole MB only (decimal megabytes, matching ByteCountFormatter's .file
        // convention). Avoids the jittery fractional digits that ByteCountFormatter
        // produces when it auto-switches units.
        "\(bytes / 1_000_000) MB"
    }
}

// MARK: - Model picker row

private struct ModelPickerRow: View {
    let model: AvailableModel
    let isSelected: Bool
    let isDisabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(isSelected ? Color.blue : Color.secondary)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    headerRow
                    Text(model.subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(rowGlass, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            Text(model.displayName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
            Text(model.humanSize)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            if model.isDownloaded {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 14))
            }
        }
    }

    private var rowGlass: Glass {
        isSelected ? .regular.tint(.blue.opacity(0.18)) : .regular
    }
}
