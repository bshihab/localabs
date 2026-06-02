import SwiftUI
import UIKit
import Vision

/// Interactive document viewer that displays the original scanned image
/// with tappable text overlays. Users can select text and ask follow-up questions.
struct DocumentViewerView: View {
    let report: StructuredReport
    @EnvironmentObject var engine: InferenceEngine

    /// Open directly on a specific page. The dashboard's swipeable scan
    /// preview passes the page the user tapped so the viewer lands on
    /// the same page they were looking at, rather than snapping to page 1.
    init(report: StructuredReport, initialPage: Int = 0) {
        self.report = report
        _currentPageIndex = State(initialValue: max(0, initialPage))
    }

    @State private var scanImages: [UIImage] = []
    @State private var pageBlocks: [[TextBlock]] = []
    @State private var currentPageIndex: Int = 0
    @State private var selectedBlocks: Set<UUID> = []
    @State private var showChat = false
    @State private var renderedImageSize: CGSize = .zero
    @State private var lassoPoints: [CGPoint] = []
    @State private var isLassoing = false
    @State private var showInteractionHint = false
    /// Direction of the last page navigation, so the page slide
    /// transition moves the right way (forward = new page enters from
    /// the trailing edge).
    @State private var pageNavForward = true
    @State private var mode: ViewerMode = .browse
    /// Drives the floating "you have selections on other pages"
    /// banner. Auto-shows on page change + on every new selection
    /// while in Select mode, as long as some OTHER page has at
    /// least one selected block. Dismisses on tap; reappears the
    /// next time the selection set or current page changes.
    @State private var showCrossPageBanner = false
    @Namespace private var glassNamespace

    /// Two explicit interaction modes — replaces the long-press-to-engage
    /// pattern that kept fighting with scroll. Browse is the default
    /// (Photos-style: drag to scroll, pinch to zoom, tap-to-select still
    /// works for precision). Select disables scroll and turns plain drag
    /// into the lasso path.
    enum ViewerMode {
        case browse, select
    }

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

    /// One-based page numbers of every OTHER page (i.e. not the page
    /// currently displayed) that has at least one selected block.
    /// Drives the cross-page reminder banner — without it, users
    /// would flip between pages, make new selections, and forget
    /// that earlier-page selections were still part of the bundle
    /// they'd be asking Localabs about.
    private var otherPagesWithSelections: [Int] {
        pageBlocks.enumerated().compactMap { idx, blocks in
            guard idx != currentPageIndex else { return nil }
            return blocks.contains(where: { selectedBlocks.contains($0.id) }) ? idx + 1 : nil
        }
    }

    /// Human-readable list of page numbers: "page 3", "pages 3 and
    /// 4", "pages 3, 4, and 5". Used inside the banner body so the
    /// copy reads naturally regardless of how many pages have
    /// selections.
    private func formatPageList(_ pages: [Int]) -> String {
        guard !pages.isEmpty else { return "" }
        if pages.count == 1 { return "page \(pages[0])" }
        if pages.count == 2 { return "pages \(pages[0]) and \(pages[1])" }
        let head = pages.dropLast().map(String.init).joined(separator: ", ")
        return "pages \(head), and \(pages.last!)"
    }

    /// Every recognized block across every page, used by the chat sheet to
    /// resolve a UUID-keyed selection back to text regardless of which
    /// page each selected block came from.
    private var allBlocks: [TextBlock] { pageBlocks.flatMap { $0 } }

