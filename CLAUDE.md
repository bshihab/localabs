# Localabs Project Context

Localabs is a private, on-device iOS app that scans physical lab reports and translates them into a plain-language report you can actually understand — and ask follow-up questions about. The AI never sees the cloud; everything runs on the user's phone via a quantized 4B-parameter medical-tuned model.

## What lives where

- **`/Localabs`** — the native iOS app (SwiftUI, Swift 6, iOS 26 deployment target). Project is generated via XcodeGen from `project.yml`.
- **`/llama-binary`** — a local Swift package that exposes `llama.cpp` (the `b7484` xcframework from `ggml-org/llama.cpp`) as a target named `llama`. This bypasses `mattt/llama.swift`'s broken Swift wrapper that collided with macOS's case-insensitive filesystem. See commit history around `b585028` for the full story.

## The AI model

Localabs ships with the user choosing one of two GGUF models at runtime, downloaded from Hugging Face into the app's documents folder:

- **MedGemma 4B** (default) — Google's medical-tuned Gemma, ~2.5 GB, Q4_K_M quantization. `unsloth/medgemma-4b-it-GGUF`.
- **TinyLlama 1.1B** — fallback for dev testing on lower-memory devices.

The model file is loaded into Metal GPU memory by `LlamaContext.swift` (a thin Swift wrapper over the C API in `llama-binary`'s xcframework). All inference goes through this — generation is token-streamed via an `AsyncStream<String>` so the UI can fill in section cards as Localabs writes them.

## iOS Development (`/Localabs`)

### Project regeneration

The Xcode project is generated from `project.yml` via XcodeGen. To pick up new source files or apply project.yml changes, on the machine where Xcode runs:

```bash
cd Localabs
xcodegen
```

The generated `Localabs.xcodeproj` is gitignored — every checkout runs `xcodegen` once before building.

### Key dependencies

- **Local SwiftPM package** at `/llama-binary` — pins llama.cpp xcframework b7484 by checksum.
- Apple frameworks only otherwise (SwiftUI, PDFKit, Vision, HealthKit, UserNotifications, PhotosUI, ImageIO).

### HealthKit caveat

The `com.apple.developer.healthkit` entitlement is currently stripped from `Localabs.entitlements` because free Apple Personal Teams can't sign provisioning profiles that include it. The `HealthKitService` code is wired in and ready — once the project moves to a paid Apple Developer Program account, uncomment the `properties:` block in `project.yml` (commented instructions are there) and run `xcodegen` to regenerate.

## The analysis pipeline

`InferenceEngine.analyzeImages([UIImage])` is the entry point. It orchestrates:

1. **OCR** — Apple Vision (`VisionOCRService`) runs on each downsampled image. Downsampling happens at intake via `InferenceEngine.downsampledImage(from:)` (uses `ImageIO`'s thumbnail decoder so the full-resolution bitmap never gets allocated — multi-photo scans of 12MP iPhone photos would otherwise OOM the moment the AI model allocated its KV cache).
2. **Save scans** — JPEG'd to `Documents/scans/` so `DocumentViewerView` can re-display them later.
3. **Apple Health context** — 30-day averages for resting HR, HRV, sleep. Falls back to demo data when HealthKit isn't authorized (which is currently always, until the paid dev account is active).
4. **Inference** — `runInference` builds a structured prompt (system role + profile + Health metrics + RAG context from past reports + the OCR'd text), streams Localabs' output token-by-token. The streaming text is re-parsed on every token into a `StructuredReport` so the live section cards in `ScanView` can fill in as the model writes.
5. **Parse & save** — final output is parsed into the 5 section fields and persisted to `LocalStorageService` (UserDefaults-backed).

## The interactive document viewer

`DocumentViewerView` opens a saved scan's original image, runs Apple Vision OCR again (this time keeping bounding boxes), and lets the user select text on the image. Two modes:

- **Browse** (default) — UIScrollView handles pan + pinch zoom natively via the `ZoomablePanContainer` UIViewRepresentable.
- **Select** — single-finger drag draws a glowing "lasso" path; on release, every text block whose center falls inside the polygon gets added to the selection. Long-press fallback for quick lassos within Browse mode is gone — explicit mode toggle is more reliable.

Selected text feeds into `FollowUpChatView` (a sheet) where the user can chat with Localabs about the highlight. If the selection looks tabular (≥2 rows, ≥2 columns, ≥50% cell fill), `VisionOCRService.breakdown(of:)` extracts it as a `RecognizedTable` and the chat sheet renders a real SwiftUI Grid widget. Otherwise it falls back to plain text. Non-table prose lasso'd alongside a table renders separately as `ExtraTextBanner`.

## Known issues / sharp edges

- **Background URLSession resilience** — model downloads survive app suspension and hard-kill via `URLSessionConfiguration.background`. iOS relaunches the app to deliver completion events; `LocalabsAppDelegate.application(_:handleEventsForBackgroundURLSession:completionHandler:)` parks the handler on `ModelDownloader.shared.backgroundCompletionHandler`.
- **ggml_abort prevention** — `LlamaContext` cancels any in-flight inference when the app enters background (via a `NotificationCenter` observer in `InferenceEngine.init`). Without this, iOS suspending us mid-decode can corrupt the Metal command buffer and the next ggml call crashes.
- **Prompt overflow** — `n_ctx` is 4096, `n_batch` is 4096 (matched so multi-image prompts fit in one decode call without tripping `GGML_ASSERT(n_tokens_all <= cparams.n_batch)`). Combined OCR is truncated to 7000 chars (`truncateForContext`) as a safety net.
- **Apple Vision tables** — Vision doesn't expose native table detection, so `RecognizedTable` is reconstructed via Y-cluster (rows) + left-edge X-cluster (columns) algorithm in `VisionOCRService.breakdown`. Works well on clean lab-report tables; merged cells and multi-line cells are known v1 limitations.

## App icon (Icon Composer + Liquid Glass)

The app icon is built as a layered `.icon` file using Apple's **Icon Composer** (download from developer.apple.com → Downloads → Applications → Icon Composer beta). Icon Composer is GUI-only — there's no API to assemble `.icon` files programmatically. The workflow is:

### Generating the layer assets

The `LocalabsLogo` SwiftUI view in `Views/SplashView.swift` is the canonical brand mark. To get PNG layers out of it for Icon Composer:

1. Open Localabs on a real device or Simulator.
2. **Profile tab → Export Logo Layers (Dev)**. Three PNGs save to a share sheet:
   - `Localabs-full.png` — entire logo (flat icon fallback)
   - `Localabs-chip.png` — chip + pins + traces, transparent background
   - `Localabs-heart.png` — white heart on transparent, positioned to overlay the chip
3. Save them to Files → iCloud Drive (or AirDrop to the Mac).

### Building the .icon in Icon Composer

1. **File → New** → save as `LocalabsAppIcon.icon` somewhere outside the repo (anywhere — you'll drop it into the project after).
2. **Background:** choose "Gradient" and use `#5299FF` → `#135EE8` to match the chip's blue, OR "Solid" with pure white if you want the chip to read as a sticker against white (matches the PDF brand spec).
3. Add a group **Chip** → drag `Localabs-chip.png` in. Toggle the glass effect ON for a subtle refraction.
4. Add a group **Heart** → drag `Localabs-heart.png` in. Glass effect ON, set the glass intensity slightly higher — heart is the focal point.
5. Set the dark-mode variant: same layout, but switch the background to system dark.
6. Set the mono variant: leave glass off, the chip's blue desaturates automatically.
7. **File → Export → All variants** (also produces PNG fallbacks for iOS 25 and below).
8. **Save** the document.

### Wiring `.icon` into the Xcode project

1. Drag `LocalabsAppIcon.icon` into the Xcode project navigator at the same level as `LocalabsApp.swift` (NOT into Assets.xcassets).
2. In `project.yml`, under `targets.Localabs.settings.base`, set:
   ```yaml
   ASSETCATALOG_COMPILER_APPICON_NAME: LocalabsAppIcon
   ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS: YES
   ```
3. Run `xcodegen` to regenerate the project.
4. Clean build folder, rebuild — home-screen icon should now be the new layered Localabs logo.

The flat PNG fallback (also exported from Icon Composer) goes into `Assets.xcassets/AppIcon.appiconset/` so iOS 25 devices render the same brand mark without Liquid Glass.

Once the `.icon` is finalized and committed, remove the Export Logo Layers button and `Services/LogoExportTool.swift` — they're development scaffolding only.

## Working with this repo

The repo lives in two places per the maintainer's split-machine setup: this dev machine (where Claude edits) and a separate, more capable Mac where Xcode builds run. The flow is always:

1. Edit + commit + push from the dev machine.
2. Pull on the build Mac.
3. `cd Localabs && xcodegen` if any files were added/moved.
4. Build via `xcodebuild` or open Xcode.

SourceKit-LSP errors visible on the dev machine are environmental noise — there's no iOS toolchain here. Trust the build Mac's `xcodebuild` output for ground truth.
