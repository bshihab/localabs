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
    /// Drives the "Ask Localabs about your trends" chat sheet.
    /// Snapshot captured at present-time so the chat sees the same
    /// data the user was looking at.
    @State private var showTrendsChat: Bool = false
    /// Symptom log entry point. Lives on the Trends tab (in addition
    /// to the History toolbar) because Trends is the "your body over
    /// time" surface users open most — pairing logged symptoms with
    /// health metrics is the natural place to surface it until the
    /// Meds/Health tab consolidates both. The logs also feed the
    /// Trends + metric chats as silent context.
    @State private var showSymptomLog: Bool = false
    /// Cross-report lab-value trends (#28), loaded from saved report
    /// history. Independent of HealthKit.
    @State private var labTrends: [LabTrend] = []
    @State private var showLabTrends: Bool = false
    /// Bumped when the user pins/unpins a marker so the lab list re-sorts
    /// pinned markers to the top in place.
    @State private var trackedVersion = 0
    /// Which data source the tab is showing — Apple Health metrics or
    /// lab-report trends. Replaces the old single long scroll.
    @State private var dataSource: DataSource = .health

    enum DataSource: String, CaseIterable {
        case health, labs
        var label: String {
            switch self {
            case .health: return "Apple Health"
            case .labs:   return "Lab Reports"
            }
        }
    }

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
                // The "Health Trends" header used to be a Text view
                // inside this VStack with a manually-set font. That
                // bypassed the system's large-to-inline title
                // behavior, so when the user scrolled, the title
                // just disappeared off the top instead of collapsing
                // into a centered inline title with the blur-behind-
                // the-notch effect the other tabs (History, Profile)
                // get for free. Switched to .navigationTitle +
                // .navigationBarTitleDisplayMode(.large) — the
                // system handles the shrink + blur automatically.
                VStack(alignment: .leading, spacing: 22) {
                    dataSourcePicker
                        .padding(.horizontal)

                    if dataSource == .health {
                        healthContent
                    } else {
                        labContent
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 100)
            }
            .scrollContentBackground(.hidden)
            .background(.background)
            .navigationTitle("Health Trends")
            .navigationBarTitleDisplayMode(.large)
            // Recompute on every appearance so deleting a report
            // elsewhere (History) is reflected here even if this tab
            // was already loaded in the background. Cheap — a
            // UserDefaults read + in-memory grouping.
            .onAppear {
                labTrends = LabTrendService.trends(from: LocalStorageService.shared.getHistory())
            }
            // When the age/sex range recompute finishes (banner goes
            // away), reload so the new thresholds show even if the user
            // is already sitting on this tab.
            .onChange(of: engine.rangeRecompute?.done) { _, _ in
                if engine.rangeRecompute == nil {
                    labTrends = LabTrendService.trends(from: LocalStorageService.shared.getHistory())
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSymptomLog = true
                    } label: {
                        Label("Symptoms", systemImage: "heart.text.square")
                    }
                }
            }
            .task(id: rangeDays) {
                // Pull the auth flag fresh every time the view appears
                // or the range changes — Profile may have flipped it
                // while we were away, and SwiftUI @State otherwise
                // sticks to the value it had at first init.
                hasRequestedHealth = HealthKitService.shared.hasRequestedAuthorization
                labTrends = LabTrendService.trends(from: LocalStorageService.shared.getHistory())
                await refresh()
            }
            .sheet(isPresented: $showTrendsChat) {
                // Capture the current snapshot's HealthMetrics at
                // present-time so the chat doesn't lag behind if
                // the snapshot refreshes mid-conversation. If the
                // user hasn't loaded any data yet we pass an empty
                // struct — the model just has profile + RAG to
                // work with.
                TrendsChatView(healthMetrics: makeHealthMetricsForChat())
                    .environmentObject(engine)
            }
            .sheet(isPresented: $showSymptomLog) {
                SymptomLogView()
            }
            .sheet(isPresented: $showLabTrends) {
                LabComparisonView(trends: labTrends)
            }
            .sheet(item: $presentedMetric) { metric in
                MetricDetailView(
                    label: metric.label,
                    series: metric.series,
                    tint: metric.tint,
                    rangeDays: rangeDays,
                    siblingMetrics: makeHealthMetricsForChat()
                )
                .environmentObject(engine)
            }
        }
    }

    // MARK: - Lab values (#28)

    /// A card listing cross-report lab trends, tappable to open the
    /// full comparison sheet. Shows the first few markers inline with
    /// worsening ones surfaced first (LabTrendService already sorts
    /// that way).
    /// Lab trends with pinned (tracked) markers floated to the top —
    /// recomputed when `trackedVersion` bumps so a pin tap re-sorts live.
    private var sortedLabTrends: [LabTrend] {
        _ = trackedVersion
        let pinned = labTrends.filter { TrackedMarkers.isTracked($0.canonicalName) }
        let rest = labTrends.filter { !TrackedMarkers.isTracked($0.canonicalName) }
        return pinned + rest
    }

    private var labValuesSection: some View {
        let rows = sortedLabTrends
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("LAB VALUES OVER TIME")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(1.0)
                Spacer()
                Text("Tap 📌 to pin")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            VStack(spacing: 0) {
                ForEach(rows) { trend in
                    LabTrendRow(trend: trend, onTrackToggle: { trackedVersion += 1 })
                    if trend.id != rows.last?.id {
                        Divider()
                    }
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )

            // Explain where the "normal" range comes from + that it's
            // personalized to the user's age/sex when a report omits one.
            Text(labRangeFootnote)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// Footnote under the lab trends explaining the source of the
    /// normal range — and nudging the user to fill in age/sex if they
    /// haven't, since that's what personalizes the filled-in ranges.
    private var labRangeFootnote: String {
        let profile = UserProfile.load()
        if profile.hasDemographicsForStatusLabels {
            return "Normal ranges are taken from each report, or — when a report doesn't list one — set by the on-device AI for your age and sex. Informational only; not a diagnosis."
        } else {
            return "Normal ranges are taken from each report. Add your age and biological sex in Profile so ranges can be personalized when a report doesn't list one. Informational only; not a diagnosis."
        }
    }

    // MARK: - Data-source toggle + content branches

    /// Liquid Glass segmented control switching between Apple Health
    /// metrics and lab-report trends — same glass treatment as the
    /// range picker. Replaces the old single long scroll where both
    /// stacked.
    private var dataSourcePicker: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(DataSource.allCases, id: \.self) { source in
                    dataSourceSegment(source)
                }
            }
        }
    }

    @ViewBuilder
    private func dataSourceSegment(_ source: DataSource) -> some View {
        if dataSource == source {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { dataSource = source }
            } label: { rangeLabel(source.label) }
            .buttonStyle(.glassProminent)
        } else {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { dataSource = source }
            } label: { rangeLabel(source.label) }
            .buttonStyle(.glass)
        }
    }

    /// Apple Health branch — the existing metric grid + range picker.
    @ViewBuilder
    private var healthContent: some View {
        if !hasRequestedHealth {
            notConnectedCard.padding(.horizontal)
        } else {
            contextHeader.padding(.horizontal)
            askLocalabsCTA.padding(.horizontal)
            rangePicker.padding(.horizontal)
            if isLoading && snapshot == nil {
                ProgressView("Loading from Apple Health…")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            } else if let snapshot, snapshotHasAnyData(snapshot) {
                renderedCards(for: snapshot)
            } else {
                emptyDataHint.padding(.horizontal)
            }
        }
    }

    /// Lab-report branch — all cross-report lab trends, or an empty
    /// state prompting the user to scan two reports that share a marker.
    @ViewBuilder
    private var labContent: some View {
        if labTrends.isEmpty {
            labTrendsEmptyState.padding(.horizontal)
        } else {
            labValuesSection.padding(.horizontal)
        }
    }

    private var labTrendsEmptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
                .opacity(0.6)
            Text("No lab trends yet")
                .font(.headline)
            Text("Scan two or more lab reports that share a marker — like cholesterol or A1c — and Localabs will track how it changes over time here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 50)
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

    // MARK: - Ask Localabs CTA

    /// Prominent gradient card pinned right under the context
    /// header. Same shape language as Dashboard's "Ask More About
    /// Your Scan" card so users recognize the pattern (big tappable
    /// CTA → chat sheet). Tap presents TrendsChatView, scoped to
    /// the current snapshot.
    private var askLocalabsCTA: some View {
        Button {
            showTrendsChat = true
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.22))
                        .frame(width: 44, height: 44)
                    Image(systemName: "sparkle.magnifyingglass")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .symbolEffect(.pulse, options: .repeat(.continuous))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Ask Localabs about your trends")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Synthesizes Health data + past scans + your profile")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.88))
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(
                LinearGradient(
                    colors: [Color.blue, Color.blue.opacity(0.82)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: Color.blue.opacity(0.28), radius: 12, y: 5)
        }
        .buttonStyle(.plain)
    }

    /// Pulls the current snapshot's averages into the smaller
    /// `HealthMetrics` shape the chat / inference engine expects.
    /// Returns an empty struct when there's no snapshot yet — the
    /// chat will still work, the model just has profile + RAG to
    /// answer from.
    private func makeHealthMetricsForChat() -> HealthKitService.HealthMetrics {
        guard let s = snapshot else { return HealthKitService.HealthMetrics() }
        return HealthKitService.HealthMetrics(
            avgRestingHR: s.restingHR?.average,
            avgSleepHours: s.sleepHours?.average,
            avgHRV: s.hrv?.average,
            avgSteps: s.steps?.average,
            avgWalkingDistanceMiles: s.walkingRunningDistance?.average,
            avgWalkingSpeedMPH: s.walkingSpeed?.average,
            avgExerciseMinutes: s.exerciseMinutes?.average
        )
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
            // (The "What's notable" insights block was removed — it
            // pushed the actual metric grid below the fold and forced
            // scrolling. The data-source segmented control at the top
            // is the new way to focus.)
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
        let profile = UserProfile.load()
        let age = profile.ageYears
        let sex = HealthInsights.BiologicalSex.from(profile.biologicalSex)
        let insights = HealthInsights.computeInsights(from: withData, age: age, sex: sex, maxInsights: 3)
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
        // Status pills are personalized: HRV, VO₂ max, walking
        // speed, sleep, and resting HR each use age- and sex-
        // stratified cutoffs from peer-reviewed sources, so the
        // same number reads differently for a 25-year-old vs. a
        // 65-year-old. When the user hasn't supplied either field,
        // we suppress the pill entirely (force .unknown) rather
        // than fall back to a generic adult norm — population-
        // average pills without that context were the original
        // "vague at best, misleading at worst" problem.
        let profile = UserProfile.load()
        let age = profile.ageYears
        let sex = HealthInsights.BiologicalSex.from(profile.biologicalSex)
        let rawStatus = context?.interpret(series.average, age, sex) ?? .unknown
        let status: HealthInsights.Status = profile.hasDemographicsForStatusLabels ? rawStatus : .unknown
        let delta = deltaString(for: series)
        let isCumulative = HealthInsights.isCumulativeMetric(label)

        return Button {
            presentedMetric = PresentedMetric(label: label, series: series, tint: tint)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(label)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text(format(series.average))
                        .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.primary)
                    Text(series.unit)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
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
                            .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                    }
                    .foregroundStyle(delta.tint)
                }

                // Sparkline: bars for cumulative metrics (steps, etc.)
                // so the day-to-day discrete totals read clearly; a
                // smooth line+area for continuous metrics (HR, HRV,
                // weight) so the trend reads as a single curve.
                Chart {
                    ForEach(series.daily) { day in
                        if isCumulative {
                            BarMark(
                                x: .value("Date", day.date, unit: .day),
                                y: .value(label, day.value),
                                width: .ratio(0.7)
                            )
                            .foregroundStyle(tint.gradient)
                            .cornerRadius(1.5)
                        } else {
                            AreaMark(
                                x: .value("Date", day.date),
                                y: .value(label, day.value)
                            )
                            .foregroundStyle(LinearGradient(
                                colors: [tint.opacity(0.45), tint.opacity(0.03)],
                                startPoint: .top,
                                endPoint: .bottom
                            ))
                            .interpolationMethod(.catmullRom)

                            LineMark(
                                x: .value("Date", day.date),
                                y: .value(label, day.value)
                            )
                            .foregroundStyle(tint)
                            .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                            .interpolationMethod(.catmullRom)
                        }
                    }
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
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
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

    /// Builds the "↑ 4% vs previous 30 days" copy. Returns nil if the
    /// prior window had no data (so we omit the line entirely instead
    /// of showing "—" or "0%"). Direction-aware so we can color the
    /// arrow even if the user doesn't read the text. The cards use a
    /// short form ("vs prev 30d") to fit two-column layout; the detail
    /// sheet uses the long form spelled out.
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
        return ("\(abs(pct))% vs prev \(rangeDays)d", change > 0 ? 1 : -1, tint)
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
/// Apple-Health-style layout: big bold rounded number up top, full
/// chart (bars for cumulative metrics, smooth line+area for
/// continuous), then status legend, clinical context, and a CTA to
/// open a chat scoped to this single metric.
struct MetricDetailView: View {
    let label: String
    let series: HealthKitService.MetricSeries
    let tint: Color
    let rangeDays: Int
    /// The other metric averages from the same snapshot. Passed
    /// through to the per-metric chat so the model can cross-reference
    /// siblings (e.g. low HRV + short sleep) without us having to
    /// hit HealthKit again.
    var siblingMetrics: HealthKitService.HealthMetrics = HealthKitService.HealthMetrics()

    @EnvironmentObject var engine: InferenceEngine
    @Environment(\.dismiss) private var dismiss
    @State private var showMetricChat: Bool = false

    private var isCumulative: Bool { HealthInsights.isCumulativeMetric(label) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    headlineCard
                    chartCard
                    askLocalabsCTA
                    statusLegendCard
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
            .sheet(isPresented: $showMetricChat) {
                MetricChatView(
                    label: label,
                    series: series,
                    tint: tint,
                    rangeDays: rangeDays,
                    siblingMetrics: siblingMetrics
                )
                .environmentObject(engine)
            }
        }
    }

    // MARK: Headline (big rounded number, status pill, delta)

    private var headlineCard: some View {
        let context = HealthInsights.clinicalContext(for: label)
        // Match TrendsView.metricCard: status pill only renders when
        // the user has supplied age + biological sex, and when it
        // does, the underlying interpret call is given those values
        // so the threshold is age/sex-bracketed instead of generic.
        let profile = UserProfile.load()
        let age = profile.ageYears
        let sex = HealthInsights.BiologicalSex.from(profile.biologicalSex)
        let rawStatus = context?.interpret(series.average, age, sex) ?? .unknown
        let status: HealthInsights.Status = profile.hasDemographicsForStatusLabels ? rawStatus : .unknown
        return VStack(alignment: .leading, spacing: 14) {
            // "AVERAGE" pill above the value, Apple Health style.
            Text(isCumulative ? "DAILY AVERAGE" : "AVERAGE")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.secondary)
                .tracking(1.4)

            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text(format(series.average))
                    .font(.system(size: 48, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.primary)
                Text(series.unit)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Text("Last \(rangeDays) days")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                if status != .unknown {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(status.color)
                            .frame(width: 8, height: 8)
                        Text(status.label)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
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
                            Text("\(abs(pct))% vs previous \(rangeDays) days")
                                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                        }
                        .foregroundStyle(change > 0 ? Color.blue : Color.orange)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    // MARK: Chart (Apple Health style)

    /// Renders bars for cumulative metrics (Steps, Distance, Flights,
    /// Exercise minutes, Active energy, Caffeine) and a smooth
    /// line+area for continuous metrics. Axis labels are SF Rounded
    /// to match the Apple Health typography hierarchy.
    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Soft inline range label, top-left of the card —
            // duplicates "Last X days" subtly so the user always knows
            // what window the chart spans without scrolling back up.
            HStack {
                Text("\(rangeDays.formatted()) DAYS")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .tracking(1.3)
                Spacer()
            }

            Chart {
                ForEach(series.daily) { day in
                    if isCumulative {
                        BarMark(
                            x: .value("Date", day.date, unit: .day),
                            y: .value(label, day.value),
                            width: .ratio(0.65)
                        )
                        .foregroundStyle(tint.gradient)
                        .cornerRadius(2)
                    } else {
                        AreaMark(
                            x: .value("Date", day.date),
                            y: .value(label, day.value)
                        )
                        .foregroundStyle(LinearGradient(
                            colors: [tint.opacity(0.42), tint.opacity(0.03)],
                            startPoint: .top,
                            endPoint: .bottom
                        ))
                        .interpolationMethod(.catmullRom)

                        LineMark(
                            x: .value("Date", day.date),
                            y: .value(label, day.value)
                        )
                        .foregroundStyle(tint)
                        .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.catmullRom)
                    }
                }
            }
            .chartXAxis {
                // ~4 evenly-spaced day ticks across the window — Apple
                // Health shows day-of-month numbers like "5, 12, 19, 26"
                // for a monthly view.
                let stride = max(1, rangeDays / 4)
                AxisMarks(values: .stride(by: .day, count: stride)) { _ in
                    AxisValueLabel(format: .dateTime.day(), centered: true)
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .chartYAxis {
                // Y axis on the right with subtle dotted gridlines so
                // the chart reads "Apple Health" instead of "default
                // SwiftUI Chart."
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                        .foregroundStyle(Color.secondary.opacity(0.35))
                    AxisValueLabel()
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 220)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    // MARK: Ask Localabs about this trend (CTA)

    /// Compact gradient CTA that opens a chat scoped to this specific
    /// metric. Distinct from the broader Trends chat — the per-metric
    /// chat puts THIS metric first in the prompt and treats other
    /// metrics + past scans as supporting context.
    private var askLocalabsCTA: some View {
        Button {
            showMetricChat = true
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.22))
                        .frame(width: 40, height: 40)
                    Image(systemName: "sparkle.magnifyingglass")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .symbolEffect(.pulse, options: .repeat(.continuous))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ask Localabs about this trend")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Focused on \(label) — plus other trends & scans for context")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(
                LinearGradient(
                    colors: [tint, tint.opacity(0.78)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: tint.opacity(0.28), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
    }

    // MARK: Status legend (what Typical / Borderline / Outside mean)

    /// Three-row key explaining what each status color actually means
    /// — but only when the user has supplied demographics. Without
    /// age + biological sex we don't show status pills (they'd be
    /// generic and misleading), so the legend pivots to an inline
    /// "add your age + sex to enable status labels" prompt instead.
    @ViewBuilder
    private var statusLegendCard: some View {
        let profile = UserProfile.load()
        if profile.hasDemographicsForStatusLabels {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text("WHAT THE STATUS LABELS MEAN")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .tracking(1.2)
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(HealthInsights.statusLegend().enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top, spacing: 10) {
                            Circle()
                                .fill(item.color)
                                .frame(width: 8, height: 8)
                                .padding(.top, 6)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.label)
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundStyle(item.color)
                                Text(item.description)
                                    .font(.system(size: 12, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        } else {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 22))
                    .foregroundStyle(.blue)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add your age + biological sex to see status labels")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Typical / Borderline / Outside-typical labels need both fields — population norms shift with each. Set them under Profile → Personal Health.")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }

    // MARK: Clinical context

    private func contextCard(_ context: HealthInsights.ClinicalContext) -> some View {
        // typicalRangeLabel is now demographics-aware: HRV, VO₂ max,
        // walking speed, sleep, and resting HR each return a band
        // appropriate to the user's age/sex bracket (e.g. HRV
        // shows "30–55 ms" for a 45-year-old and "50–80 ms" for a
        // 25-year-old). Without profile demographics it falls back
        // to the adult-typical band.
        let profile = UserProfile.load()
        let age = profile.ageYears
        let sex = HealthInsights.BiologicalSex.from(profile.biologicalSex)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("TYPICAL RANGE")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .tracking(1.2)
                Spacer()
                Text(context.typicalRangeLabel(age, sex))
                    .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.primary)
            }
            Divider()
            Text(context.explanation)
                .font(.system(size: 14, design: .rounded))
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
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
    }

    private func format(_ value: Double) -> String {
        // For cumulative metrics with big numbers (steps especially),
        // Apple Health uses comma grouping ("5,326"). Re-using the
        // localized number formatter so the user's locale dictates the
        // separator.
        if isCumulative && value >= 1000 {
            return value.formatted(.number.precision(.fractionLength(0)))
        }
        if value >= 100 { return String(format: "%.0f", value) }
        if value >= 10  { return String(format: "%.1f", value) }
        return String(format: "%.2f", value)
    }
}
