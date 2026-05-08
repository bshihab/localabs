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
