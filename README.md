# Localabs

Localabs translates your medical lab reports and clinical notes into plain language, on-device. Scan a document with the camera, the Photos picker, or by importing a PDF — get a readable summary in five sections, then ask follow-up questions about anything you don't understand. Your health data never leaves your phone.

Marketing site: **[localabs.app](https://bshihab.github.io/localabs-website/)** ([repo](https://github.com/bshihab/localabs-website))

## What it does

- **Multi-page document scanner.** Apple's native `VNDocumentCameraViewController` (the same scanner Notes uses) captures multiple pages in one session, with edge detection, perspective correction, and per-page retake. Photos picker and PDF picker are alternative entry points.
- **Apple Vision OCR** extracts text on-device.
- **MedGemma 4B** — Google's medical-tuned Gemma, quantized to ~2.5 GB — runs on your iPhone's GPU via `llama.cpp` on Metal and translates the report into five sections:
  - Patient Summary
  - Questions for Your Doctor
  - Targeted Dietary Advice
  - Medical Glossary
  - Medication Notes
- **Per-document follow-up chat.** Lasso any text on the original scan to ask about it. Single-finger drag in Select mode draws a glowing lasso path; on release, every text block whose center falls inside gets added to the selection. Lasso multi-page reports and the app reminds you which other pages you've selected from. The chat history persists per scan — reopen the report later and pick up where you left off.
- **Health Trends tab.** Daily averages for activity, mobility, cardio & recovery, sleep, vitals, and body metrics from Apple Health, rendered as Apple-Health-style bar / line charts. Each metric card carries an age- and sex-bracketed status label (Typical / Borderline / Outside typical) drawn from peer-reviewed reference bands.
- **Per-metric chat + Trends chat.** Tap any metric for a detail sheet with its full chart, clinical context, and a chat scoped to that single trend; or use the Trends-tab chat for broader synthesis across all your metrics and past scans.
- **Apple Health context in every report.** Resting HR, HRV, sleep, steps, walking distance, walking speed, and exercise minutes (30-day averages) are folded into every analysis prompt as silent reference context. Never quoted as findings; never restated as if they were lab values.
- **History tab.** Past reports live on-device with keyword-derived titles (Lipid Panel, Vitiligo Evaluation, Hypertension Visit, etc.). Long-press for Rename / Share / Delete. Multi-select for batch share or delete. Per-report chat history travels with the report.
- **Medical profile.** Age, biological sex, blood type, smoking, alcohol, family history, conditions, and medications fold into every prompt as personalization context. Add facts mid-chat via a "+" quick-add sheet, or edit the full profile from a dedicated edit sheet.
- **Refusal on non-medical scans.** A pre-flight heuristic + a mid-stream watcher both detect when a scan isn't actually a medical document and stop the analysis with a popup instead of fabricating content from past reports.

## Privacy

Everything stays on your device:

- Lab report photos never upload anywhere.
- The AI model runs locally via `llama.cpp` on Metal GPU.
- Apple Health reads are local; values are only read into the analysis prompt at runtime, never transmitted.
- Per-report chat history is stored locally in `UserDefaults` keyed by report UUID and cleared automatically when you delete the report.
- No analytics, no third-party SDKs, no cloud, no account.

The only network traffic is the one-time download of the AI model file (~2.5 GB for MedGemma 4B) from Hugging Face when you first install. After that, the app works fully offline.

## Requirements

- **iPhone 15 Pro or later** — same hardware floor as Apple Intelligence. The 4B model + KV cache + iOS overhead needs ≥ 8 GB RAM, which excludes A16 and earlier devices.
- **iOS 26 or later** — required for several Liquid Glass + sensory-feedback APIs the UI relies on.
- **~3 GB free storage** for the AI model.

## Build

This is an Xcode project generated via [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `Localabs/project.yml`.

```bash
brew install xcodegen
git clone https://github.com/bshihab/localabs.git
cd localabs/Localabs
xcodegen
open Localabs.xcodeproj
```

The local Swift package at `/llama-binary` wraps the `llama.cpp` xcframework (release `b7484`) — it's referenced by relative path in `project.yml`, so nothing extra to install.

HealthKit is enabled in the project's entitlements. To build with HealthKit, you'll need a paid Apple Developer Program membership (free Personal Teams can't sign a profile that includes the `com.apple.developer.healthkit` entitlement).

## Architecture

### Services

- **`InferenceEngine.swift`** — orchestrates the full scan-to-report pipeline (OCR → save → Apple Health context → AI streaming → parse → persist). Owns the four chat methods (`askFollowUp`, `askAboutTrends`, `askAboutMetric`, and the main analysis), the resume/discard flow for paused or truncated runs, and the non-medical-document refusal logic.
- **`VisionOCRService.swift`** — Apple Vision OCR + table-region reconstruction. Detects multi-column lab tables by clustering Y-positions (rows) and left-edge X-positions (columns), then merges multi-line cells into a single logical row.
- **`HealthKitService.swift`** — daily-bucketed reads for activity, mobility, cardio & recovery, sleep, vitals, and body metrics. Returns nil per-metric when denied or unavailable; the UI hides cards whose backing series is empty.
- **`HealthInsights.swift`** — clinical interpretation of Health metrics. Age + sex bracketed reference bands drawn from peer-reviewed sources (Umetani 1998 for HRV, ACSM Guidelines for VO₂ max, Studenski 2011 for walking speed, Hirshkowitz 2015 for sleep, etc.).
- **`LocalStorageService.swift`** — UserDefaults-backed report history with RAG-context builder for the chats.
- **`ChatHistoryService.swift`** — per-report chat persistence (FollowUpChatView only — Trends and Metric chats are ephemeral by design since their underlying data is a rolling window).
- **`ModelDownloader.swift`** — background-URLSession-based AI model downloader that survives app suspension and hard-kill.
- **`ProfileSuggestionService.swift`** *(deprecated, replaced by manual quick-add)*.

### Models

- **`StructuredReport.swift`** — the 5-section report Codable + keyword-based title detector + non-medical-rejection sentinel.
- **`UserProfile.swift`** — the medical profile + `Field` enum + `add(_:to:)` mutator used by the quick-add sheet.

### LLM

- **`LLaMA/LlamaContext.swift`** — Swift wrapper over `llama.cpp`'s C API. Handles model load, sampler chain (penalties → top-k → top-p → temperature → dist), KV-cache clearing per call, and streaming token generation.

### Views

- **`LocalabsApp.swift`** — SwiftUI app entry point + minimal `UIApplicationDelegate` for handling background-URLSession relaunch events and keyboard pre-warming.
- **`ContentView.swift`** — root tab container.
- **`SplashView.swift`** — animated launch splash (heart-window reveal into ContentView, light + dark variants).
- **`OnboardingView.swift`** — first-launch 4-step welcome + profile capture.
- **`ScanView.swift`** — upload flow with photo picker, document camera, PDF picker; live processing view with per-section streaming cards and Resume/Discard for paused or truncated runs.
- **`DashboardView.swift`** — per-report summary page with patient summary, expandable sections, regenerate, share, and per-report chat entry point.
- **`DocumentViewerView.swift`** — interactive viewer with Browse / Select mode toggle, lasso selection, multi-page navigation, cross-page selection reminder banner, auto-detect-table button, and the embedded follow-up chat sheet.
- **`HistoryView.swift`** — past-report list with rename / share / delete via long-press context menu + multi-select toolbar.
- **`ProfileView.swift`** — profile tab with on-device AI engine card, Apple Health connection status, and core profile fields.
- **`ProfileEditSheet.swift`** — dedicated edit sheet showing all profile fields with auto-save.
- **`TrendsView.swift`** — Health Trends tab with grouped metric cards.
- **`TrendsChatView.swift`** — broad health-trends chat (synthesizes across all metrics + past reports).
- **`MetricChatView.swift`** — per-metric chat (scoped to one trend, with other metrics + past reports as supporting context).
- **`MetricDetailView.swift`** *(in TrendsView)* — full-screen metric chart with Apple-Health-style typography, status legend, clinical context, and the per-metric chat trigger.

### Components

- **`Components/SectionCard.swift`** — collapsible report-section card. Hosts `MarkdownBody` which renders `**bold**`, `*italic*`, bullets, and Markdown tables from the AI's output.
- **`Components/ZoomablePanContainer.swift`** — `UIScrollView` wrapper for native Photos-style pan + pinch zoom over the document image.
- **`Components/TypingDots.swift`** — iMessage-style three-dot typing indicator shown while a chat waits on the first streamed token.
- **`Components/ProfileQuickAddSheet.swift`** — quick add-to-profile sheet with field-aware controls (picker for closed-set fields like blood type, numeric keypad for age, text for free-form fields) and validation alerts.

## Known sharp edges

- **`n_ctx` is 4096** — multi-page scans get OCR-truncated to 7000 chars and the AI output is capped at 1500 tokens. Five pages of dense bloodwork can still fit; eight-page clinical novels won't.
- **The AI's KV-cache memory observer** auto-pauses inference when the app actually enters background (not on every brief `.inactive` lifecycle event, which used to mis-fire). This protects the Metal command buffer from corruption that would crash on resume with `ggml_abort`.
- **Pure regex title detector**, no LLM. The keyword list lives in `StructuredReport.titleFromOCRKeywords` — easy to extend, but a report whose OCR doesn't surface any known keyword falls back to a date-based title ("May 22 Report").
- **No medical-device certification.** Localabs is an experimental translation tool, not a diagnostic. Every report ends with explicit questions to raise with a clinician.

## License

Personal / research project. The bundled AI model (MedGemma 4B) is provided by Google under its own license terms — see [the model card on Hugging Face](https://huggingface.co/unsloth/medgemma-4b-it-GGUF).
