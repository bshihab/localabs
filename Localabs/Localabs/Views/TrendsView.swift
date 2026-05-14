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
    /// The metric the user just tapped — drives the detail sheet.
    /// Nil means no sheet open. Wrapped in an Identifiable struct so
    /// SwiftUI's .sheet(item:) can present it.
    @State private var presentedMetric: PresentedMetric?

    struct PresentedMetric: Identifiable {
        var id: String { label }
        let label: String
        let series: HealthKitService.MetricSeries
        let tint: Color
    }

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
                        contextHeader
                            .padding(.horizontal)

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
            .sheet(item: $presentedMetric) { metric in
                MetricDetailView(
                    label: metric.label,
                    series: metric.series,
                    tint: metric.tint,
                    rangeDays: rangeDays
                )
            }
        }
    }

    // MARK: - Range picker

    /// Native Liquid Glass — same pattern Apple uses for the bottom
    /// tab bar. Each segment is its own glass capsule via
    /// `buttonStyle(.glass)` / `.glassProminent`. `GlassEffectContainer`
    /// makes the inactive capsules morph as the active one shifts.
    /// This is the system-vended treatment so it matches whatever
    /// iOS does with the tab bar, including the active-tap
    /// interactive feedback.
    private var rangePicker: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(ranges, id: \.days) { range in
                    rangeSegment(range)
                }
            }
        }
    }

    /// `.buttonStyle` takes a concrete type that Swift's type system
    /// can't switch on at the call site, so the active vs. inactive
    /// branches need to be two distinct Buttons rather than one Button
    /// with a conditional style. @ViewBuilder collapses them down.
    @ViewBuilder
    private func rangeSegment(_ range: (label: String, days: Int)) -> some View {
        if rangeDays == range.days {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    rangeDays = range.days
                }
            } label: { rangeLabel(range.label) }
            .buttonStyle(.glassProminent)
        } else {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    rangeDays = range.days
                }
            } label: { rangeLabel(range.label) }
            .buttonStyle(.glass)
        }
    }

    private func rangeLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
    }

    // MARK: - Context header

    /// Sits above the range picker so users understand why the app is
    /// pulling Health data at all — it isn't a wellness tracker for
    /// its own sake, it's the contextual layer the lab-report
    /// translation pipeline reads from when generating the empathetic
    /// summary. Removing this leaves users wondering "what does my
    /// step count have to do with my cholesterol panel?"
    private var contextHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.blue)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text("Context for every scan")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("Localabs reads these metrics from Apple Health and folds them into every lab-report translation — so your results are interpreted alongside your activity, sleep, and vitals from the past month.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
            // Auto-generated insights — pulled from any section's
            // metrics that have data. Shown above the grid so notable
            // changes catch the eye before the user starts scrolling.
            insightsSection(allEntries: activity + mobility + cardio + sleep + vitals + body + logged)

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

    /// Top-of-grid block of computed insights. Each card is a tappable
    /// shortcut that opens the matching metric's detail sheet.
    @ViewBuilder
    private func insightsSection(allEntries: [(String, HealthKitService.MetricSeries?)]) -> some View {
        let withData = allEntries.compactMap { entry -> (label: String, series: HealthKitService.MetricSeries, context: HealthInsights.ClinicalContext?)? in
            guard let s = entry.1, s.hasData else { return nil }
            return (entry.0, s, HealthInsights.clinicalContext(for: entry.0))
        }
        let insights = HealthInsights.computeInsights(from: withData, maxInsights: 3)
        if !insights.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.yellow)
                    Text("WHAT'S NOTABLE")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .tracking(1.5)
                }
                .padding(.horizontal, 4)

                VStack(spacing: 8) {
                    ForEach(insights) { insight in
                        insightRow(insight, entries: withData)
                    }
                }
            }
        }
    }

    private func insightRow(
        _ insight: HealthInsights.Insight,
        entries: [(label: String, series: HealthKitService.MetricSeries, context: HealthInsights.ClinicalContext?)]
    ) -> some View {
        Button {
            // Find the matching metric's series + tint and open the
            // detail sheet so "Tell me more" feels connected to the
            // grid below rather than ending in a dead-end card.
            guard
                let label = insight.metricLabel,
                let entry = entries.first(where: { $0.label == label })
            else { return }
            presentedMetric = PresentedMetric(
                label: entry.label,
                series: entry.series,
                tint: insight.tint
            )
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: insight.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(insight.tint)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(insight.headline)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    Text(insight.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.tint(insight.tint.opacity(0.18)), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
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
        let context = HealthInsights.clinicalContext(for: label)
        let status = context?.interpret(series.average) ?? .unknown
        let delta = deltaString(for: series)

        return Button {
            presentedMetric = PresentedMetric(label: label, series: series, tint: tint)
        } label: {
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

                // Delta vs prior period — only shown when the prior
                // window had data. Color-coded by direction so the
                // eye picks up "going up" vs "going down" at a glance.
                if let delta {
                    HStack(spacing: 4) {
                        Image(systemName: delta.direction > 0 ? "arrow.up" : "arrow.down")
                            .font(.system(size: 9, weight: .bold))
                        Text(delta.text)
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    }
                    .foregroundStyle(delta.tint)
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

                // Status bar at the bottom of each card — green
                // (typical), orange (borderline), red (outside typical),
                // or hidden if we have no clinical reference for this
                // metric. Honest: these are population norms, not a
                // personalized diagnosis (spelled out in the detail
                // sheet).
                if status != .unknown {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(status.color)
                            .frame(width: 6, height: 6)
                        Text(status.label)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(status.color)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// Builds the "↑ 4% vs prior" copy. Returns nil if the prior
    /// window had no data (so we omit the line entirely instead of
    /// showing "—" or "0%"). Direction-aware so we can color the
    /// arrow even if the user doesn't read the text.
    private func deltaString(for series: HealthKitService.MetricSeries) -> (text: String, direction: Int, tint: Color)? {
        guard let prior = series.previousAverage, prior > 0 else { return nil }
        let change = (series.average - prior) / prior
        let pct = Int((change * 100).rounded())
        if pct == 0 { return nil }
        // Direction tint: ambivalent metrics like weight don't have a
        // universal "up = bad" rule, so we use neutral blue for "up"
        // and orange for "down" — viewers can interpret per their own
        // goals. We don't try to be clever here.
        let tint: Color = change > 0 ? .blue : .orange
        return ("\(abs(pct))% vs prior period", change > 0 ? 1 : -1, tint)
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
                Task {
                    // Explicit re-request — fires iOS's prompt for any
                    // data types not previously answered. Useful when
                    // Localabs's readTypes set has grown since the
                    // user first connected (the original Connect in
                    // Profile may have asked for fewer types).
                    _ = await HealthKitService.shared.requestAuthorization()
                    await refresh()
                }
            } label: {
                Label("Re-request all permissions", systemImage: "heart.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.glassProminent)

            Button {
                openHealthApp()
            } label: {
                Label("Open Health App", systemImage: "arrow.up.right.square")
                    .font(.system(size: 14, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.glass)

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
    /// We deliberately DON'T call requestAuthorization here. iOS would
    /// briefly present + dismiss the system permission sheet on every
    /// tab-switch back to Trends because SwiftUI's TabView sometimes
    /// unmounts inactive tabs (resetting our hasRequestedThisSession
    /// @State guard), and iOS shows the auth UI even when nothing
    /// new is pending. The empty-state's "Re-request all permissions"
    /// button is the manual entry point if a user needs to grant
    /// additional types after the initial Profile connect.
    private func refresh() async {
        guard hasRequestedHealth else { return }
        isLoading = true
        defer { isLoading = false }
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

// MARK: - Metric detail sheet

/// Sheet shown when the user taps any metric card on the Trends tab.
/// Surfaces a full-size chart, the status interpretation, a clinical
/// context paragraph, and a delta-vs-prior line. The "Ask Localabs"
/// CTA at the bottom is wired up in a follow-up commit.
struct MetricDetailView: View {
    let label: String
    let series: HealthKitService.MetricSeries
    let tint: Color
    let rangeDays: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    headlineCard
                    chartCard
                    if let context = HealthInsights.clinicalContext(for: label) {
                        contextCard(context)
                    }
                    caveatCard
                }
                .padding()
                .padding(.bottom, 60)
            }
            .scrollContentBackground(.hidden)
            .background(.background)
            .navigationTitle(label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var headlineCard: some View {
        let context = HealthInsights.clinicalContext(for: label)
        let status = context?.interpret(series.average) ?? .unknown
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text(format(series.average))
                    .font(.system(size: 44, weight: .bold).monospacedDigit())
                    .foregroundStyle(.primary)
                Text(series.unit)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text("Average over the last \(rangeDays) days")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                if status != .unknown {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(status.color)
                            .frame(width: 8, height: 8)
                        Text(status.label)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(status.color)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(status.color.opacity(0.12))
                    )
                }

                if let prior = series.previousAverage, prior > 0 {
                    let change = (series.average - prior) / prior
                    let pct = Int((change * 100).rounded())
                    if pct != 0 {
                        HStack(spacing: 4) {
                            Image(systemName: change > 0 ? "arrow.up" : "arrow.down")
                                .font(.system(size: 10, weight: .bold))
                            Text("\(abs(pct))% vs prior")
                                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        }
                        .foregroundStyle(change > 0 ? Color.blue : Color.orange)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Last \(rangeDays) days")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            Chart(series.daily) { day in
                AreaMark(
                    x: .value("Date", day.date),
                    y: .value(label, day.value)
                )
                .foregroundStyle(LinearGradient(
                    colors: [tint.opacity(0.45), tint.opacity(0.05)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                LineMark(
                    x: .value("Date", day.date),
                    y: .value(label, day.value)
                )
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 2))
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine()
                    AxisValueLabel()
                }
            }
            .frame(height: 220)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func contextCard(_ context: HealthInsights.ClinicalContext) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("TYPICAL RANGE")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(1.2)
                Spacer()
                Text(context.typicalRangeLabel)
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.primary)
            }
            Divider()
            Text(context.explanation)
                .font(.system(size: 14))
                .foregroundStyle(.primary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// Honest caveat that's invisible elsewhere — this is a wellness
    /// view of Apple Health data, not a clinical diagnostic.
    private var caveatCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Text("These ranges are population norms from published research, not personalized medical advice. Discuss persistent changes with your doctor.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
    }

    private func format(_ value: Double) -> String {
        if value >= 100 { return String(format: "%.0f", value) }
        if value >= 10  { return String(format: "%.1f", value) }
        return String(format: "%.2f", value)
    }
}
