import SwiftUI
import UserNotifications

/// Settings for Trends threshold alerts. The user arms individual
/// Apple Health metrics; when an armed metric drifts outside its
/// age/sex-adjusted norm for several readings, Localabs fires a
/// local notification (enriched with past-report context).
///
/// Thresholds themselves aren't editable here — they come from the
/// same `HealthInsights` bands the Trends cards use, so the alert
/// and the on-card status pill stay in sync. The user controls
/// which metrics are watched and how sensitive each trip is.
struct HealthAlertsView: View {
    @State private var configs: [HealthAlertConfig] = HealthAlertConfig.loadAll()
    @State private var recentLog: [FiredAlert] = HealthAlertService.shared.recentLog()
    /// Tracks notification permission so we can warn the user if
    /// they've armed alerts but denied notifications (in which case
    /// nothing will actually fire).
    @State private var notificationsDenied = false

    var body: some View {
        Form {
            Section {
                Text("Localabs can watch your Apple Health metrics and notify you when one drifts outside the typical range for your age and sex — interpreted alongside your past reports. Everything is evaluated on-device.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if notificationsDenied && anyEnabled {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Notifications are off for Localabs, so alerts can't reach you. Enable them in Settings → Localabs → Notifications.")
                            .font(.footnote)
                    }
                }
            }

            Section("Metrics to watch") {
                ForEach($configs) { $config in
                    AlertMetricRow(config: $config) {
                        persist()
                    }
                }
            }

            if !recentLog.isEmpty {
                Section("Recent alerts") {
                    ForEach(recentLog) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.title)
                                .font(.subheadline.weight(.semibold))
                            Text(entry.body)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(entry.date, format: .dateTime.month().day().hour().minute())
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle("Health Alerts")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await refreshNotificationStatus()
            recentLog = HealthAlertService.shared.recentLog()
        }
    }

    private var anyEnabled: Bool { configs.contains { $0.enabled } }

    /// Persist the edited configs, then request notification
    /// permission if the user just armed something and we haven't
    /// asked yet.
    private func persist() {
        HealthAlertConfig.saveAll(configs)
        Task { @MainActor in
            await HealthAlertService.shared.requestAuthorizationIfNeeded()
            await refreshNotificationStatus()
        }
    }

    private func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationsDenied = settings.authorizationStatus == .denied
    }
}

/// One metric's row: a toggle, and — when armed — a sensitivity
/// picker that controls how far out of range a reading has to be
/// before it counts toward tripping the alert.
private struct AlertMetricRow: View {
    @Binding var config: HealthAlertConfig
    let onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $config.enabled) {
                Label {
                    Text(config.metric.displayName)
                } icon: {
                    Image(systemName: config.metric.systemImage)
                        .foregroundStyle(.blue)
                }
            }
            .onChange(of: config.enabled) { _, _ in onChange() }

            if config.enabled {
                Picker("Sensitivity", selection: $config.sensitivity) {
                    ForEach(HealthAlertConfig.Sensitivity.allCases, id: \.self) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: config.sensitivity) { _, _ in onChange() }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: config.enabled)
    }
}
