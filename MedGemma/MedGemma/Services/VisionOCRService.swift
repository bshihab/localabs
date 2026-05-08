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

        var rowCount: Int { rows.count }
        var columnCount: Int { rows.map(\.count).max() ?? 0 }

        /// Markdown table form for handing to an LLM. First row is treated
        /// as the header. Pipe-separated with a `---` divider after the
        /// header — Gemma understands this format natively and reasons about
        /// cells positionally instead of guessing from a flat string.
        func asMarkdown() -> String {
            guard !rows.isEmpty else { return "" }
            let cols = columnCount
            func pad(_ row: [String]) -> [String] {
                (0..<cols).map { i in i < row.count ? row[i] : "" }
            }
            var lines: [String] = []
            lines.append("| " + pad(rows[0]).joined(separator: " | ") + " |")
            lines.append("|" + String(repeating: "---|", count: cols))
            for row in rows.dropFirst() {
                lines.append("| " + pad(row).joined(separator: " | ") + " |")
            }
            return lines.joined(separator: "\n")
        }
    }

    /// Tries to recover a table structure from a set of recognized blocks
    /// (typically the user's lasso selection). Returns nil if the layout
    /// doesn't look table-like — caller falls back to plain text.
    ///
    /// Algorithm, in order:
    ///   1. Cluster blocks into rows by Y-center proximity. Tolerance is
    ///      60% of the median text height, which is loose enough to absorb
    ///      slight baseline drift in scanned docs but tight enough to keep
    ///      adjacent rows separate.
    ///   2. Cluster left-edge X positions across all rows into column
    ///      boundaries. Tolerance is 4% of normalized image width — anything
    ///      closer is treated as the same column. Most lab tables are
    ///      left-aligned within columns, so left edges are the cleanest
    ///      anchor (right edges vary with content length).
    ///   3. Snap each block to its nearest column boundary. Multiple blocks
    ///      landing in the same (row, col) get joined with a space — handles
    ///      the case where Vision splits a cell into two observations
    ///      ("70-100", "mg/dL").
    ///   4. Validate: need ≥2 rows AND ≥2 columns AND ≥50% of expected
    ///      cells filled AND average cell length ≤ 60 chars. The last check
    ///      rules out paragraph text that happens to wrap on consistent
    ///      indentation (looks gridlike but isn't).
    static func detectTable(from blocks: [RecognizedBlock]) -> RecognizedTable? {
        guard blocks.count >= 4 else { return nil }

        // ── Step 1: row clustering by Y-center proximity ──
        // Vision uses bottom-left origin, so descending midY = top-down.
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
        guard rows.count >= 2 else { return nil }

        // ── Step 2: column boundary detection by left-edge clustering ──
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
        guard columnEdges.count >= 2 else { return nil }

        // ── Step 3: snap blocks into (row, column) cells ──
        var grid: [[String]] = []
        for row in rows {
            var cells = [String](repeating: "", count: columnEdges.count)
            let leftSorted = row.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
            for block in leftSorted {
                let nearest = columnEdges.enumerated().min { a, b in
                    abs(a.element - block.boundingBox.minX) < abs(b.element - block.boundingBox.minX)
                }!
                let col = nearest.offset
                cells[col] = cells[col].isEmpty ? block.text : cells[col] + " " + block.text
            }
            grid.append(cells)
        }

        // ── Step 4: validate this actually looks like a table ──
        let totalExpected = rows.count * columnEdges.count
        let filledCells = grid.flatMap { $0 }.filter { !$0.isEmpty }
        let fillRate = Double(filledCells.count) / Double(totalExpected)
        guard fillRate >= 0.5 else { return nil }

        // Long average cell length suggests paragraph text that just happens
        // to wrap on consistent indentation, not a real table.
        let avgCellLength = filledCells.map(\.count).reduce(0, +) / max(filledCells.count, 1)
        guard avgCellLength <= 60 else { return nil }

        return RecognizedTable(rows: grid)
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
