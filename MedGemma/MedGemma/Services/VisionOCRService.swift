import Foundation
import Vision
import UIKit

/// Uses Apple's native VisionKit framework to extract text from images.
/// This is the "Eyes" of the pipeline — zero download size, runs on the Neural Engine.
class VisionOCRService {
    
    /// Extracts all text from a UIImage using Apple's Vision framework.
    /// Uses the highest accuracy recognition level with language correction enabled.
    static func extractText(from image: UIImage) async throws -> String {
        guard let cgImage = image.cgImage else {
            throw OCRError.invalidImage
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: "")
                    return
                }
                
                // Extract the highest-confidence text candidate from each observation
                let extractedLines = observations.compactMap { observation in
                    observation.topCandidates(1).first?.string
                }
                
                continuation.resume(returning: extractedLines.joined(separator: "\n"))
            }
            
            // Configure for maximum accuracy (same as our Python test)
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
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
