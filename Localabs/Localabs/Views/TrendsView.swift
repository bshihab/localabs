import SwiftUI
import Charts

/// Health trends home — the tab that replaces the old empty Dashboard.
/// Pulls a `TrendsSnapshot` from HealthKitService on appear and again
/// whenever the user changes the time range, then renders one card per
/// grouped section. Cards whose backing metrics are all nil hide
/// entirely; this is what makes the screen behave gracefully for
/// phone-only users (no HRV / VO2max / Watch-only metrics).
struct TrendsView: View {
    @EnvironmentObject var engine: InferenceEngine
    @State private var snapshot: HealthKitService.TrendsSnapshot?
    @State private var rangeDays: Int = 30
    @State private var isLoading = false
    @State private var hasRequestedHealth = HealthKitService.shared.hasRequestedAuthorization

    private let ranges: [(label: String, days: Int)] = [
        ("7d", 7),
        ("30d", 30),
        ("90d", 90)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Health Trends")
                        .font(.system(size: 34, weight: .bold))
                        .padding(.horizontal)
                        .padding(.top, 8)

                    if !hasRequestedHealth {
                        notConnectedCard
                            .padding(.horizontal)
                    } else {
                        rangePicker
                            .padding(.horizontal)

                        if let snapshot {
                            renderedCards(for: snapshot)
                        } else if isLoading {
                            ProgressView("Loading from Apple Health…")
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        } else {
                            emptyDataHint
                                .padding(.horizontal)
                        }
                    }
                }
                .padding(.bottom, 100)
            }
            .scrollContentBackground(.hidden)
            .background(.background)
            .navigationTitle("")
            .task(id: rangeDays) {
                await refresh()
            }
        }
    }

    // MARK: - Range picker

    private var rangePicker: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(ranges, id: \.days) { range in
                    rangeButton(range)
                }
            }
        }
    }

    /// Conditional .buttonStyle application: SwiftUI's modifier API
    /// can't pick between `.glass` and `.glassProminent` inline (the
    /// generic gets fixed at compile time), so we branch the whole
    /// button at the view level instead. The label is identical
    /// either way.
    @ViewBuilder
    private func rangeButton(_ range: (label: String, days: Int)) -> some View {
        if rangeDays == range.days {
            Button {
                rangeDays = range.days
            } label: { rangeButtonLabel(range.label) }
                .buttonStyle(.glassProminent)
        } else {
            Button {
                rangeDays = range.days
            } label: { rangeButtonLabel(range.label) }
                .buttonStyle(.glass)
        }
    }

    private func rangeButtonLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
    }

    // MARK: - Cards

    @ViewBuilder
    private func renderedCards(for snapshot: HealthKitService.TrendsSnapshot) -> some View {
        let activity: [(String, HealthKitService.MetricSeries?)] = [
            ("Steps", snapshot.steps),
            ("Walking + running", snapshot.walkingRunningDistance),
            ("Flights climbed", snapshot.flightsClimbed),
            ("Exercise minutes", snapshot.exerciseMinutes),
            ("Active energy", snapshot.activeEnergy)
        ]
        let mobility: [(String, HealthKitService.MetricSeries?)] = [
            ("Walking speed", snapshot.walkingSpeed),
            ("Step length", snapshot.walkingStepLength),
            ("Asymmetry", snapshot.walkingAsymmetry),
            ("Double support", snapshot.walkingDoubleSupport),
            ("Six-min walk", snapshot.sixMinuteWalkDistance)
        ]
        let cardio: [(String, HealthKitService.MetricSeries?)] = [
            ("Resting HR", snapshot.restingHR),
            ("HRV", snapshot.hrv),
            ("VO₂ max", snapshot.vo2Max),
            ("Walking HR", snapshot.walkingHR)
        ]
        let sleep: [(String, HealthKitService.MetricSeries?)] = [
            ("Sleep", snapshot.sleepHours)
        ]
        let vitals: [(String, HealthKitService.MetricSeries?)] = [
            ("Systolic BP", snapshot.systolicBP),
            ("Diastolic BP", snapshot.diastolicBP),
            ("Oxygen", snapshot.oxygenSaturation),
            ("Respiratory", snapshot.respiratoryRate),
            ("Body temp", snapshot.bodyTemperature)
        ]
        let body: [(String, HealthKitService.MetricSeries?)] = [
            ("Weight", snapshot.bodyMass),
            ("BMI", snapshot.bodyMassIndex)
        ]
        let logged: [(String, HealthKitService.MetricSeries?)] = [
            ("Blood glucose", snapshot.bloodGlucose),
            ("Caffeine", snapshot.caffeine)
        ]

        VStack(alignment: .leading, spacing: 18) {
            section(title: "ACTIVITY", icon: "figure.walk", tint: .blue, metrics: activity)
            section(title: "MOBILITY", icon: "figure.walk.motion", tint: .indigo, metrics: mobility)
            section(title: "CARDIO & RECOVERY", icon: "heart.fill", tint: .red, metrics: cardio)
            section(title: "SLEEP", icon: "moon.stars.fill", tint: .purple, metrics: sleep)
            section(title: "VITALS", icon: "waveform.path.ecg", tint: .pink, metrics: vitals)
            section(title: "BODY", icon: "person.crop.rectangle", tint: .orange, metrics: body)
            section(title: "LOGGED", icon: "pencil.line", tint: .green, metrics: logged)
        }
        .padding(.horizontal)
    }

    /// One section ("ACTIVITY", "MOBILITY", ...). Hides itself when
    /// none of its metrics have data — keeps the screen tight for
    /// users who only have a subset (phone-only, Watch-only, partial
    /// permissions).
    @ViewBuilder
    private func section(
        title: String,
        icon: String,
        tint: Color,
        metrics: [(String, HealthKitService.MetricSeries?)]
    ) -> some View {
        let available = metrics.compactMap { entry -> (String, HealthKitService.MetricSeries)? in
            guard let s = entry.1, s.hasData else { return nil }
            return (entry.0, s)
        }
        if !available.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .tracking(1.5)
                }
                .padding(.horizontal, 4)

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(available, id: \.0) { entry in
                        metricCard(label: entry.0, series: entry.1, tint: tint)
                    }
                }
            }
        }
    }

    private func metricCard(label: String, series: HealthKitService.MetricSeries, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(format(series.average))
                    .font(.system(size: 22, weight: .bold).monospacedDigit())
                    .foregroundStyle(.primary)
                Text(series.unit)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            Chart(series.daily) { day in
                AreaMark(
                    x: .value("Date", day.date),
                    y: .value(label, day.value)
                )
                .foregroundStyle(LinearGradient(
                    colors: [tint.opacity(0.55), tint.opacity(0.05)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                LineMark(
                    x: .value("Date", day.date),
                    y: .value(label, day.value)
                )
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .frame(height: 38)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Empty / disconnected states

    private var notConnectedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "heart.text.square.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.pink)
                Text("Connect Apple Health")
                    .font(.system(size: 17, weight: .semibold))
            }
            Text("Localabs needs access to read your activity, vitals, and sleep — none of this leaves your phone. Connect in the Profile tab to start seeing trends here.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var emptyDataHint: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No Apple Health data yet")
                .font(.system(size: 15, weight: .semibold))
            Text("Once your iPhone or Apple Watch logs activity, sleep, or vitals, the data will appear here.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    // MARK: - Loading + formatting

    private func refresh() async {
        guard hasRequestedHealth else { return }
        isLoading = true
        defer { isLoading = false }
        snapshot = await HealthKitService.shared.getTrends(rangeDays: rangeDays)
    }

    private func format(_ value: Double) -> String {
        if value >= 100 {
            return String(format: "%.0f", value)
        }
        if value >= 10 {
            return String(format: "%.1f", value)
        }
        return String(format: "%.2f", value)
    }
}

