# Localabs

Localabs translates your medical lab reports into plain language, on-device. Snap a photo or import a PDF, get a readable summary, then ask follow-up questions about anything you don't understand — all without your health data ever leaving your phone.

## What it does

- **Scan a lab report** with the camera, the Photos picker, or by importing a PDF (single page or multi-page).
- **Apple Vision OCR** extracts the text on-device.
- A **4 billion-parameter medical AI** (Google's MedGemma 4B, quantized) runs entirely on your iPhone's GPU and translates the report into five sections:
  - Patient Summary
  - Questions for Your Doctor
  - Targeted Dietary Advice
  - Medical Glossary
  - Medication Notes
- **Tap or lasso** any text on the original scan to ask follow-up questions in plain language. Lasso multiple values and the AI returns a structured Markdown table comparing them.
- **Apple Health context** (resting HR, HRV, sleep — 30-day averages) is folded into every report when authorized.
- **History view** keeps your past reports for longitudinal trend reasoning by the AI.

## Privacy

Everything stays on your device:
- Lab report photos never upload anywhere.
- The AI model runs locally via `llama.cpp` on Metal GPU.
- No analytics, no cloud, no account.

The only network traffic is the one-time download of the AI model file (~2.5 GB for MedGemma 4B) from Hugging Face when you first install. After that, the app works fully offline.

## Requirements

- iPhone with iOS 26 or later
- ~3 GB free storage for the AI model
- 6 GB+ RAM recommended (so the model can stay loaded alongside other apps)

## Build

This is an Xcode project generated via [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `Localabs/project.yml`.

```bash
brew install xcodegen
git clone <repo-url>
cd <repo>/Localabs
xcodegen
open Localabs.xcodeproj
```

The local Swift package at `/llama-binary` wraps the `llama.cpp` xcframework (release `b7484`) — it's referenced by relative path in `project.yml`, so nothing extra to install.

## Architecture

- **`LocalabsApp.swift`** — the SwiftUI app entry point + minimal `UIApplicationDelegate` for handling background-URLSession relaunch events.
- **`Services/InferenceEngine.swift`** — orchestrates the full scan-to-report pipeline (OCR → save → Health context → AI streaming → parse → persist).
- **`Services/VisionOCRService.swift`** — Apple Vision OCR + table-region reconstruction.
- **`Services/ModelDownloader.swift`** — background-URLSession-based AI model downloader that survives app suspension and hard-kill.
- **`Services/HealthKitService.swift`** — reads 30-day resting HR, HRV, sleep averages. Gated on the HealthKit entitlement (currently disabled until paid Apple Developer Program enrollment).
- **`Services/LocalStorageService.swift`** — UserDefaults-backed report history.
- **`LLaMA/LlamaContext.swift`** — Swift wrapper over `llama.cpp`'s C API. Handles model load, sampler chain (penalties → top-k → top-p → temperature → dist), and streaming token generation.
- **`Views/ScanView.swift`** — upload + live analysis flow with section cards that fill in as the AI streams.
- **`Views/DashboardView.swift`** — the per-report summary page.
- **`Views/DocumentViewerView.swift`** — interactive viewer with browse/select mode, lasso selection, multi-page navigation, follow-up chat sheet.
- **`Views/Components/MarkdownBody.swift`** (inside `SectionCard.swift`) — renders `**bold**`, `*italic*`, bullets, and Markdown tables from the AI's output.
- **`Views/Components/ZoomablePanContainer.swift`** — UIScrollView wrapper for native Photos-style pan + pinch zoom over the document image.

## License

Personal/research project. The bundled AI model (MedGemma 4B) is provided by Google under its own license terms — see [the model card on Hugging Face](https://huggingface.co/unsloth/medgemma-4b-it-GGUF).
