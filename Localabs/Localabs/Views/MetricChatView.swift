import SwiftUI
import UIKit

/// Chat sheet for a *single* Apple Health metric, presented from the
/// MetricDetailView's "Ask Localabs about this trend" CTA.
///
/// This is intentionally separate from TrendsChatView so the prompt
/// to the model can be ordered with strict priority:
///   1. The focus metric (subject of the conversation).
///   2. Sibling Apple Health metrics (cross-reference only).
///   3. Past lab reports (mentioned only when genuinely connected).
///
/// The UI mirrors TrendsChatView so users feel the same surface —
/// glass input, glass send button, iMessage-style TypingDots while
/// waiting on the first token — but the empty-state header, starter
/// chips, and system prompt are all metric-scoped.
struct MetricChatView: View {
    let label: String
    let series: HealthKitService.MetricSeries
    let tint: Color
    let rangeDays: Int
    /// Other metrics the chat can pull in as supporting context.
    /// Captured from the same snapshot the user was looking at.
    let siblingMetrics: HealthKitService.HealthMetrics

    @EnvironmentObject var engine: InferenceEngine
    @Environment(\.dismiss) private var dismiss

    @State private var messages: [ChatMessage] = []
    @State private var inputText: String = ""
    @State private var isThinking: Bool = false
    /// The in-flight generation, held so we can hard-cancel it the
    /// instant the chat is dismissed — otherwise the model keeps
    /// decoding in the background and the per-word haptics keep
    /// pulsing after the user has left the sheet.
    @State private var streamTask: Task<Void, Never>?
    /// Drives the "+" quick-add-to-profile sheet from the input bar.
    @State private var showQuickAddSheet = false

    struct ChatMessage: Identifiable, Equatable {
        let id = UUID()
        let role: Role
        var content: String
        var isStreaming: Bool = false
        enum Role { case user, ai }
    }

