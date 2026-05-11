import Foundation
import Vision
import UIKit
import CoreGraphics

/// Uses Apple's native VisionKit framework to extract text from images.
/// This is the "Eyes" of the pipeline — zero download size, runs on the Neural Engine.
class VisionOCRService {

    /// One recognized text region: the string + its normalized bounding box
    /// (Vision's [0,1] coordinate space, origin bottom-left). Sendable so
    /// the OCR work can cross actor boundaries without copying observations.
    struct RecognizedBlock: Sendable {
        let text: String
        let boundingBox: CGRect
    }

    /// A reconstructed table inferred from a set of recognized blocks. The
    /// grid is rectangular — rows are padded to the column count with empty
    /// strings, so callers can iterate `[row][col]` safely.
    struct RecognizedTable: Sendable {
        let rows: [[String]]
        /// Index of the row that should be styled as the header. Detected
        /// post-clustering by picking the row with the most all-text
        /// (non-numeric) cells and the shortest average cell length —
        /// usually row 0 in lab reports, but not always (e.g. a "Lab Panel"
        /// title row above the actual column-name row).
        let headerRowIndex: Int

        var rowCount: Int { rows.count }
        var columnCount: Int { rows.map(\.count).max() ?? 0 }
        var headerRow: [String] {
            rows.indices.contains(headerRowIndex) ? rows[headerRowIndex] : []
        }

        /// Markdown table form for handing to an LLM. The detected header
        /// row is reordered to position 0 (with the divider directly under
        /// it) and the remaining rows preserve their original order. Gemma
        /// reads this format natively and reasons about cells positionally.
        func asMarkdown() -> String {
            guard !rows.isEmpty else { return "" }
            let cols = columnCount
            func pad(_ row: [String]) -> [String] {
                (0..<cols).map { i in i < row.count ? row[i] : "" }
            }
            var lines: [String] = []
            // Header first (reordered if it wasn't already on row 0).
            lines.append("| " + pad(headerRow).joined(separator: " | ") + " |")
            lines.append("|" + String(repeating: "---|", count: cols))
            for (i, row) in rows.enumerated() where i != headerRowIndex {
                lines.append("| " + pad(row).joined(separator: " | ") + " |")
            }
            return lines.joined(separator: "\n")
        }
    }

    /// Picks the row most likely to be the table header. Heuristics:
    ///   - All-text rows (no digits) score higher than rows with numbers,
    ///     since headers are typically labels and body rows often contain
    ///     numeric values.
    ///   - Shorter average cell length scores higher (header cells are
    ///     usually one or two words; body cells often carry more text).
    ///   - Row 0 gets a small tiebreaker bonus since it's the conventional
    ///     header position and we don't want to thrash on edge cases.
    /// Returns 0 if every row scores equally (e.g. a numeric-only table).
    private static func detectHeaderRow(_ rows: [[String]]) -> Int {
        guard !rows.isEmpty else { return 0 }
        var bestIndex = 0
        var bestScore: Double = -.infinity
        for (idx, row) in rows.enumerated() {
            let nonEmpty = row.filter { !$0.isEmpty }
            guard !nonEmpty.isEmpty else { continue }
            let avgLength = Double(nonEmpty.map(\.count).reduce(0, +)) / Double(nonEmpty.count)
            let allText = nonEmpty.allSatisfy { !$0.contains(where: \.isNumber) }
            var score = 0.0
            if allText { score += 100 }
            score -= avgLength             // shorter cells → higher score
            if idx == 0 { score += 0.5 }   // tiebreaker for conventional layout
            if score > bestScore {
                bestScore = score
                bestIndex = idx
            }
        }
        return bestIndex
    }

    /// What `breakdown(of:)` returns: an optional table, plus any non-table
    /// text in the same selection rendered separately. When the user lassos
    /// a region that contains a table AND surrounding paragraphs (e.g., a
    /// "Note:" line below the lab values), `extraText` carries the
    /// paragraphs in document order so the UI can show them apart from the
    /// table widget.
    struct LassoBreakdown: Sendable {
        let table: RecognizedTable?
        let extraText: String
    }

