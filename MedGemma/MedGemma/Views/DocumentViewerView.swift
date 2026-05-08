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
            let bd = lassoBreakdown
            FollowUpChatView(
                selectedText: getSelectedText(),
                fullReportContext: report.patientSummary,
                ocrText: report.rawText,
                isWholeDocumentAsk: selectedBlocks.isEmpty,
                detectedTable: bd.table,
                extraText: bd.extraText
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
            // Render documents at 1.5× the natural fit-width so the user can
            // actually read small print. Lab reports are dense, and rendering
            // at exact viewport width was leaving body text unreadable. The
            // ScrollView is now 2-axis: horizontal pan if the scaled image
            // exceeds viewport width, vertical pan for tall documents.
            let displayWidth = geo.size.width * 1.5
            // Disable scroll for short single-page docs AND while the user is
            // actively lassoing — otherwise SwiftUI's ScrollView would steal
            // the drag and turn it into a pan instead of a selection.
            let fitsOnePage = renderedImageSize.height > 0
                && renderedImageSize.height <= geo.size.height
                && displayWidth <= geo.size.width
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: displayWidth)
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
        // Long-press-then-drag. On a 2-axis ScrollView, a plain DragGesture
        // gets eaten by the scroll view's pan recognizer before our gesture
        // can claim it. A short long-press (0.3s) wins over scroll: once
        // it succeeds we own the drag and can free-hand the lasso path.
        // Matches iOS's built-in "press and hold to enter selection mode"
        // pattern from Notes / Photos.
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                switch value {
                case .first:
                    // Long press completed without a drag yet. Could surface
                    // a haptic here; leaving silent for now to keep things calm.
                    break
                case .second(_, let drag):
                    guard let drag else { return }
                    if !isLassoing {
                        isLassoing = true
                        lassoPoints = [drag.startLocation]
                    }
                    // Throttle by minimum distance: keeps the path smooth and
                    // saves SwiftUI from re-rendering for every sub-pixel move.
                    if let last = lassoPoints.last,
                       hypot(drag.location.x - last.x, drag.location.y - last.y) > 4 {
                        lassoPoints.append(drag.location)
                    }
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
        // Hand the LLM both pieces when the selection has a table AND
        // surrounding paragraphs: markdown table first (reasons positionally),
        // then the prose. Either may be empty depending on what was lassoed.
        let bd = lassoBreakdown
        switch (bd.table, bd.extraText.isEmpty) {
        case (let table?, true):
            return table.asMarkdown()
        case (let table?, false):
            return table.asMarkdown() + "\n\n" + bd.extraText
        case (nil, _):
            return bd.extraText.isEmpty
                ? recognizedBlocks.filter { selectedBlocks.contains($0.id) }
                    .map(\.text).joined(separator: "\n")
                : bd.extraText
        }
    }

    /// Runs the table-vs-paragraph breakdown over the current lasso selection.
    /// Always returns a value (never nil); callers check `.table` and
    /// `.extraText` to decide what to render.
    private var lassoBreakdown: VisionOCRService.LassoBreakdown {
        guard !selectedBlocks.isEmpty else {
            return VisionOCRService.LassoBreakdown(table: nil, extraText: "")
        }
        let selected = recognizedBlocks
            .filter { selectedBlocks.contains($0.id) }
            .map { VisionOCRService.RecognizedBlock(text: $0.text, boundingBox: $0.boundingBox) }
        return VisionOCRService.breakdown(of: selected)
    }

    /// Convenience accessor for the table portion (used by the sheet).
    private var detectedTable: VisionOCRService.RecognizedTable? {
        lassoBreakdown.table
    }
}

// MARK: - Glowing lasso path

/// Plain-text card used by the chat banner. Rendered alongside (or instead
/// of) `DetectedTableBanner` depending on what the lasso captured. Title is
/// dynamic so we can say "Surrounding Text" when there's also a table, and
/// just "Selected Text" otherwise.
private struct ExtraTextBanner: View {
    let text: String
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "text.quote")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.blue)

            Text(text)
                .textSelection(.enabled)
                .font(.system(size: 14))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// Renders a `RecognizedTable` as an actual SwiftUI Grid in the chat banner.
/// Each cell is independently selectable so the user can copy a single value
/// out, and the first row is treated as a header (subtle background tint +
/// semibold) so reading reproduces the original table's hierarchy.
private struct DetectedTableBanner: View {
    let table: VisionOCRService.RecognizedTable

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "tablecells")
                    .font(.caption.weight(.semibold))
                Text("Detected Table")
                    .font(.caption.weight(.semibold))
                Text("· \(table.rowCount) row\(table.rowCount == 1 ? "" : "s") × \(table.columnCount) col\(table.columnCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.blue)

            // Horizontal scroll keeps wide tables readable without forcing
            // the chat sheet to expand.
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    ForEach(Array(table.rows.enumerated()), id: \.offset) { rowIdx, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(cell)
                                    .font(.system(size: 13, design: .rounded))
                                    .fontWeight(rowIdx == 0 ? .semibold : .regular)
                                    .foregroundStyle(rowIdx == 0 ? Color.primary : Color.secondary)
                                    .textSelection(.enabled)
                                    .padding(.vertical, 6)
                                    .padding(.horizontal, 8)
                                    .frame(minHeight: 28, alignment: .leading)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(rowIdx == 0 ? Color.blue.opacity(0.10) : Color.clear)
                                    )
                            }
                        }
                    }
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

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
    var detectedTable: VisionOCRService.RecognizedTable? = nil
    var extraText: String = ""
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
                    // Plain SF Symbol — the previous "Done" button under
                    // .glass style was rendering near-illegibly on iOS 26
                    // (looked like the letters "or"). chevron.backward with
                    // default tint reads as a back affordance immediately.
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.backward")
                            .font(.system(size: 18, weight: .semibold))
                    }
                }
            }
            .onAppear {
                if detectedTable != nil {
                    inputText = "Can you walk me through this table and explain what each value means in plain language?"
                } else if isWholeDocumentAsk {
                    inputText = "Can you summarize this report in plain language?"
                } else {
                    inputText = "What does this mean in simple terms? Is this normal?"
                }
                sendMessage()
            }
        }
    }

    @ViewBuilder
    private var selectionBanner: some View {
        if isWholeDocumentAsk {
            wholeDocumentBanner
        } else {
            // The lasso may have captured a table, paragraph text, or both.
            // Render whichever pieces are non-empty as separate banners so
            // the structure stays clear (table widget for the grid, plain
            // text card for the surrounding prose).
            VStack(alignment: .leading, spacing: 12) {
                if let table = detectedTable {
                    DetectedTableBanner(table: table)
                }
                if !extraText.isEmpty {
                    ExtraTextBanner(
                        text: extraText,
                        title: detectedTable != nil ? "Surrounding Text" : "Selected Text"
                    )
                }
                // Defensive fallback — only fires if both pieces were empty
                // (e.g., a single-block selection that's also too short for
                // the table heuristic). Keeps the banner non-empty so the
                // user always has visible context.
                if detectedTable == nil && extraText.isEmpty {
                    ExtraTextBanner(text: selectedText, title: "Selected Text")
                }
            }
        }
    }

    private var wholeDocumentBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Whole Document", systemImage: "doc.text")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.blue)
            Text("Asking about the entire scan.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
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
