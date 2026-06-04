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
        ///
        /// Cells that carry internal newlines (multi-line cell content,
        /// e.g. a "Therapeutic Range" column with three bullet lines)
        /// get those newlines collapsed to `; ` so each markdown table
        /// row stays on a single line — a raw `\n` inside a cell would
        /// terminate the row in standard markdown and leave the model
        /// staring at a mis-shaped table.
        func asMarkdown() -> String {
            guard !rows.isEmpty else { return "" }
            let cols = columnCount
            func sanitize(_ cell: String) -> String {
                cell.replacingOccurrences(of: "\n", with: "; ")
                    .replacingOccurrences(of: "|", with: "\\|")
            }
            func pad(_ row: [String]) -> [String] {
                (0..<cols).map { i in i < row.count ? sanitize(row[i]) : "" }
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
    ///      the row exceeds 90 chars (long blocks are sentences, not cells).
    ///   4. Take the span from the first tabular row to the last tabular
    ///      row as the table region. Non-tabular rows INSIDE that span
    ///      (between two tabular rows) are treated as multi-line cell
    ///      continuations — their blocks get folded into the matching
    ///      columns of the preceding tabular row. This is what lets us
    ///      handle lab tables where the "Therapeutic Range" column stacks
    ///      3-4 bullet lines per test row.
    ///   5. Validate the candidate table: need ≥2 rows, ≥2 columns, and
    ///      ≥50% of expected cells filled. If it fails any check, drop the
    ///      table and return everything as plain text.
    ///
    /// Rows BEFORE the first tabular row (e.g. a "LIPID PANEL PROFILE"
    /// heading) and AFTER the last tabular row (footnotes) become
    /// `extraText` rather than being folded into the table.
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
        // the words across different X positions. Bumped to 90 chars (was
        // 60) so longer cell content like "Numeric calculation requested"
        // descriptions or wrapped flag text doesn't disqualify a row.
        let rowIsTabular: [Bool] = rows.map { row in
            var hitColumns = Set<Int>()
            var maxBlockLength = 0
            for block in row {
                hitColumns.insert(nearestColumnIndex(for: block.boundingBox.minX, edges: columnEdges))
                maxBlockLength = max(maxBlockLength, block.text.count)
            }
            return hitColumns.count >= 2 && maxBlockLength <= 90
        }

        // ── Step 4: table range = first tabular row through last tabular row ──
        // We use the outer span (not the longest contiguous run) so that
        // single-block "orphan" rows between tabular rows can be folded
        // back in as continuation lines of multi-line cells. The longest-
        // contiguous-run approach was dropping every test row in a lab
        // table whose Therapeutic Range column had multiple bullets,
        // because each bullet became its own non-tabular row.
        let tabularIndices = rowIsTabular.enumerated().compactMap { $1 ? $0 : nil }
        guard let firstTabular = tabularIndices.first,
              let lastTabular = tabularIndices.last,
              tabularIndices.count >= 2,
              columnEdges.count >= 2
        else {
            return LassoBreakdown(table: nil, extraText: joinedFromRows(rows))
        }
        let tableRange = firstTabular...lastTabular

        // ── Step 5: build the grid, folding orphan rows into the prior tabular row ──
        var grid: [[String]] = []
        var currentCells: [String]? = nil
        for i in tableRange {
            let row = rows[i]
            if rowIsTabular[i] {
                // Flush the prior tabular row (with any continuations
                // that got folded into it) before starting a new one.
                if let prev = currentCells { grid.append(prev) }
                var cells = [String](repeating: "", count: columnEdges.count)
                let leftSorted = row.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                for block in leftSorted {
                    let col = nearestColumnIndex(for: block.boundingBox.minX, edges: columnEdges)
                    cells[col] = cells[col].isEmpty
                        ? block.text
                        : cells[col] + " " + block.text
                }
                currentCells = cells
            } else if currentCells != nil {
                // Continuation row: append each block to the matching
                // column of the preceding tabular row, newline-separated.
                // Newlines (rather than spaces) preserve the bullet-list
                // structure of multi-line cells in the markdown export.
                for block in row {
                    let col = nearestColumnIndex(for: block.boundingBox.minX, edges: columnEdges)
                    currentCells![col] = currentCells![col].isEmpty
                        ? block.text
                        : currentCells![col] + "\n" + block.text
                }
            }
        }
        if let last = currentCells { grid.append(last) }

        let totalExpected = grid.count * columnEdges.count
        let filledCount = grid.flatMap { $0 }.filter { !$0.isEmpty }.count
        let fillRate = totalExpected > 0 ? Double(filledCount) / Double(totalExpected) : 0
        guard grid.count >= 2, fillRate >= 0.5 else {
            return LassoBreakdown(table: nil, extraText: joinedFromRows(rows))
        }

        // ── Step 6: paragraph rows outside the range become extraText ──
        // Only rows above the first tabular row and below the last
        // tabular row get split out — anything inside got folded into
        // the grid already.
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

    /// Returns the index of the column edge nearest to `x`. Pulled out
    /// of the breakdown algorithm as a helper because we now need to do
    /// the same lookup in two phases (row classification + grid build +
    /// orphan-row continuation fold).
    private static func nearestColumnIndex(for x: CGFloat, edges: [CGFloat]) -> Int {
        var bestIndex = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (i, edge) in edges.enumerated() {
            let d = abs(edge - x)
            if d < bestDistance {
                bestDistance = d
                bestIndex = i
            }
        }
        return bestIndex
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
