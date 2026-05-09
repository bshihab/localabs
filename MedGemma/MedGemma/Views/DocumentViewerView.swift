import SwiftUI
import Vision

/// Interactive document viewer that displays the original scanned image
/// with tappable text overlays. Users can select text and ask follow-up questions.
struct DocumentViewerView: View {
    let report: StructuredReport
    @EnvironmentObject var engine: InferenceEngine

    @State private var scanImages: [UIImage] = []
    @State private var pageBlocks: [[TextBlock]] = []
    @State private var currentPageIndex: Int = 0
    @State private var selectedBlocks: Set<UUID> = []
    @State private var showChat = false
    @State private var renderedImageSize: CGSize = .zero
    @State private var lassoPoints: [CGPoint] = []
    @State private var isLassoing = false
    @State private var showInteractionHint = false
    @State private var hintRingProgress: CGFloat = 0
    @State private var zoomScale: CGFloat = 1.0
    @State private var committedZoom: CGFloat = 1.0
    @Namespace private var glassNamespace

    struct TextBlock: Identifiable {
        let id = UUID()
        let text: String
        let boundingBox: CGRect // Normalized (0-1), bottom-left origin (Vision)
    }

    /// Current page's loaded image, if any.
    private var currentImage: UIImage? {
        guard scanImages.indices.contains(currentPageIndex) else { return nil }
        return scanImages[currentPageIndex]
    }

    /// Vision-recognized blocks for the page that's currently visible.
    /// Lasso hit-testing and overlay rendering use this — cross-page
    /// selections accumulate in `selectedBlocks` (UUID-keyed) but the
    /// gesture only compares against what's on screen right now.
    private var recognizedBlocks: [TextBlock] {
        guard pageBlocks.indices.contains(currentPageIndex) else { return [] }
        return pageBlocks[currentPageIndex]
    }

    /// Every recognized block across every page, used by the chat sheet to
    /// resolve a UUID-keyed selection back to text regardless of which
    /// page each selected block came from.
    private var allBlocks: [TextBlock] { pageBlocks.flatMap { $0 } }

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            if let image = currentImage {
                imageScroller(image: image)
                    .id(currentPageIndex) // force fresh layout on page change
            } else {
                emptyState
            }

            VStack(spacing: 8) {
                Spacer()
                if scanImages.count > 1 {
                    pageNavigation
                        .padding(.horizontal, 20)
                }
                askPill
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
            }

