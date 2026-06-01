import SwiftUI
import UIKit

/// Chat sheet presented from the Trends tab's "Ask Localabs" CTA.
/// Mirrors the FollowUpChatView pattern but scoped to the user's
/// broader trends (HealthKit data + past lab reports + profile)
/// rather than a single document's selected text.
///
/// Conversations here are ephemeral by design: the Trends window
/// is rolling (last 7/30/90 days), so a chat from weeks ago would
/// be asking about state that no longer exists. Each open session
/// is a fresh slate.
struct TrendsChatView: View {
    /// Captured at sheet-open time so the model sees the same
    /// snapshot the user was looking at when they tapped the CTA.
    let healthMetrics: HealthKitService.HealthMetrics

    @EnvironmentObject var engine: InferenceEngine
    @Environment(\.dismiss) private var dismiss

    @State private var messages: [ChatMessage] = []
    @State private var inputText: String = ""
    @State private var isThinking: Bool = false
    /// The in-flight generation. Held so we can hard-cancel it the
    /// instant the chat is dismissed — otherwise the model keeps
    /// decoding in the background and the per-word haptics keep
    /// pulsing even though the user has left the sheet.
    @State private var streamTask: Task<Void, Never>?
    /// Drives the "+" quick-add-to-profile sheet from the input
    /// bar. See FollowUpChatView for the design rationale (manual
    /// replaces the previous unreliable auto-detection feature).
    @State private var showQuickAddSheet = false

    /// Suggested-question chips shown above the input bar when the
    /// conversation is empty. Tapping one fires it as the first
    /// user turn so users have a starting point rather than a
    /// blank prompt.
    private let starterQuestions: [String] = [
        "How do my recent activity trends compare to my last lab report?",
        "Any patterns in my sleep or HRV worth bringing up to my doctor?",
        "What lifestyle changes could improve my health based on what you've seen?"
    ]

    struct ChatMessage: Identifiable, Equatable {
        let id = UUID()
        let role: Role
        var content: String
        var isStreaming: Bool = false
        enum Role { case user, ai }
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
            .navigationTitle("Ask Localabs")
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

    private var emptyStateHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 20))
                    .foregroundStyle(.yellow)
                Text("Synthesizes across your trends + past scans")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            Text("Localabs combines what's in Apple Health, every lab report you've scanned, and your health profile to answer questions about how it all fits together.")
                .font(.system(size: 13))
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
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)

            VStack(spacing: 6) {
                ForEach(starterQuestions, id: \.self) { question in
                    Button {
                        send(question)
                    } label: {
                        HStack {
                            Text(question)
                                .font(.system(size: 13))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.blue)
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
        // Empty streaming AI placeholder = "waiting for the first
        // token." Render TypingDots inline instead of an empty glass
        // bubble — same pattern as FollowUpChatView so the user sees
        // the iMessage-style indicator in the same spot the bubble
        // will appear once tokens arrive.
        if message.role == .ai && message.isStreaming && message.content.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkle")
                    .font(.system(size: 20))
                    .foregroundStyle(.blue)
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
                Image(systemName: "sparkle")
                    .font(.system(size: 20))
                    .foregroundStyle(.blue)
                    .padding(.top, 6)
            }

            // MarkdownBody handles **bold**, *italic*, bullets (- ),
            // and tables — same renderer the report sections use.
            MarkdownBody(message.content)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: 280, alignment: .leading)
                .glassEffect(
                    message.role == .user
                        ? .regular.tint(.blue.opacity(0.85))
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
            // "+ to profile" — manual quick-save sheet, same shape
            // FollowUpChatView and MetricChatView use.
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

            TextField("Ask about your trends…", text: $inputText, axis: .vertical)
                .lineLimit(1...4)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                // Fixed-radius rounded rect, not a Capsule: a Capsule's
                // corner radius is half its height, so as the field
                // grows to multiple lines the rounding balloons and
                // clips the text. A fixed 22pt radius stays consistent.
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

            // Liquid-glass send button: tinted blue when there's
            // something to send, plain glass when disabled. Matches
            // the FollowUpChatView pattern so the two chats feel
            // like the same surface.
            Button {
                send(inputText)
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(canSend ? Color.white : Color.secondary)
                    .frame(width: 44, height: 44)
                    .glassEffect(
                        canSend
                            ? .regular.tint(.blue.opacity(0.85)).interactive()
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

        // Capture the prior turns BEFORE we mutate `messages` so the
        // history we pass to the engine doesn't include the new
        // question (the engine receives the new question as a
        // separate parameter).
        let history: [InferenceEngine.ChatTurn] = messages
            .filter { !$0.isStreaming }
            .map { .init(isUser: $0.role == .user, content: $0.content) }

        messages.append(ChatMessage(role: .user, content: question))
        inputText = ""
        isThinking = true

        let aiMessage = ChatMessage(role: .ai, content: "", isStreaming: true)
        let aiId = aiMessage.id
        messages.append(aiMessage)

        streamTask = Task {
            let stream = engine.askAboutTrends(
                question: question,
                history: history,
                healthMetrics: healthMetrics
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
}