    var body: some View {
        mainContent
            .navigationTitle("Scan Viewer")
            .navigationBarTitleDisplayMode(.inline)
            .sensoryFeedback(.impact(weight: .medium), trigger: isLassoing) { old, new in
                lassoStarted(oldValue: old, newValue: new)
            }
            .onChange(of: currentPageIndex) { _, _ in evaluateCrossPageBanner() }
            .onChange(of: selectedBlocks) { _, _ in evaluateCrossPageBanner() }
            .onChange(of: mode) { _, newMode in handleModeChange(newMode) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                topTrailingToolbarContent
            }
        }
        .sheet(isPresented: $showChat) {
            followUpChatSheet
            .presentationBackground(.thinMaterial)
            .presentationDragIndicator(.visible)
            // Without this, the sheet's pull-to-dismiss gesture wins over
            // the chat ScrollView's scroll — every time you tried to scroll
            // up through the chat, the sheet itself would drag down toward
            // dismissal. .scrolls tells iOS to let the inner ScrollView
            // handle scrolls first; the sheet only dismisses when the user
            // grabs the drag indicator at the top.
            .presentationContentInteraction(.scrolls)
        }
        .onAppear {
            loadAllPages()
        }
    }

    private func imageScroller(image: UIImage) -> some View {
        GeometryReader { geo in
            // The whole document — image + selection overlays + lasso path —
            // lives inside a UIScrollView (via ZoomablePanContainer). UIKit
            // handles pan + pinch natively, including pan-while-pinching,
            // so we no longer have to lock scroll during zoom or apply
            // .frame(width:) hacks to drive zoom from SwiftUI state.
            //
            // Browse mode → isScrollEnabled = true (UIScrollView pans + zooms).
            // Select mode → isScrollEnabled = false (single-finger drag goes
            //               to the embedded lasso gesture; pinch still works
            //               because pinch is two-finger and untouched by
            //               isScrollEnabled).
            //
            // resetZoomTrigger flips zoom back to 1.0 each time the user
            // navigates to a different page so each page opens at fit.
            ZoomablePanContainer(
                isScrollEnabled: mode == .browse,
                resetZoomTrigger: currentPageIndex
            ) {
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
                                    // Tap-to-select is Select-mode only.
                                    // Without this gate, taps in Browse
                                    // mode flipped selection state too,
                                    // which let users accidentally select
                                    // blocks while just panning around
                                    // the scan.
                                    guard mode == .select else { return }
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

                    // Lasso path drawn in the same coordinate space as the
                    // overlay grid. UIScrollView's transform scales both
                    // together so hit-tests still line up at any zoom.
                    if !lassoPoints.isEmpty {
                        LassoPath(points: lassoPoints)
                            .frame(width: renderedImageSize.width, height: renderedImageSize.height)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                // Lasso gesture only fires in Select mode. In Browse mode
                // .none disables it so the UIScrollView pan recognizer
                // owns single-finger drags.
                .gesture(lassoGesture, including: mode == .select ? .all : .none)
            }
        }
    }

    private var lassoGesture: some Gesture {
        // Plain drag — no long-press dance needed because we're already in
        // Select mode (gated via .gesture(_:including:) on the parent).
        // ScrollView is disabled in Select mode, so drags can't be stolen.
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isLassoing {
                    isLassoing = true
                    lassoPoints = [value.startLocation]
                    // Haptic intentionally NOT triggered here — the
                    // inline `UIImpactFeedbackGenerator(...).impactOccurred()`
                    // pattern fires from a cold engine and lands ~1s
                    // late. The view's `.sensoryFeedback(_:trigger:)`
                    // modifier watches `isLassoing` and fires the
                    // impact immediately (it keeps the haptic engine
                    // warm in the background).
                    dismissHintIfShown()
                } else if let last = lassoPoints.last,
                          hypot(value.location.x - last.x, value.location.y - last.y) > 4 {
                    // Throttle by minimum distance: keeps the path smooth
                    // and prevents SwiftUI re-renders for sub-pixel moves.
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

    /// Two-button mode selector at the top of the screen. Browse vs Select.
    /// Each button is its own Liquid Glass capsule; the active one carries
    /// a blue tint. Wrapping in a GlassEffectContainer groups the two
    /// glass effects so iOS 26's continuous-glass rendering treats them
    /// as a coordinated pair rather than two separate floating elements.
    private var modeToggle: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 4) {
                modeButton(.browse, label: "Browse", icon: "hand.draw")
                modeButton(.select, label: "Select", icon: "lasso")
            }
        }
    }

    private func modeButton(_ targetMode: ViewerMode, label: String, icon: String) -> some View {
        let isActive = mode == targetMode
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                mode = targetMode
                lassoPoints = []
                isLassoing = false
            }
            dismissHintIfShown()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                Text(label)
                    .font(.system(size: 14, weight: .semibold))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .frame(minWidth: 100)
            .foregroundStyle(isActive ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .glassEffect(
            isActive
                ? .regular.tint(.blue.opacity(0.85)).interactive()
                : .regular.interactive(),
            in: Capsule()
        )
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

    /// Main ZStack content. Extracted so the body expression
    /// stays trivially type-checkable — the previous inline form
    /// (ZStack + 3 chained .onChange closures + .toolbar with a
    /// nested ToolbarItem + .sheet with the FollowUpChatView
    /// constructor) pushed Swift past its inference budget every
    /// time we added another small subview. Each piece of UI is
    /// already its own named view (imageScroller, emptyState,
    /// bottomControlsStack, interactionHint), so the ZStack here
    /// is just composition — fast to infer.
    private var mainContent: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            if let image = currentImage {
                imageScroller(image: image)
                    .id(currentPageIndex) // force fresh layout on page change
                    // Slide pages in from the side the user navigated
                    // toward, so arrow taps feel like the fluid paging on
                    // the dashboard preview rather than an instant swap.
                    .transition(.asymmetric(
                        insertion: .move(edge: pageNavForward ? .trailing : .leading),
                        removal: .move(edge: pageNavForward ? .leading : .trailing)
                    ))
            } else {
                emptyState
            }

            bottomControlsStack

            if showInteractionHint {
                // Transparent layer above the document: the first touch
                // anywhere dismisses the tutorial ("touch to begin"),
                // then it's gone and the document gets all subsequent
                // touches. Catches taps AND the start of a drag.
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { dismissHintIfShown() }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in dismissHintIfShown() }
                    )

                interactionHint
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    .allowsHitTesting(false) // the scrim above handles dismissal
            }
        }
    }

    /// Predicate for the lasso-start haptic. Pulled out of the
    /// .sensoryFeedback closure because returning Bool from inside
    /// a complex view-builder closure was contributing to the
    /// "can't type-check" error.
    private func lassoStarted(oldValue: Bool, newValue: Bool) -> Bool {
        newValue && !oldValue
    }

    /// Handles the Browse / Select mode toggle's side-effects on
    /// the cross-page banner. Inlining this as a closure inside
    /// .onChange added enough complexity to push the body past
    /// Swift's type-inference budget.
    private func handleModeChange(_ newMode: ViewerMode) {
        if newMode == .browse {
            withAnimation(.easeOut(duration: 0.2)) {
                showCrossPageBanner = false
            }
        } else {
            evaluateCrossPageBanner()
        }
    }

    /// Top-trailing toolbar items — wand for auto-select-table
    /// plus the conditional clear-selection X. Extracted so the
    /// main body's `.toolbar` modifier stays tiny enough for
    /// Swift's type inference. The behavior is identical to the
    /// previous inline version.
    private var topTrailingToolbarContent: some View {
        HStack(spacing: 8) {
            Button {
                autoSelectTableOnCurrentPage()
            } label: {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 18))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Auto-select table on this page")
            .disabled(recognizedBlocks.isEmpty)

            if !selectedBlocks.isEmpty {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        selectedBlocks.removeAll()
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary, .tertiary)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear selection")
            }
        }
    }

    /// Follow-up chat sheet content. Pulled out of the inline
    /// `.sheet { ... }` closure on the body so Swift's type
    /// inference doesn't have to chew through the whole
    /// FollowUpChatView constructor + chained presentation
    /// modifiers as part of the body expression.
    private var followUpChatSheet: some View {
        let bd = lassoBreakdown
        return FollowUpChatView(
            reportID: report.id,
            selectedText: getSelectedText(),
            fullReportContext: report.patientSummary,
            ocrText: report.rawText,
            isWholeDocumentAsk: selectedBlocks.isEmpty,
            detectedTable: bd.table,
            extraText: bd.extraText
        )
        .environmentObject(engine)
    }

    /// Extracted from `body` because the original ZStack was too
    /// dense for Swift's type inference (the conditional banner +
    /// conditional page-nav + ask-pill chained inside a VStack
    /// inside a ZStack with `.gesture` and `.toolbar` modifiers
    /// tripped a "compiler can't type-check in reasonable time"
    /// error). Splitting it out keeps each builder closure small
    /// enough to infer quickly.
    private var bottomControlsStack: some View {
        VStack(spacing: 8) {
            modeToggle
                .padding(.top, 8)
            Spacer()
            if showCrossPageBanner && !otherPagesWithSelections.isEmpty {
                crossPageBanner
                    .padding(.horizontal, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if scanImages.count > 1 {
                pageNavigation
                    .padding(.horizontal, 20)
            }
            askPill
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
        }
    }

    /// Glass banner that surfaces when the user is on a page with
    /// no selections on it, but earlier-visited pages still have
    /// selections in the bundle. Tap to dismiss; the underlying
    /// onChange handlers re-show it on the next state change.
    private var crossPageBanner: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) {
                showCrossPageBanner = false
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "highlighter")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 1) {
                    Text("You have selections on \(formatPageList(otherPagesWithSelections))")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("Tap to dismiss")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// Re-evaluates whether the cross-page banner should show.
    /// Two gates: must be in Select mode (banner is useless in
    /// Browse), and there must be at least one other page with
    /// selections. Setting the flag inside an animation gives the
    /// banner the slide-up appearance the user expects.
    private func evaluateCrossPageBanner() {
        let shouldShow = mode == .select && !otherPagesWithSelections.isEmpty
        withAnimation(.easeOut(duration: 0.25)) {
            showCrossPageBanner = shouldShow
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

    /// Animated tutorial overlay. A finger smoothly traces a rounded
    /// rectangle around a couple of mock lab rows, then the enclosed
    /// rows highlight — looping. Shows the lasso-to-select gesture far
    /// more concretely than a finger orbiting an empty circle did.
    /// Disappears on first touch (handled by the scrim in mainContent)
    /// or after 6 seconds.
    private var interactionHint: some View {
        VStack(spacing: 16) {
            LassoDemoView()

            Text("Drag to circle any values")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)

            Text("Then ask Localabs about them — or tap a single word")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(22)
        .glassEffect(
            .regular.tint(.blue.opacity(0.10)),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .padding(.horizontal, 50)
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
                pageNavForward = false
                withAnimation(.smooth(duration: 0.42)) {
                    currentPageIndex = max(0, currentPageIndex - 1)
                    lassoPoints = []
                    isLassoing = false
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
                pageNavForward = true
                withAnimation(.smooth(duration: 0.42)) {
                    currentPageIndex = min(scanImages.count - 1, currentPageIndex + 1)
                    lassoPoints = []
                    isLassoing = false
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

    /// Runs the table detector against every block on the current page
    /// and auto-selects the blocks that form the detected table.
    /// Equivalent to the user manually lassoing the table, but available
    /// from the toolbar so they don't have to circle.
    private func autoSelectTableOnCurrentPage() {
        let pageBlocksOnPage = recognizedBlocks
        guard !pageBlocksOnPage.isEmpty else { return }

        let serviceBlocks = pageBlocksOnPage.map {
            VisionOCRService.RecognizedBlock(text: $0.text, boundingBox: $0.boundingBox)
        }
        let breakdown = VisionOCRService.breakdown(of: serviceBlocks)
        guard breakdown.table != nil else {
            // No table-shaped region on this page — nothing to select.
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }

        // The breakdown ran over the deduped *positions* of the page's
        // RecognizedBlocks, but we need to map those positions back to our
        // TextBlock UUIDs to flip them into selectedBlocks. Match by
        // bounding-box equality since each block's boundingBox is unique
        // within the page.
        let tableBoxes = Set(serviceBlocks.compactMap { sb -> CGRect? in
            // Only blocks NOT in the extraText make it into the table.
            // breakdown.extraText is the prose; the rest is the table.
            // We re-run the algorithm to get the table-block positions.
            return sb.boundingBox
        })

        // Easier path: re-derive which blocks are in the table by running
        // the algorithm directly. For each TextBlock on this page, ask
        // whether the breakdown classified its text as part of the table.
        // Simpler: select every block whose text appears in any cell of
        // the detected table.
        let tableTexts: Set<String> = Set(breakdown.table?.rows.flatMap { $0 }.filter { !$0.isEmpty } ?? [])
        var newSelections = Set<UUID>()
        for block in pageBlocksOnPage where tableBoxes.contains(block.boundingBox) {
            // A block belongs to the table if its text is contained in
            // any joined-cell value. (Cells may be the concatenation of
            // multiple blocks, so use contains rather than equals.)
            let blockText = block.text
            if tableTexts.contains(where: { $0.contains(blockText) }) {
                newSelections.insert(block.id)
            }
        }
        guard !newSelections.isEmpty else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }

        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            selectedBlocks.formUnion(newSelections)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismissHintIfShown()
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
                            let isHeader = rowIdx == table.headerRowIndex
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(cell)
                                    .font(.system(size: 13, design: .rounded))
                                    .fontWeight(isHeader ? .semibold : .regular)
                                    .foregroundStyle(isHeader ? Color.primary : Color.secondary)
                                    .textSelection(.enabled)
                                    .padding(.vertical, 6)
                                    .padding(.horizontal, 8)
                                    .frame(minHeight: 28, alignment: .leading)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(isHeader ? Color.blue.opacity(0.10) : Color.clear)
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
    /// The scan this chat belongs to. Drives ChatHistoryService:
    /// the sheet loads any prior conversation about this report on
    /// `.task` and persists every completed turn so reopening the
    /// scan later picks the chat up where it left off. Per-document
    /// chats are scoped to a real saved scan (which lives forever
    /// in History until explicitly deleted), unlike Trends and
    /// Metric chats whose underlying data is a rolling window.
    let reportID: UUID
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
    /// Drives the "+" quick-add-to-profile sheet shown from the
    /// chat input bar. Replaced the previous auto-detection
    /// pipeline (regex scanner + model `[PROFILE_ADD: …]` signals
    /// + popup alerts) which was too unreliable to be worth the
    /// interruptions.
    @State private var showQuickAddSheet = false
    /// HealthKit averages fetched once at sheet-open time, then
    /// reused for every send. Pre-fetching aligns FollowUpChatView
    /// with TrendsChatView (which already received metrics from its
    /// parent) — fetching fresh inside each send Task occasionally
    /// hung indefinitely if one of the seven concurrent HKQueries
    /// didn't return, leaving the chat stuck on typing dots forever.
    /// Empty `HealthMetrics()` is a safe placeholder until the real
    /// values land via `.task` below.
    @State private var healthMetrics: HealthKitService.HealthMetrics = HealthKitService.HealthMetrics()
    /// Drives the "Clear this chat?" confirmation. Tapping the
    /// trash icon in the top toolbar sets this true; the
    /// confirmation dialog then commits or cancels the wipe.
    @State private var showClearChatConfirm = false
    /// Reference to the in-flight streaming Task so we can cancel
    /// it if the user dismisses the sheet mid-stream. Without this,
    /// the llama.cpp predict loop kept generating tokens after the
    /// sheet closed — you could feel each whitespace token's haptic
    /// even though there was no visible bubble to update.
    @State private var sendTask: Task<Void, Never>?

    struct ChatMessage: Identifiable, Equatable {
        // Explicit init (instead of an inline `let id = UUID()`
        // default) so callers can pass a specific UUID when
        // hydrating from ChatHistoryService — Swift's synthesized
        // memberwise initializer drops `let` properties that have
        // inline defaults, which made `ChatMessage(id: …, role:
        // …, content: …)` fail to compile during chat restore.
        let id: UUID
        let role: Role
        var content: String
        var isStreaming: Bool

        enum Role { case user, ai }

        init(id: UUID = UUID(), role: Role, content: String, isStreaming: Bool = false) {
            self.id = id
            self.role = role
            self.content = content
            self.isStreaming = isStreaming
        }
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

                            // Intro card + suggested starter questions.
                            // No auto-fire on appear anymore — the
                            // previous behavior (which immediately
                            // sent "Can you summarize this report?")
                            // was hitting a race where the engine
                            // wasn't always ready in time, leaving
                            // the chat hanging on an empty bubble.
                            // Users now see a clear "what this is"
                            // header + tappable starter questions and
                            // pick whichever they want.
                            if messages.isEmpty {
                                emptyStateHeader
                                    .padding(.horizontal)

                                starterChips
                                    .padding(.horizontal)
                                    .padding(.bottom, 4)
                            }

                            ForEach(messages) { message in
                                messageRow(message: message)
                                    .id(message.id)
                            }
                        }
                        .padding(.vertical)
                    }
                    .scrollContentBackground(.hidden)
                    // Keyboard follows the user's scroll: starts to drop the
                    // moment they begin scrolling and tracks their finger
                    // until released. Standard iOS Messages / Mail behavior
                    // — keyboard only comes back when they tap the input
                    // field again.
                    .scrollDismissesKeyboard(.interactively)
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
            .sheet(isPresented: $showQuickAddSheet) {
                ProfileQuickAddSheet(prefilledValue: inputText)
            }
            .task {
                // Pre-fetch HealthKit metrics ONCE when the sheet
                // opens, instead of inside every send Task. If any
                // single HKQuery hangs, this puts the wait at sheet-
                // open time (with the UI still responsive) rather
                // than at message-send time (where the chat would
                // get stuck on typing dots).
                healthMetrics = await HealthKitService.shared.getHealthMetrics()
            }
            .onAppear {
                // Hydrate the conversation from disk if the user
                // chatted about this report before. Empty array
                // means it's a fresh chat — the starter chips + intro
                // header still render via the `messages.isEmpty`
                // branch below.
                loadPersistedMessages()
            }
            .onDisappear {
                // Sheet is going away — stop the in-flight stream
                // immediately. Cancellation propagates through the
                // for-await loop's `Task.isCancelled` check, then
                // down into LlamaContext via the AsyncStream's
                // onTermination handler, halting token generation
                // at the model's next safe checkpoint. Without this,
                // the predict loop kept running after dismiss and
                // the haptic kept firing on every whitespace token.
                sendTask?.cancel()
                sendTask = nil
                isThinking = false
                if let idx = messages.firstIndex(where: { $0.isStreaming }) {
                    messages[idx].isStreaming = false
                    persistMessages()
                }
            }
            .navigationTitle("Ask Localabs")
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
                // Clear-chat trash icon, top trailing. Only renders
                // when there's a conversation to clear — keeps the
                // empty state uncluttered. Tap routes through a
                // confirmation dialog so an errant tap doesn't wipe
                // a long thread.
                if !messages.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showClearChatConfirm = true
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.red)
                        }
                        .accessibilityLabel("Clear conversation")
                    }
                }
            }
            // Confirmation dialog instead of an alert — matches the
            // History single-row delete pattern; slides up from the
            // bottom anchored to the trash tap rather than appearing
            // as a centered modal.
            .confirmationDialog(
                "Clear this conversation?",
                isPresented: $showClearChatConfirm,
                titleVisibility: .visible
            ) {
                Button("Clear Conversation", role: .destructive) {
                    clearConversation()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes every message in this chat — the empty starter prompts come back. The original scan and its analysis stay untouched.")
            }
        }
    }

    /// Wipes the in-memory chat AND its persisted copy, returning
    /// the sheet to its fresh-conversation state (empty-state header
    /// + starter chips). The scan itself and its analysis are
    /// untouched — this only resets the conversational history.
    private func clearConversation() {
        withAnimation(.easeOut(duration: 0.2)) {
            messages.removeAll()
        }
        ChatHistoryService.clear(for: reportID)
    }

    /// Same shape language as TrendsChatView's intro card. Explains
    /// what this chat does so users don't have to guess.
    private var emptyStateHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 20))
                    .foregroundStyle(.yellow)
                Text("Asks about your selected text")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            Text("Localabs answers questions about the part of the lab report you highlighted, with the rest of your scan, profile, and recent Apple Health data as background context.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// Starter questions shaped to the user's selection — table,
    /// whole document, or arbitrary text — so the first prompt is
    /// always something they could plausibly want to ask.
    private var starterChips: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Try asking:")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)

            VStack(spacing: 6) {
                ForEach(starterQuestions, id: \.self) { question in
                    Button {
                        inputText = question
                        sendMessage()
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

    private var starterQuestions: [String] {
        if detectedTable != nil {
            return [
                "Walk me through this table — what does each value mean?",
                "Which values here are outside the normal range?",
                "How do these results connect to my recent Apple Health data?"
            ]
        }
        if isWholeDocumentAsk {
            return [
                "Summarize this report in plain language.",
                "What are the top 3 things I should ask my doctor about?",
                "Are there any concerning values I should know about?"
            ]
        }
        return [
            "What does this mean in simple terms? Is this normal?",
            "How does this value relate to my health profile?",
            "Should I bring this up with my doctor?"
        ]
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

    @ViewBuilder
    private func messageRow(message: ChatMessage) -> some View {
        // Empty streaming AI bubble = "waiting for first token".
        // Show the iMessage-style typing dots inline so the user
        // gets the familiar "they're typing" affordance, not a
        // generic spinner. Replaced the old separate "Thinking…"
        // row that used to render above the messages — putting
        // the indicator inside the bubble keeps spatial continuity
        // when the dots flip to actual content.
        if message.role == .ai && message.isStreaming && message.content.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "brain.head.profile")
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
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 20))
                    .foregroundStyle(.blue)
                    .padding(.top, 6)
            }

            // MarkdownBody handles **bold**, *italic*, bullets (- ), and
            // markdown tables (| col | col |) — same renderer the dashboard
            // uses, so chat output formats consistently with the report
            // sections instead of showing literal `**` characters.
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

    private var inputBar: some View {
        HStack(spacing: 10) {
            // "+ to profile" button — opens the manual quick-add
            // sheet pre-filled with whatever's currently typed.
            // Replaces the previous auto-detection feature; the
            // user is now in explicit control of what gets saved.
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

            TextField("Ask about this text…", text: $inputText, axis: .vertical)
                .lineLimit(1...4)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                // Fixed radius instead of Capsule so the field doesn't
                // over-round and clip text as it grows to multiple lines.
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

            // Liquid glass send button. Active state tints blue so
            // it reads as "primary action" while still feeling like
            // glass; disabled state drops the tint so it dims but
            // stays in the glass family.
            Button {
                sendMessage()
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

        // Hold the streaming Task in @State so `.onDisappear` (or
        // any cancellation path) can stop it. Without this, dismissing
        // the sheet mid-stream left llama.cpp generating tokens
        // against a torn-down view — the user felt every word-
        // boundary haptic with no visible bubble updating.
        sendTask = Task {
            // Use the snapshot pre-fetched in `.task` at sheet-open
            // time. Fetching inside this Task was the source of the
            // "chat hangs forever on typing dots" bug — one of the
            // 7 concurrent HKQueries could fail to return its
            // continuation, and the whole send would stall waiting.
            // Look up whose report this is, fresh, so a report marked
            // "someone else's" (e.g. a parent's) is discussed in
            // isolation — no other reports, no Apple Health, no profile.
            let isOwn = LocalStorageService.shared.getHistory()
                .first(where: { $0.id == reportID })?.isOwnReport ?? true
            let stream = engine.askFollowUp(
                question: question,
                history: history,
                selectedText: selectedText,
                reportContext: fullReportContext,
                ocrText: ocrText,
                healthMetrics: healthMetrics,
                isOwnReport: isOwn
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
                // Exit the loop the moment the parent Task is
                // cancelled — happens on sheet dismiss via
                // `sendTask?.cancel()` in `.onDisappear`.
                // Cancelling the consumer also triggers the
                // AsyncStream's onTermination, which propagates the
                // cancel down to LlamaContext.predict's detached
                // task and stops token generation at its next
                // safe checkpoint.
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
            isThinking = false
            if let idx = messages.firstIndex(where: { $0.id == aiId }) {
                messages[idx].isStreaming = false
            }
            // Persist the full conversation so reopening this scan
            // later restores the chat. Saving here (rather than per-
            // chunk) means we always write a stable, completed-turn
            // snapshot — never a half-streamed AI message.
            persistMessages()
        }
    }

    /// Loads the saved conversation for `reportID` and converts the
    /// persisted form back into in-memory ChatMessage rows. Called
    /// on `.onAppear` so reopening a scan picks the chat up where
    /// the user left off.
    private func loadPersistedMessages() {
        let stored = ChatHistoryService.messages(for: reportID)
        guard !stored.isEmpty else { return }
        messages = stored.map { persisted in
            ChatMessage(
                id: persisted.id,
                role: persisted.role == .user ? .user : .ai,
                content: persisted.content,
                isStreaming: false
            )
        }
    }

    /// Writes the current conversation to disk. Called after every
    /// completed AI turn so the on-disk copy is always current —
    /// if the app gets killed mid-session, the chat up to the last
    /// completed turn survives.
    private func persistMessages() {
        let toSave = messages.map { msg in
            PersistedChatMessage(
                id: msg.id,
                role: msg.role == .user ? .user : .ai,
                content: msg.content
            )
        }
        ChatHistoryService.save(toSave, for: reportID)
    }
}

// MARK: - Lasso tutorial demo

/// The little looping animation inside the "how to circle" hint. A
/// finger traces a rounded rectangle around two mock lab rows, the
/// outline drawing smoothly behind it, then the enclosed rows light up
/// blue — then it resets and repeats. Self-contained: drives its own
/// loop via `.task` (auto-cancels when the hint disappears).
private struct LassoDemoView: View {
    /// 0→1 progress of the lasso outline + the finger riding its edge.
    @State private var trace: CGFloat = 0
    /// Whether the enclosed rows are currently highlighted.
    @State private var highlighted = false

    // Fixed demo canvas + the rectangle the finger traces, both in the
    // canvas's local top-left coordinate space.
    private let canvas = CGSize(width: 200, height: 112)
    private let lasso = CGRect(x: 14, y: 24, width: 172, height: 56)
    private let radius: CGFloat = 12

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Mock "document" rows.
            VStack(alignment: .leading, spacing: 10) {
                demoRow(name: "Glucose", value: "98", unit: "mg/dL", lit: highlighted)
                demoRow(name: "Cholesterol", value: "184", unit: "mg/dL", lit: highlighted)
                demoRow(name: "Vitamin D", value: "—", unit: "", lit: false)
            }
            .padding(.horizontal, 16)
            .padding(.top, 27)

            // Highlight fill behind the two enclosed rows.
            RoundedRectangle(cornerRadius: radius - 1, style: .continuous)
                .fill(Color.blue.opacity(highlighted ? 0.16 : 0))
                .frame(width: lasso.width, height: lasso.height)
                .offset(x: lasso.minX, y: lasso.minY)

            // The traced lasso outline, drawn progressively.
            LassoOutline(box: lasso, radius: radius)
                .trim(from: 0, to: trace)
                .stroke(Color.blue.opacity(0.9),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                .shadow(color: .blue.opacity(0.4), radius: 5)

            // Finger riding the leading edge of the trace. The
            // Animatable modifier recomputes the on-path point every
            // frame so the finger follows the rounded rectangle instead
            // of cutting straight across as `trace` interpolates.
            Image(systemName: "hand.point.up.left.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.blue)
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                .modifier(FingerAlongLasso(progress: trace, box: lasso, radius: radius))
                .opacity(highlighted ? 0 : 1)
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white)
                .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        )
        .task {
            // Loop: reset instantly → draw the lasso → highlight + hold.
            // The reset is unanimated so the finger snaps back to the
            // start rather than sliding backwards along the path.
            while !Task.isCancelled {
                highlighted = false
                trace = 0
                try? await Task.sleep(nanoseconds: 350_000_000)
                if Task.isCancelled { return }
                withAnimation(.easeInOut(duration: 1.5)) { trace = 1 }
                try? await Task.sleep(nanoseconds: 1_550_000_000)
                if Task.isCancelled { return }
                withAnimation(.easeOut(duration: 0.3)) { highlighted = true }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    private func demoRow(name: String, value: String, unit: String, lit: Bool) -> some View {
        HStack(spacing: 5) {
            Text(name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(lit ? Color.blue : Color.primary.opacity(0.75))
            Spacer(minLength: 6)
            Text(value)
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .foregroundStyle(lit ? Color.blue : Color.primary.opacity(0.85))
            if !unit.isEmpty {
                Text(unit)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Positions a view at the leading edge of the lasso outline trimmed to
/// `progress`. Conforming to `Animatable` (with `progress` as the
/// animatable data) makes SwiftUI re-evaluate the point every frame as
/// `progress` interpolates — so the finger genuinely follows the curve
/// rather than lerping straight from start to end.
private struct FingerAlongLasso: ViewModifier, Animatable {
    var progress: CGFloat
    let box: CGRect
    let radius: CGFloat

    // `nonisolated` so the Animatable conformance doesn't cross the
    // ViewModifier's implicit @MainActor isolation (Swift 6 data-race
    // check). It only touches value-type stored properties, so it's safe.
    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let t = max(0.0001, min(1, progress))
        let point = LassoOutline(box: box, radius: radius)
            .path(in: .zero)
            .trimmedPath(from: 0, to: t)
            .currentPoint ?? CGPoint(x: box.minX + radius, y: box.minY)
        return content.position(point)
    }
}

/// A rounded-rectangle path drawn from the top edge clockwise, used for
/// the lasso outline. Returns its path in fixed `box` coordinates
/// (ignores the layout rect) so the stroke trim and the finger's
/// `trimmedPath(...).currentPoint` stay in perfect sync.
private struct LassoOutline: Shape {
    let box: CGRect
    let radius: CGFloat

    func path(in _: CGRect) -> Path {
        let r = radius
        var p = Path()
        p.move(to: CGPoint(x: box.minX + r, y: box.minY))
        p.addLine(to: CGPoint(x: box.maxX - r, y: box.minY))
        p.addQuadCurve(to: CGPoint(x: box.maxX, y: box.minY + r),
                       control: CGPoint(x: box.maxX, y: box.minY))
        p.addLine(to: CGPoint(x: box.maxX, y: box.maxY - r))
        p.addQuadCurve(to: CGPoint(x: box.maxX - r, y: box.maxY),
                       control: CGPoint(x: box.maxX, y: box.maxY))
        p.addLine(to: CGPoint(x: box.minX + r, y: box.maxY))
        p.addQuadCurve(to: CGPoint(x: box.minX, y: box.maxY - r),
                       control: CGPoint(x: box.minX, y: box.maxY))
        p.addLine(to: CGPoint(x: box.minX, y: box.minY + r))
        p.addQuadCurve(to: CGPoint(x: box.minX + r, y: box.minY),
                       control: CGPoint(x: box.minX, y: box.minY))
        p.closeSubpath()
        return p
    }
}