    /// Splits a set of recognized blocks into a structured table region
    /// (when present) and any surrounding paragraph text. Used by the chat
    /// sheet to render tables and prose separately.
    ///
    /// Algorithm:
    ///   1. Cluster blocks into rows by Y-center proximity (tolerance =
    ///      60% of median text height).
    ///   2. Find global column boundaries by clustering left-edge X
    ///      positions across all rows (tolerance = 4% of normalized width).
    ///   3. Classify each row as tabular vs. paragraph. A row is tabular
    ///      iff its blocks span ≥2 distinct columns AND no single block in
    ///      the row exceeds 60 chars (long blocks are sentences, not cells).
    ///   4. Find the longest contiguous run of tabular rows — that's the
    ///      table. Everything outside that run becomes paragraph text,
    ///      preserved in document order (above-table prose then
    ///      below-table prose).
    ///   5. Validate the candidate table: need ≥2 rows, ≥2 columns, and
    ///      ≥50% of expected cells filled. If it fails any check, drop the
    ///      table and return everything as plain text.
    ///
    /// The contiguous-run requirement matters because lab reports often
    /// have a section heading + table + footnote layout. We want to
    /// extract the table portion cleanly without folding the heading into
    /// row 0 or the footnote into the last row.
    static func breakdown(of blocks: [RecognizedBlock]) -> LassoBreakdown {
        guard !blocks.isEmpty else {
            return LassoBreakdown(table: nil, extraText: "")
        }

        // Selections too small to be meaningful tables get returned as text.
        guard blocks.count >= 4 else {
            return LassoBreakdown(table: nil, extraText: joinedText(blocks))
        }

        // ── Step 1: row clustering by Y-center proximity ──
        let sortedByY = blocks.sorted { $0.boundingBox.midY > $1.boundingBox.midY }
        let sortedHeights = blocks.map(\.boundingBox.height).sorted()
        let medianHeight = sortedHeights[sortedHeights.count / 2]
        let rowTolerance = medianHeight * 0.6

        var rows: [[RecognizedBlock]] = [[sortedByY[0]]]
        for block in sortedByY.dropFirst() {
            let anchorY = rows.last!.first!.boundingBox.midY
            if abs(anchorY - block.boundingBox.midY) < rowTolerance {
                rows[rows.count - 1].append(block)
            } else {
                rows.append([block])
            }
        }

        // ── Step 2: global column boundaries ──
        let columnTolerance: CGFloat = 0.04
        let sortedLeftEdges = blocks.map(\.boundingBox.minX).sorted()
        var columnEdges: [CGFloat] = []
        var currentCluster: [CGFloat] = [sortedLeftEdges[0]]
        for edge in sortedLeftEdges.dropFirst() {
            if abs(edge - currentCluster.last!) < columnTolerance {
                currentCluster.append(edge)
            } else {
                columnEdges.append(currentCluster.reduce(0, +) / CGFloat(currentCluster.count))
                currentCluster = [edge]
            }
        }
        columnEdges.append(currentCluster.reduce(0, +) / CGFloat(currentCluster.count))

        // ── Step 3: classify each row ──
        // Tabular = spans ≥2 columns AND no single block is sentence-length.
        // The length check kills the false-positive where a multi-word
        // paragraph row hits multiple columns just because Vision split
        // the words across different X positions.
        let rowIsTabular: [Bool] = rows.map { row in
            var hitColumns = Set<Int>()
            var maxBlockLength = 0
            for block in row {
                let nearest = columnEdges.enumerated().min { a, b in
                    abs(a.element - block.boundingBox.minX)
                        < abs(b.element - block.boundingBox.minX)
                }!
                hitColumns.insert(nearest.offset)
                maxBlockLength = max(maxBlockLength, block.text.count)
            }
            return hitColumns.count >= 2 && maxBlockLength <= 60
        }

        // ── Step 4: longest contiguous tabular run ──
        var bestStart = 0
        var bestLength = 0
        var runStart = 0
        for (i, isTabular) in rowIsTabular.enumerated() {
            if isTabular {
                if i == 0 || !rowIsTabular[i - 1] { runStart = i }
                let runLength = i - runStart + 1
                if runLength > bestLength {
                    bestStart = runStart
                    bestLength = runLength
                }
            }
        }
        let tableRange = bestStart..<(bestStart + bestLength)

        // Need at least 2 tabular rows AND 2 columns to have a table at all.
        guard bestLength >= 2, columnEdges.count >= 2 else {
            return LassoBreakdown(table: nil, extraText: joinedFromRows(rows))
        }

        // ── Step 5: build the grid from the tabular run only ──
        var grid: [[String]] = []
        for row in rows[tableRange] {
            var cells = [String](repeating: "", count: columnEdges.count)
            let leftSorted = row.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
            for block in leftSorted {
                let nearest = columnEdges.enumerated().min { a, b in
                    abs(a.element - block.boundingBox.minX)
                        < abs(b.element - block.boundingBox.minX)
                }!
                let col = nearest.offset
                cells[col] = cells[col].isEmpty
                    ? block.text
                    : cells[col] + " " + block.text
            }
            grid.append(cells)
        }

        let totalExpected = grid.count * columnEdges.count
        let filledCount = grid.flatMap { $0 }.filter { !$0.isEmpty }.count
        let fillRate = Double(filledCount) / Double(totalExpected)
        guard fillRate >= 0.5 else {
            return LassoBreakdown(table: nil, extraText: joinedFromRows(rows))
        }

        // ── Step 6: paragraph rows outside the run become extraText ──
        // Document order is preserved: above-table rows first, then
        // below-table rows. Each row's blocks are joined left-to-right.
        var extraLines: [String] = []
        for (i, row) in rows.enumerated() where !tableRange.contains(i) {
            let line = row.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                .map(\.text)
                .joined(separator: " ")
            extraLines.append(line)
        }

        return LassoBreakdown(
            table: RecognizedTable(rows: grid, headerRowIndex: detectHeaderRow(grid)),
            extraText: extraLines.joined(separator: "\n")
        )
    }

