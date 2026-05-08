import SwiftUI
import Vision

/// Interactive document viewer that displays the original scanned image
/// with tappable text overlays. Users can select text and ask follow-up questions.
struct DocumentViewerView: View {
    let report: StructuredReport
    @EnvironmentObject var engine: InferenceEngine

    @State private var scanImage: UIImage?
    @State private var recognizedBlocks: [TextBlock] = []
    @State private var selectedBlocks: Set<UUID> = []
    @State private var showChat = false
    @State private var renderedImageSize: CGSize = .zero
    @State private var lassoPoints: [CGPoint] = []
    @State private var isLassoing = false
    @Namespace private var glassNamespace

    struct TextBlock: Identifiable {
        let id = UUID()
        let text: String
        let boundingBox: CGRect // Normalized (0-1), bottom-left origin (Vision)
    }

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            if let image = scanImage {
                imageScroller(image: image)
            } else {
                emptyState
            }

            VStack {
                Spacer()
                askPill
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
            }
        }
        .navigationTitle("Scan Viewer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !selectedBlocks.isEmpty {
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            selectedBlocks.removeAll()
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                    }
                    .buttonStyle(.glass)
                }
            }
        }
        .sheet(isPresented: $showChat) {
            FollowUpChatView(
                selectedText: getSelectedText(),
                fullReportContext: report.patientSummary,
                ocrText: report.rawText,
                isWholeDocumentAsk: selectedBlocks.isEmpty
            )
            .environmentObject(engine)
            .presentationBackground(.thinMaterial)
            .presentationDragIndicator(.visible)
        }
        .onAppear {
            loadImage()
        }
    }

    private func imageScroller(image: UIImage) -> some View {
        GeometryReader { geo in
            // Disable scroll for single-page docs (the common case for lab reports)
            // AND while the user is actively drawing a lasso — otherwise SwiftUI's
            // ScrollView would steal the drag and turn it into a vertical pan.
            let fitsOnePage = renderedImageSize.height > 0
                && renderedImageSize.height <= geo.size.height
            ScrollView {
                ZStack(alignment: .topLeading) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width)
                        .background(
                            GeometryReader { imgGeo in
                                Color.clear
                                    .onAppear { renderedImageSize = imgGeo.size }
                                    .onChange(of: imgGeo.size) { _, new in renderedImageSize = new }
                            }
                        )

                    GlassEffectContainer(spacing: 4) {
                        ZStack(alignment: .topLeading) {
                            ForEach(recognizedBlocks) { block in
                                let rect = convertRect(block.boundingBox, in: renderedImageSize)
                                let isSelected = selectedBlocks.contains(block.id)

                                Group {
                                    if isSelected {
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(.clear)
                                            .glassEffect(
                                                .regular.tint(.yellow.opacity(0.55)).interactive(),
                                                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            )
                                            .glassEffectID(block.id, in: glassNamespace)
                                    } else {
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(Color.white.opacity(0.001))
                                    }
                                }
                                .frame(width: rect.width, height: rect.height)
                                .position(x: rect.midX, y: rect.midY)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                                        if isSelected {
                                            selectedBlocks.remove(block.id)
                                        } else {
                                            selectedBlocks.insert(block.id)
                                        }
                                    }
                                }
                            }
                        }
                        .frame(width: renderedImageSize.width, height: renderedImageSize.height)
                    }

                    // Lasso path - drawn in the same coordinate space as the
                    // image overlay grid so polygon hit-test against the
                    // recognized blocks lines up exactly.
                    if !lassoPoints.isEmpty {
                        LassoPath(points: lassoPoints)
                            .frame(width: renderedImageSize.width, height: renderedImageSize.height)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .gesture(lassoGesture)
                .padding(.bottom, 100)
            }
            .scrollDisabled(fitsOnePage || isLassoing)
        }
    }

    private var lassoGesture: some Gesture {
        // 8pt minimum — short taps still go to the per-block onTapGesture,
        // longer drags fall through to here.
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                if !isLassoing {
                    isLassoing = true
                    lassoPoints = [value.startLocation]
                }
                // Throttle by minimum distance: keeps the path smooth and
                // saves SwiftUI from re-rendering for every sub-pixel move.
                if let last = lassoPoints.last,
                   hypot(value.location.x - last.x, value.location.y - last.y) > 4 {
                    lassoPoints.append(value.location)
                }
            }
            .onEnded { _ in
                let polygon = lassoPoints
                let hitIDs: [UUID] = recognizedBlocks.compactMap { block in
                    let rect = convertRect(block.boundingBox, in: renderedImageSize)
                    let center = CGPoint(x: rect.midX, y: rect.midY)
                    return Self.pointInPolygon(center, polygon: polygon) ? block.id : nil
                }

                withAnimation(.spring(response: 0.4, dampingFraction: 0.78)) {
                    if !hitIDs.isEmpty {
                        selectedBlocks.formUnion(hitIDs)
                    }
                    lassoPoints = []
                    isLassoing = false
                }
            }
    }

    /// Standard ray-casting point-in-polygon test. Returns true if `point`
    /// is inside the closed polygon defined by `polygon`'s vertices (with
    /// implicit closing segment from last back to first).
    private static func pointInPolygon(_ point: CGPoint, polygon: [CGPoint]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let xi = polygon[i].x, yi = polygon[i].y
            let xj = polygon[j].x, yj = polygon[j].y
            if ((yi > point.y) != (yj > point.y)) &&
                (point.x < (xj - xi) * (point.y - yi) / (yj - yi) + xi) {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Original scan not available")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
    }

    private var askPill: some View {
        Button {
            showChat = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selectedBlocks.isEmpty ? "sparkles" : "highlighter")
                    .font(.system(size: 16, weight: .semibold))
                Text(askLabel)
                    .font(.system(size: 16, weight: .semibold))
                    .contentTransition(.opacity)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .animation(.easeInOut(duration: 0.25), value: selectedBlocks.count)
    }

    private var askLabel: String {
        if selectedBlocks.isEmpty {
            return "Ask about this document"
        }
        return selectedBlocks.count == 1
            ? "Elaborate on highlighted text"
            : "Elaborate on \(selectedBlocks.count) highlights"
    }

    private func loadImage() {
        guard let url = report.imageURL,
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else { return }

        scanImage = image

        // Route through VisionOCRService.extractBlocks so we get the same
        // downscale + background-queue safety as the initial scan path.
        // Running Vision on the raw stored JPEG (full sensor resolution)
        // while MedGemma 4B is still resident in RAM was getting this view
        // jetsam-killed the moment the user opened it.
        Task {
            let blocks = (try? await VisionOCRService.extractBlocks(from: image)) ?? []
            recognizedBlocks = blocks.map { TextBlock(text: $0.text, boundingBox: $0.boundingBox) }
        }
    }

    private func convertRect(_ visionRect: CGRect, in size: CGSize) -> CGRect {
        let x = visionRect.origin.x * size.width
        let y = (1 - visionRect.origin.y - visionRect.height) * size.height
        let w = visionRect.width * size.width
        let h = visionRect.height * size.height
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func getSelectedText() -> String {
        // Empty selection → ask about the whole document. Hand the model the
        // full OCR text so it has something to anchor the answer to.
        if selectedBlocks.isEmpty {
            return recognizedBlocks.map(\.text).joined(separator: "\n")
        }
        return recognizedBlocks
            .filter { selectedBlocks.contains($0.id) }
            .map(\.text)
            .joined(separator: "\n")
    }
}

// MARK: - Glowing lasso path

/// Soft blue glowing stroke. Drawn on top of the document while the user
/// is dragging — single color so it doesn't fight the document for visual
/// weight.
private struct LassoPath: View {
    let points: [CGPoint]

    var body: some View {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            for p in points.dropFirst() {
                path.addLine(to: p)
            }
        }
        .stroke(
            Color.blue.opacity(0.9),
            style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
        )
        .shadow(color: .blue.opacity(0.45), radius: 6)
    }
}

