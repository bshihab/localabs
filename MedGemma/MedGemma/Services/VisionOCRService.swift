import Foundation
import Vision
import UIKit
import CoreGraphics

/// Uses Apple's native VisionKit framework to extract text from images.
/// This is the "Eyes" of the pipeline — zero download size, runs on the Neural Engine.
class VisionOCRService {

    /// Extracts all text from a UIImage using Apple's Vision framework.
    /// Uses the highest accuracy recognition level with language correction enabled.
    ///
    /// Two important things this does that the naive version didn't:
    ///   1. Downscales the image to ~2048px on its longest side before OCR.
    ///      With MedGemma 4B already loaded (~2.5 GB resident), feeding Vision
    ///      a raw 12-megapixel camera image was pushing devices over the
    ///      jetsam budget and getting the app instant-killed.
    ///   2. Runs `handler.perform` on a userInitiated background queue.
    ///      Vision's perform is synchronous and was previously blocking
    ///      MainActor for the full OCR duration.
    static func extractText(from image: UIImage) async throws -> String {
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
                        continuation.resume(returning: "")
                        return
                    }
                    let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                    continuation.resume(returning: lines.joined(separator: "\n"))
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
