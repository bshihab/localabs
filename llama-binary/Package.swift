// swift-tools-version: 6.0
//
// Local SwiftPM wrapper that exposes the llama.cpp xcframework directly,
// bypassing the broken `mattt/llama.swift` Swift wrapper. That wrapper's
// `Llama.swift` does `@_exported import llama`, which collides on macOS's
// case-insensitive filesystem with the xcframework's `llama` clang module
// and produces "cannot load module 'Llama' as 'llama'" during build.
//
// We pin to the same xcframework release (b7484) the upstream package was
// using, skip the Swift wrapper file entirely, and let our app depend on
// the C module `llama` (lowercase) directly. All llama.cpp symbols
// (llama_load_model_from_file, llama_sampler_sample, etc.) are still
// available via `import llama`.
import PackageDescription

let package = Package(
    name: "llama-binary",
    platforms: [
        .iOS(.v16)
    ],
    products: [
        .library(
            name: "llama",
            targets: ["llama-cpp"]
        )
    ],
    targets: [
        .binaryTarget(
            name: "llama-cpp",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b7484/llama-b7484-xcframework.zip",
            checksum: "c384d4f6a8d822884e3f14668a48c6758fe74de77bc51a443b2d5be5a7da505b"
        )
    ]
)