            if showInteractionHint {
                interactionHint
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    .allowsHitTesting(false) // taps pass through to the document
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
            loadAllPages()
        }
    }

    private func imageScroller(image: UIImage) -> some View {
        GeometryReader { geo in
            // Default zoom is 1.0× (image fits viewport width — Photos-style
            // initial state), and the user pinches to zoom in for detail.
            // The previous 1.5× default forced horizontal scrolling on every
            // open and couldn't be centered cleanly.
            let displayWidth = geo.size.width * zoomScale
            // Disable scroll while the user is actively lassoing OR when the
            // image fits entirely in the viewport (no scroll needed). At 1.0×
            // a portrait lab report typically fits horizontally but spills
            // vertically, so vertical scroll stays available.
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
                                    dismissHintIfShown()
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
            // Centers the document in the viewport on first appear (and
            // whenever zoom changes the content size) so the user isn't
            // looking at the left edge of an oversized page.
            .defaultScrollAnchor(.center)
            // Two-finger pinch — doesn't conflict with the single-finger
            // long-press lasso or scroll. Bounds 1.0× (fit) to 3.0× (read
            // tiny lab values clearly). Double-tap toggles between fit and
            // 2× as a quick zoom-in shortcut.
            .simultaneousGesture(zoomGesture)
            .onTapGesture(count: 2) {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    if zoomScale > 1.05 {
                        zoomScale = 1.0
                    } else {
                        zoomScale = 2.0
                    }
                    committedZoom = zoomScale
                }
            }
        }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let proposed = committedZoom * value.magnification
                zoomScale = min(max(proposed, 1.0), 3.0)
            }
            .onEnded { _ in
                committedZoom = zoomScale
            }
    }

    private var lassoGesture: some Gesture {
        // Long-press-then-drag.
        //   - minimumDuration: 0.18s. Short enough to feel responsive
        //     (previous 0.3s required a deliberate hold that felt finicky)
        //     but still distinguishable from a tap.
        //   - maximumDistance: 30pt. Default 10pt cancelled the long-press
        //     if the user's finger drifted slightly during the hold; 30pt
        //     is forgiving without false-triggering.
        //   - As soon as the long-press succeeds (transition into .second
        //     state, even before any drag value arrives) we lock the
        //     scroll view via isLassoing and fire a haptic so the user
        //     knows they've "engaged" lasso mode. This eliminates the
        //     small window where ScrollView could still grab the gesture.
        LongPressGesture(minimumDuration: 0.18, maximumDistance: 30)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                switch value {
                case .first:
                    // Long-press measurement in progress; do nothing yet.
                    break
                case .second(_, let drag):
                    if !isLassoing {
                        // Engage the moment long-press succeeds. Haptic
                        // confirms the mode change without UI noise.
                        isLassoing = true
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        dismissHintIfShown()
                    }
                    if let drag {
                        if lassoPoints.isEmpty {
                            lassoPoints = [drag.startLocation]
                        } else if let last = lassoPoints.last,
                                  hypot(drag.location.x - last.x, drag.location.y - last.y) > 4 {
                            // Throttle by minimum distance: keeps the path
                            // smooth and prevents SwiftUI from re-rendering
                            // for every sub-pixel move.
                            lassoPoints.append(drag.location)
                        }
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

    private func loadAllPages() {
        let urls = report.allImageURLs
        var images: [UIImage] = []
        for url in urls {
            if let data = try? Data(contentsOf: url),
               let image = UIImage(data: data) {
                images.append(image)
            }
        }
        scanImages = images
        // Pre-allocate per-page block arrays so OCR can fill them in place
        // without races while we navigate between pages.
        pageBlocks = Array(repeating: [], count: images.count)

        // OCR each page sequentially. Routes through VisionOCRService for
        // downscale + background-queue safety. With MedGemma 4B resident
        // in RAM, parallel OCR on N pages would court the same jetsam
        // crash we already fixed for the initial scan path.
        Task {
            for (idx, image) in images.enumerated() {
                let blocks = (try? await VisionOCRService.extractBlocks(from: image)) ?? []
                pageBlocks[idx] = blocks.map {
                    TextBlock(text: $0.text, boundingBox: $0.boundingBox)
                }
            }
        }

        // Tutorial hint shown every visit. Auto-dismisses after 6s or as
        // soon as the user touches anything (lasso engages or a block gets
        // tapped) — returning users barely see it before it fades, new
        // users still get the demo. No persistence; cheap to show.
        if !images.isEmpty {
            withAnimation(.easeOut(duration: 0.4)) {
                showInteractionHint = true
            }
            Task {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if showInteractionHint {
                    withAnimation(.easeOut(duration: 0.5)) {
                        showInteractionHint = false
                    }
                }
            }
        }
    }

    /// Animated tutorial overlay: a finger SF Symbol orbits a continuously-
    /// traced circle, mimicking the "press & hold then drag" lasso gesture.
    /// Uses `.symbolEffect(.pulse)` (Apple's built-in SF Symbol animation)
    /// for the finger, plus a custom Path.trim animation for the ring.
    /// Disappears on first interaction or after 6 seconds.
    private var interactionHint: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .trim(from: 0, to: hintRingProgress)
                    .stroke(
                        Color.blue.opacity(0.85),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: 92, height: 92)
                    .shadow(color: .blue.opacity(0.45), radius: 8)

                Image(systemName: "hand.point.up.left.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.blue)
                    .symbolEffect(.pulse, options: .repeat(.continuous))
                    .offset(
                        x: cos(hintRingProgress * 2 * .pi - .pi / 2) * 46,
                        y: sin(hintRingProgress * 2 * .pi - .pi / 2) * 46
                    )
            }

            Text("Press & hold, then drag to circle text")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)

            Text("Or tap any word to select it")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(22)
        .glassEffect(
            .regular.tint(.blue.opacity(0.10)),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .padding(.horizontal, 50)
        .onAppear {
            withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) {
                hintRingProgress = 1.0
            }
        }
    }

    /// Called whenever the user interacts in a way that proves they
    /// understand the gesture — dismisses the hint immediately.
    private func dismissHintIfShown() {
        guard showInteractionHint else { return }
        withAnimation(.easeOut(duration: 0.35)) {
            showInteractionHint = false
        }
    }

    private var pageNavigation: some View {
        HStack(spacing: 14) {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    currentPageIndex = max(0, currentPageIndex - 1)
                    lassoPoints = []
                    isLassoing = false
                    zoomScale = 1.0
                    committedZoom = 1.0
                }
            } label: {
                Image(systemName: "chevron.left.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(currentPageIndex == 0 ? Color.gray.opacity(0.4) : Color.blue)
            }
            .disabled(currentPageIndex == 0)

            Text("Page \(currentPageIndex + 1) of \(scanImages.count)")
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .frame(minWidth: 110)

            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    currentPageIndex = min(scanImages.count - 1, currentPageIndex + 1)
                    lassoPoints = []
                    isLassoing = false
                    zoomScale = 1.0
                    committedZoom = 1.0
                }
            } label: {
                Image(systemName: "chevron.right.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(
                        currentPageIndex == scanImages.count - 1
                            ? Color.gray.opacity(0.4)
                            : Color.blue
                    )
            }
            .disabled(currentPageIndex == scanImages.count - 1)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: Capsule())
    }

    private func convertRect(_ visionRect: CGRect, in size: CGSize) -> CGRect {
        let x = visionRect.origin.x * size.width
        let y = (1 - visionRect.origin.y - visionRect.height) * size.height
        let w = visionRect.width * size.width
        let h = visionRect.height * size.height
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func getSelectedText() -> String {
        // Empty selection → ask about the whole document. Hand the model
        // every page's text in order so it has full context.
        if selectedBlocks.isEmpty {
            return allBlocks.map(\.text).joined(separator: "\n")
        }
        let bd = lassoBreakdown
        switch (bd.table, bd.extraText.isEmpty) {
        case (let table?, true):
            return table.asMarkdown()
        case (let table?, false):
            return table.asMarkdown() + "\n\n" + bd.extraText
        case (nil, _):
            return bd.extraText.isEmpty
                ? allBlocks.filter { selectedBlocks.contains($0.id) }
                    .map(\.text).joined(separator: "\n")
                : bd.extraText
        }
    }

    /// Runs the table-vs-paragraph breakdown over the current lasso selection.
    /// Cross-page selections skip table detection because each page's
    /// blocks live in their own [0,1] normalized space — mixing coordinates
    /// would scramble row/column clustering. In that case we just emit the
    /// concatenated text and let the LLM read it as prose.
    private var lassoBreakdown: VisionOCRService.LassoBreakdown {
        guard !selectedBlocks.isEmpty else {
            return VisionOCRService.LassoBreakdown(table: nil, extraText: "")
        }
        let pagesWithSelections = pageBlocks.filter { page in
            page.contains { selectedBlocks.contains($0.id) }
        }
        if pagesWithSelections.count > 1 {
            // Cross-page selection — collapse to plain text, no table.
            let text = allBlocks.filter { selectedBlocks.contains($0.id) }
                .map(\.text).joined(separator: "\n")
            return VisionOCRService.LassoBreakdown(table: nil, extraText: text)
        }
        let selected = allBlocks
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

            // Explicit gray (idle) → blue (active) so the send button is
            // always legible. The previous .glassProminent style rendered
            // the disabled state nearly transparent against the chat
            // background.
            Button {
                sendMessage()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(canSend ? Color.blue : Color.gray.opacity(0.45))
                    .clipShape(Circle())
            }
            .disabled(!canSend)
            .animation(.easeInOut(duration: 0.2), value: canSend)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isThinking
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
