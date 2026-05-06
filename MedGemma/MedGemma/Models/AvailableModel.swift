import Foundation

enum AvailableModel: String, CaseIterable, Identifiable, Codable {
    case medGemma4B = "medgemma_4b"
    case tinyLlama = "tinyllama_1_1b"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .medGemma4B: return "MedGemma 4B"
        case .tinyLlama:  return "TinyLlama 1.1B (dev)"
        }
    }

    var subtitle: String {
        switch self {
        case .medGemma4B: return "Google's medical-tuned Gemma. Recommended."
        case .tinyLlama:  return "Tiny model for fast testing. Not medically tuned."
        }
    }

    var filename: String {
        switch self {
        case .medGemma4B: return "medgemma-4b-it-Q4_K_M.gguf"
        case .tinyLlama:  return "tinyllama-1.1b-chat-v1.0.q4_k_m.gguf"
        }
    }

    var downloadURL: URL {
        switch self {
        case .medGemma4B:
            return URL(string: "https://huggingface.co/unsloth/medgemma-4b-it-GGUF/resolve/main/medgemma-4b-it-Q4_K_M.gguf")!
        case .tinyLlama:
            return URL(string: "https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/tinyllama-1.1b-chat-v1.0.q4_k_m.gguf")!
        }
    }

    var expectedSizeBytes: Int64 {
        switch self {
        case .medGemma4B: return 2_490_000_000
        case .tinyLlama:    return 637_000_000
        }
    }

    var humanSize: String {
        ByteCountFormatter.string(fromByteCount: expectedSizeBytes, countStyle: .file)
    }

    var localURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(filename)
    }

    var isDownloaded: Bool {
        guard let size = try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? Int else {
            return false
        }
        return size > 10_000_000
    }
}