    /// Starter prompts shaped to the specific metric. Building these
    /// from the label keeps the UX consistent without us writing a
    /// per-metric template — the model has the metric's clinical
    /// context in the system prompt anyway.
    private var starterQuestions: [String] {
        [
            "Is my \(label.lowercased()) trend healthy for my age and profile?",
            "What lifestyle changes would most affect my \(label.lowercased())?",
            "How does my \(label.lowercased()) relate to my other Health data and past labs?"
        ]
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            if messages.isEmpty {
                                emptyStateHeader
                                    .padding(.horizontal)
                                    .padding(.top, 16)
                            }

                            ForEach(messages) { message in
                                messageRow(message)
                                    .id(message.id)
                            }
                        }
                        .padding(.bottom, 16)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: messages) { _, _ in
                        if let last = messages.last {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }

                if messages.isEmpty {
                    starterChips
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                }

                inputBar
            }
            .navigationTitle("Ask about \(label)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .background(Color(uiColor: .systemBackground))
            .sheet(isPresented: $showQuickAddSheet) {
                ProfileQuickAddSheet(prefilledValue: inputText)
            }
        }
        .presentationContentInteraction(.scrolls)
        // Leaving the chat mid-generation must stop the model cold:
        // cancel the streaming task so decoding halts and no further
        // haptics fire.
        .onDisappear {
            streamTask?.cancel()
            streamTask = nil
        }
    }

    // MARK: - Empty state + starter chips

    /// Compact summary card so users see the metric's current value
    /// inline at the top of the chat — no need to scroll back to the
    /// detail sheet to remember "what was my number again?"
    private var emptyStateHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 20))
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Focused on your \(label) trend")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                    Text("\(rangeDays)-day average: \(formattedAverage) \(series.unit)")
                        .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Text("Localabs answers about \(label) first, then brings in your other Health trends and past lab reports as supporting context when it genuinely helps.")
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var starterChips: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Try asking:")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .tracking(0.5)

            VStack(spacing: 6) {
                ForEach(starterQuestions, id: \.self) { question in
                    Button {
                        send(question)
                    } label: {
                        HStack {
                            Text(question)
                                .font(.system(size: 13, design: .rounded))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(tint)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Messages

    @ViewBuilder
    private func messageRow(_ message: ChatMessage) -> some View {
        if message.role == .ai && message.isStreaming && message.content.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 20))
                    .foregroundStyle(tint)
                    .padding(.top, 6)
                TypingDots()
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
        } else {
            chatBubble(for: message)
        }
    }

    private func chatBubble(for message: ChatMessage) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if message.role == .ai {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 20))
                    .foregroundStyle(tint)
                    .padding(.top, 6)
            }

            MarkdownBody(message.content)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: 280, alignment: .leading)
                .glassEffect(
                    message.role == .user
                        ? .regular.tint(tint.opacity(0.85))
                        : .regular,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .foregroundStyle(message.role == .user ? Color.white : Color.primary)

            if message.role == .ai { Spacer(minLength: 0) }
            if message.role == .user {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        .padding(.horizontal)
    }

    // MARK: - Input

    private var inputBar: some View {
        HStack(spacing: 10) {
            // Manual quick-save sheet trigger — same shape the
            // other two chats use.
            Button {
                showQuickAddSheet = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.interactive(), in: Circle())
            }
            .accessibilityLabel("Save something to your profile")

            TextField("Ask about your \(label.lowercased())…", text: $inputText, axis: .vertical)
                .lineLimit(1...4)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                // Fixed-radius rounded rect, not a Capsule — see
                // TrendsChatView: a Capsule clips text as the field grows.
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

            Button {
                send(inputText)
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(canSend ? Color.white : Color.secondary)
                    .frame(width: 44, height: 44)
                    .glassEffect(
                        canSend
                            ? .regular.tint(tint.opacity(0.85)).interactive()
                            : .regular.interactive(),
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .animation(.easeInOut(duration: 0.2), value: canSend)
        }
        .padding(.horizontal)
        .padding(.bottom, 10)
        .padding(.top, 6)
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isThinking
    }

    // MARK: - Send + stream

    private func send(_ rawQuestion: String) {
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isThinking else { return }

        let history: [InferenceEngine.ChatTurn] = messages
            .filter { !$0.isStreaming }
            .map { .init(isUser: $0.role == .user, content: $0.content) }

        messages.append(ChatMessage(role: .user, content: question))
        inputText = ""
        isThinking = true

        let aiMessage = ChatMessage(role: .ai, content: "", isStreaming: true)
        let aiId = aiMessage.id
        messages.append(aiMessage)

        // Pre-compute the descriptive bits the model needs about
        // this metric — pulling from the same HealthInsights source
        // the detail sheet renders so the chat and the sheet can't
        // disagree on the numbers. Status + typical-range use the
        // user's age/sex when available so the model is reasoning
        // about the same demographics-aware band the user sees on
        // their card.
        let context = HealthInsights.clinicalContext(for: label)
        let profile = UserProfile.load()
        let age = profile.ageYears
        let sex = HealthInsights.BiologicalSex.from(profile.biologicalSex)
        let hasDemographics = profile.hasDemographicsForStatusLabels
        let rawStatus = context?.interpret(series.average, age, sex) ?? .unknown
        let status: HealthInsights.Status = hasDemographics ? rawStatus : .unknown
        let statusLabel = status == .unknown ? nil : status.label
        let typicalRange = context.map { $0.typicalRangeLabel(age, sex) }
        let deltaText = formattedDelta

        streamTask = Task {
            let stream = engine.askAboutMetric(
                question: question,
                history: history,
                metricLabel: label,
                metricValue: formattedAverage,
                metricUnit: series.unit,
                metricRangeDays: rangeDays,
                metricStatusLabel: statusLabel,
                metricTypicalRange: typicalRange,
                metricExplanation: context?.explanation,
                metricDelta: deltaText,
                otherHealthMetrics: siblingMetrics
            )
            // Selection-feedback generator pulses softly on each word
            // boundary so the chat feels like it's typing into the
            // user's palm. Per-piece pulses would jitter (a single
            // word can stream in 2–3 sub-word chunks); whitespace-
            // bearing pieces give a natural per-word cadence.
            let haptic = UISelectionFeedbackGenerator()
            haptic.prepare()
            var receivedFirstPiece = false
            for await piece in stream {
                // User left the sheet → stop appending and stop the
                // haptics immediately. The AsyncStream's onTermination
                // tears down the underlying decode.
                if Task.isCancelled { break }
                if !receivedFirstPiece {
                    isThinking = false
                    receivedFirstPiece = true
                }
                if let idx = messages.firstIndex(where: { $0.id == aiId }) {
                    messages[idx].content += piece
                }
                if piece.contains(where: \.isWhitespace) {
                    haptic.selectionChanged()
                    haptic.prepare()
                }
            }
            if Task.isCancelled { return }
            if let idx = messages.firstIndex(where: { $0.id == aiId }) {
                messages[idx].isStreaming = false
            }
            isThinking = false
        }
    }

    // MARK: - Formatting helpers

    private var formattedAverage: String {
        let value = series.average
        if HealthInsights.isCumulativeMetric(label) && value >= 1000 {
            return value.formatted(.number.precision(.fractionLength(0)))
        }
        if value >= 100 { return String(format: "%.0f", value) }
        if value >= 10  { return String(format: "%.1f", value) }
        return String(format: "%.2f", value)
    }

    private var formattedDelta: String? {
        guard let prior = series.previousAverage, prior > 0 else { return nil }
        let change = (series.average - prior) / prior
        let pct = Int((change * 100).rounded())
        if pct == 0 { return nil }
        let direction = change > 0 ? "up" : "down"
        return "\(direction) \(abs(pct))% vs previous \(rangeDays) days"
    }
}