    /// Convenience wrapper for callers that only want the table portion.
    static func detectTable(from blocks: [RecognizedBlock]) -> RecognizedTable? {
        breakdown(of: blocks).table
    }

    private static func joinedText(_ blocks: [RecognizedBlock]) -> String {
        // Order top-down, then left-to-right within roughly-the-same row.
        let sorted = blocks.sorted { lhs, rhs in
            if abs(lhs.boundingBox.midY - rhs.boundingBox.midY) < 0.01 {
                return lhs.boundingBox.minX < rhs.boundingBox.minX
            }
            return lhs.boundingBox.midY > rhs.boundingBox.midY
        }
        return sorted.map(\.text).joined(separator: "\n")
    }

    private static func joinedFromRows(_ rows: [[RecognizedBlock]]) -> String {
        rows.map { row in
            row.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                .map(\.text)
                .joined(separator: " ")
        }.joined(separator: "\n")
    }

    /// Extracts text observations as `RecognizedBlock`s. Used by the document
    /// viewer to lay tap targets over the original scan.
    ///
    /// Two important things this does that the naive version didn't:
    ///   1. Downscales the image to ~2048px on its longest side before OCR.
    ///      With MedGemma 4B already loaded (~2.5 GB resident), feeding Vision
    ///      a raw 12-megapixel camera image was pushing devices over the
    ///      jetsam budget and getting the app instant-killed.
    ///   2. Runs `handler.perform` on a userInitiated background queue.
    ///      Vision's perform is synchronous and was previously blocking
    ///      MainActor for the full OCR duration.
    ///
    /// Bounding boxes stay in Vision's normalized coordinates regardless of
    /// the OCR input resolution, so callers can downscale-for-recognition
    /// while still rendering overlays against the full-resolution image.
    static func extractBlocks(from image: UIImage) async throws -> [RecognizedBlock] {
        guard let originalCGImage = image.cgImage else {
            throw OCRError.invalidImage
        }
        let orientation = cgOrientation(from: image.imageOrientation)

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let cgImage = downscaledCGImage(from: originalCGImage, maxDimension: 2048)

                let request = VNRecognizeTextRequest { req, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let observations = req.results as? [VNRecognizedTextObservation] else {
                        continuation.resume(returning: [])
                        return
                    }
                    let blocks: [RecognizedBlock] = observations.compactMap { obs in
                        guard let text = obs.topCandidates(1).first?.string else { return nil }
                        return RecognizedBlock(text: text, boundingBox: obs.boundingBox)
                    }
                    continuation.resume(returning: blocks)
                }
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true

                let handler = VNImageRequestHandler(
                    cgImage: cgImage,
                    orientation: orientation,
                    options: [:]
                )
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Convenience: all OCR text joined by newlines. The pipeline calls this
    /// when it doesn't need positions.
    static func extractText(from image: UIImage) async throws -> String {
        let blocks = try await extractBlocks(from: image)
        return blocks.map(\.text).joined(separator: "\n")
    }

    /// Pure-CoreGraphics downscale (no UIKit drawing context, so it's safe to
    /// call from any thread). If the image is already smaller than
    /// `maxDimension` on its longest side, returns the original CGImage.
    private static func downscaledCGImage(from cgImage: CGImage, maxDimension: CGFloat) -> CGImage {
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let largest = max(width, height)
        guard largest > maxDimension else { return cgImage }

        let scale = maxDimension / largest
        let newWidth = Int((width * scale).rounded())
        let newHeight = Int((height * scale).rounded())

        guard let colorSpace = cgImage.colorSpace,
              let context = CGContext(
                data: nil,
                width: newWidth,
                height: newHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            return cgImage
        }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return context.makeImage() ?? cgImage
    }

    /// Maps UIImage's orientation to the corresponding Core Graphics value
    /// that Vision expects. Without this, photos taken in portrait mode (which
    /// the camera saves as landscape + .right orientation) would be OCR'd
    /// sideways and recognition quality would tank.
    private static func cgOrientation(from uiOrientation: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch uiOrientation {
        case .up:            return .up
        case .down:          return .down
        case .left:          return .left
        case .right:         return .right
        case .upMirrored:    return .upMirrored
        case .downMirrored:  return .downMirrored
        case .leftMirrored:  return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default:    return .up
        }
    }

    enum OCRError: LocalizedError {
        case invalidImage

        var errorDescription: String? {
            switch self {
            case .invalidImage:
                return "Could not process the image for text recognition."
            }
        }
    }
}