// MARK: - Follow-Up Chat View

struct FollowUpChatView: View {
    let selectedText: String
    let fullReportContext: String
    let ocrText: String
    var isWholeDocumentAsk: Bool = false
    @EnvironmentObject var engine: InferenceEngine
    @Environment(\.dismiss) var dismiss

    @State private var messages: [ChatMessage] = []
    @State private var inputText = ""
    @State private var isThinking = false

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
                            selectionBanner
                                .padding(.horizontal)
                                .padding(.top, 8)

                            ForEach(messages) { message in
                                messageRow(message: message)
                                    .id(message.id)
                            }

                            if isThinking {
                                HStack(spacing: 10) {
                                    Image(systemName: "brain.head.profile")
                                        .font(.system(size: 18))
                                        .foregroundStyle(.blue)
                                    ProgressView()
                                    Text("Thinking…")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal)
                            }
                        }
                        .padding(.vertical)
                    }
                    .scrollContentBackground(.hidden)
                    .onChange(of: messages.count) { _, _ in
                        if let last = messages.last {
                            withAnimation(.easeOut(duration: 0.3)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }

                inputBar
            }
            .background(Color.clear)
            .navigationTitle("Ask MedGemma")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .buttonStyle(.glass)
                }
            }
            .onAppear {
                inputText = isWholeDocumentAsk
                    ? "Can you summarize this report in plain language?"
                    : "What does this mean in simple terms? Is this normal?"
                sendMessage()
            }
        }
    }

    private var selectionBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                isWholeDocumentAsk ? "Whole Document" : "Selected Text",
                systemImage: isWholeDocumentAsk ? "doc.text" : "text.quote"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(.blue)

            if isWholeDocumentAsk {
                Text("Asking about the entire scan.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            } else {
                Text(selectedText)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func messageRow(message: ChatMessage) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if message.role == .ai {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 20))
                    .foregroundStyle(.blue)
                    .padding(.top, 6)
            }

            Text(message.content)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                // maxWidth without alignment caps wrapping at 280pt but lets
                // the bubble shrink to fit short messages. The previous
                // alignment parameter forced the bubble to a full 280pt and
                // glued short text to one edge, leaving a big empty side.
                .frame(maxWidth: 280)
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

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Ask about this text…", text: $inputText, axis: .vertical)
                .lineLimit(1...4)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .glassEffect(.regular, in: Capsule())

            Button {
                sendMessage()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.glassProminent)
            .clipShape(Circle())
            .disabled(inputText.isEmpty || isThinking)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func sendMessage() {
        let question = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }

        // Snapshot prior completed turns BEFORE appending the new user message
        // and the empty AI placeholder.
        let history: [InferenceEngine.ChatTurn] = messages.map {
            InferenceEngine.ChatTurn(isUser: $0.role == .user, content: $0.content)
        }

        messages.append(ChatMessage(role: .user, content: question))
        inputText = ""
        isThinking = true

        let aiMessage = ChatMessage(role: .ai, content: "", isStreaming: true)
        let aiId = aiMessage.id
        messages.append(aiMessage)

        Task {
            let stream = engine.askFollowUp(
                question: question,
                history: history,
                selectedText: selectedText,
                reportContext: fullReportContext,
                ocrText: ocrText
            )
            var receivedFirstPiece = false
            for await piece in stream {
                if !receivedFirstPiece {
                    isThinking = false
                    receivedFirstPiece = true
                }
                if let idx = messages.firstIndex(where: { $0.id == aiId }) {
                    messages[idx].content += piece
                }
            }
            isThinking = false
            if let idx = messages.firstIndex(where: { $0.id == aiId }) {
                messages[idx].isStreaming = false
            }
        }
    }
}
