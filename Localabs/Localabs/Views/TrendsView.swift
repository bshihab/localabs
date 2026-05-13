import SwiftUI
import Charts
import UIKit

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
    @Namespace private var pickerThumb

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

                        if isLoading && snapshot == nil {
                            ProgressView("Loading from Apple Health…")
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        } else if let snapshot, snapshotHasAnyData(snapshot) {
                            renderedCards(for: snapshot)
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
                // Pull the auth flag fresh every time the view appears
                // or the range changes — Profile may have flipped it
                // while we were away, and SwiftUI @State otherwise
                // sticks to the value it had at first init.
                hasRequestedHealth = HealthKitService.shared.hasRequestedAuthorization
                await refresh()
            }
        }
    }

    // MARK: - Range picker

    /// Native iOS 26 Liquid Glass pill. Outer track gets a `.regular`
    /// glass via Color.clear-as-View (Apple's pattern — `.fill(.clear)`
    /// on a Shape has no view content for the glass to refract).
    /// `GlassEffectContainer` makes the thumb morph smoothly when the
    /// user taps a different segment instead of cross-fading. The
    /// active thumb uses `.interactive()` which gives the proper
    /// press response Apple's own segmented controls use.
    private var rangePicker: some View {
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(ranges, id: \.days) { range in
                    rangeSegment(range)
                }
            }
            .padding(4)
            .background(
                Color.clear
                    .glassEffect(.regular, in: Capsule())
            )
        }
    }

    private func rangeSegment(_ range: (label: String, days: Int)) -> some View {
        Text(range.label)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(rangeDays == range.days ? Color.primary : Color.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background {
                if rangeDays == range.days {
                    // Color.clear IS a View — applying glassEffect to a
                    // shape's .fill(.clear) has no view content to
                    // refract, which is why the previous version
                    // looked like a tinted shape rather than glass.
                    Color.clear
                        .glassEffect(.regular.tint(.blue.opacity(0.5)).interactive(), in: Capsule())
                        .matchedGeometryEffect(id: "rangeThumb", in: pickerThumb)
                }
            }
            .contentShape(Capsule())
            .onTapGesture {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    rangeDays = range.days
                }
            }
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
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("No Apple Health data yet")
                    .font(.system(size: 15, weight: .semibold))
                Text("If you've already connected Apple Health, the individual data types may be turned off. Toggle them on in the Health app:")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 5) {
                healthStep(number: 1, text: "Open the **Health** app")
                healthStep(number: 2, text: "Tap your **profile picture** (top-right)")
                healthStep(number: 3, text: "Scroll to **Privacy** and tap **Apps and Services**")
                healthStep(number: 4, text: "Tap **Localabs** and turn on every toggle you want Localabs to read")
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

            Button {
                Task { await refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// Same numbered-step row pattern Profile uses for the Health
    /// walkthrough, so the UX feels consistent across both empty
    /// states. The text accepts `**markdown bold**`.
    private func healthStep(number: Int, text: String) -> some View {
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

    private func openHealthApp() {
        if let url = URL(string: "x-apple-health://") {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - Loading + formatting

    /// Refresh fires on first appear AND every time the range changes.
    /// We re-request authorization before fetching because the
    /// Trends-tab readTypes set is larger than what Profile's
    /// "Connect Apple Health" originally asked for — iOS only shows a
    /// prompt for newly-added types, so existing approvals carry over.
    /// This is what makes the screen "fill in" the first time the
    /// user lands on it after the Trends tab was added.
    private func refresh() async {
        guard hasRequestedHealth else { return }
        isLoading = true
        defer { isLoading = false }
        _ = await HealthKitService.shared.requestAuthorization()
        snapshot = await HealthKitService.shared.getTrends(rangeDays: rangeDays)
    }

    /// True when at least one metric in the snapshot has samples in
    /// the current window. Drives the "fall back to emptyDataHint"
    /// branch — without it, denied/empty users see a blank screen.
    private func snapshotHasAnyData(_ s: HealthKitService.TrendsSnapshot) -> Bool {
        let series: [HealthKitService.MetricSeries?] = [
            s.steps, s.walkingRunningDistance, s.flightsClimbed, s.exerciseMinutes, s.activeEnergy,
            s.walkingSpeed, s.walkingStepLength, s.walkingAsymmetry, s.walkingDoubleSupport, s.sixMinuteWalkDistance,
            s.restingHR, s.hrv, s.vo2Max, s.walkingHR,
            s.sleepHours,
            s.systolicBP, s.diastolicBP, s.oxygenSaturation, s.respiratoryRate, s.bodyTemperature,
            s.bodyMass, s.bodyMassIndex,
            s.bloodGlucose, s.caffeine
        ]
        return series.contains { $0?.hasData == true }
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

