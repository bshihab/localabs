import Foundation

/// The on-device model Localabs runs. Single option now — MedGemma 4B.
/// TinyLlama was removed: it isn't medically tuned and its output is too
/// weak to trust in a health app. The enum shape is kept (CaseIterable,
/// Codable) so the model picker and persistence keep working, and a
/// stored value that no longer matches falls back to `.medGemma4B`.
enum AvailableModel: String, CaseIterable, Identifiable, Codable {
    case medGemma4B = "medgemma_4b"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .medGemma4B: return "MedGemma 4B"
        }
    }

    var subtitle: String {
        switch self {
        case .medGemma4B: return "Google's medical-tuned Gemma. Runs entirely on your device."
        }
    }

    var filename: String {
        switch self {
        case .medGemma4B: return "medgemma-4b-it-Q4_K_M.gguf"
        }
    }

    var downloadURL: URL {
        switch self {
        case .medGemma4B:
            return URL(string: "https://huggingface.co/unsloth/medgemma-4b-it-GGUF/resolve/main/medgemma-4b-it-Q4_K_M.gguf")!
        }
    }

    var expectedSizeBytes: Int64 {
        switch self {
        case .medGemma4B: return 2_490_000_000
        }
    }

    var humanSize: String {
        ByteCountFormatter.string(fromByteCount: expectedSizeBytes, countStyle: .file)
    }

    var localURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(filename)
    }

    /// True only when the on-disk model file is at least 95% of the expected
    /// download size — a partial / interrupted download easily passes the
    /// old "size > 10 MB" check, then llama.cpp tries to load the corrupt
    /// file and fails with "Failed to load model into memory" (which is
    /// confusing because the user didn't expect to be re-trying a load).
    /// The 95% threshold tolerates minor Hugging Face file-size variations
    /// while still catching real partial downloads.
    var isDownloaded: Bool {
        guard let size = try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? Int else {
            return false
        }
        let minimumComplete = Int64(Double(expectedSizeBytes) * 0.95)
        return Int64(size) >= minimumComplete
    }
}
