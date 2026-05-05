# MedGemma Project Context

MedGemma is a medical application designed to analyze lab reports and health data using on-device AI (Gemma 4B) and cloud-based services.

## Project Structure

- **`/MedGemma`**: Native iOS application built with Swift and SwiftUI.
  - Uses **XcodeGen** (`project.yml`) for project management.
  - Integrates **VisionKit** for OCR and **HealthKit** for personal health context.
  - Uses **llama.cpp** via the **llama.swift** package for on-device inference.
- **`/mobile_app`**: Cross-platform mobile application built with **React Native** and **Expo**.
- **`/gcp_backend`**: Backend services hosted on **Google Cloud Platform**.
- **`med_llm.md`**: Documentation and notes regarding medical LLMs and prompt engineering.

## iOS Development (`/MedGemma`)

### Project Generation
The Xcode project is generated using [XcodeGen](https://github.com/yonaskolb/XcodeGen). 
To update the project after modifying `project.yml`, run:
```bash
cd MedGemma
xcodegen
```

### Key Dependencies
- **llama.swift**: `https://github.com/mattt/llama.swift`
  - Provides Swift bindings for llama.cpp.
  - Current product: `LlamaSwift`.

### Current Known Issues
- **Missing Package Product `LlamaSwift`**: There is an ongoing issue where Xcode reports a missing package product for `llama.swift`. 
  - Ensure that `project.yml` correctly references `package: llama.swift` and `product: LlamaSwift`.
  - Try resetting the Swift Package cache in Xcode: `File > Packages > Reset Package Caches`.
  - Verify that the URL and version in `project.yml` are correct.

## AI Engine (`InferenceEngine.swift`)
The core AI logic resides in `InferenceEngine.swift`. It orchestrates the pipeline:
1. **OCR**: Extracting text from images using Apple Vision.
2. **Context**: Fetching Apple Health metrics.
3. **Inference**: Running the GGUF model (MedGemma 4B or TinyLlama for testing) using `LlamaContext`.
4. **Parsing**: Structuring the model's output into a `StructuredReport`.

## Backend (`/gcp_backend`)
The backend handles more complex processing and cloud-based features. (Add more details as discovered).

## Cross-Platform App (`/mobile_app`)
A React Native / Expo implementation, likely for Android support or a unified UI. (Add more details as discovered).
