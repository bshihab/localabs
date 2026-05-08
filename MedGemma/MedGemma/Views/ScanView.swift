import SwiftUI
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers

struct ScanView: View {
    @EnvironmentObject var engine: InferenceEngine
    @State private var selectedImage: UIImage?
    @State private var report: StructuredReport?
    @State private var showCamera = false
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showPDFPicker = false
    @State private var navigateToDashboard = false
    @State private var showPermissionAlert = false

    var body: some View {
        NavigationStack {
            ZStack {
                if engine.isProcessing {
                    processingView
                        .transition(.opacity)
                } else {
                    uploadView
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: engine.isProcessing)
            .navigationTitle("")
            .fullScreenCover(isPresented: $showCamera) {
                NativeCameraView(image: $selectedImage)
                    .ignoresSafeArea()
            }
            .sheet(isPresented: $showPDFPicker) {
                PDFDocumentPicker { url in
                    Task {
                        report = await engine.analyzePDF(at: url)
                        navigateToDashboard = true
                    }
                }
                .ignoresSafeArea()
            }
            .alert("Camera Access Required", isPresented: $showPermissionAlert) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Please enable camera access in Settings to scan lab reports.")
            }
            .onChange(of: pickerItems) { _, newItems in
                guard !newItems.isEmpty else { return }
                Task {
                    // Load all picked photos in document order, dropping
                    // any that fail to decode rather than crashing the
                    // whole batch on one bad item.
                    var images: [UIImage] = []
                    for item in newItems {
                        if let data = try? await item.loadTransferable(type: Data.self),
                           let img = UIImage(data: data) {
                            images.append(img)
                        }
                    }
                    pickerItems = []
                    if !images.isEmpty {
                        report = await engine.analyzeImages(images)
                        navigateToDashboard = true
                    }
                }
            }
            .onChange(of: selectedImage) { _, newImage in
                // Camera path: single shot. Funnel through analyzeImages so
                // there's only one analysis pipeline to maintain.
                guard let image = newImage else { return }
                Task {
                    report = await engine.analyzeImages([image])
                    navigateToDashboard = true
                    selectedImage = nil
                }
            }
            .navigationDestination(isPresented: $navigateToDashboard) {
                if let report = report {
                    DashboardView(initialReport: report)
                }
            }
        }
    }

    // MARK: - Upload (idle) view

    private var uploadView: some View {
        VStack(spacing: 0) {
            Spacer()

            ZStack {
                Circle()
                    .fill(.blue.opacity(0.12))
                    .frame(width: 96, height: 96)
                Image(systemName: "doc.text.viewfinder")
                    .font(.system(size: 44))
                    .foregroundStyle(.blue)
            }
            .padding(.bottom, 24)

            Text("Upload Report")
                .font(.system(size: 34, weight: .bold))
                .padding(.bottom, 8)

            Text("Ingest lab results securely using your\nCamera or Photo Library.")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, 40)

            Spacer()

            VStack(spacing: 8) {
                GlassEffectContainer(spacing: 12) {
                    VStack(spacing: 12) {
                        Button {
                            requestCameraAndOpen()
                        } label: {
                            Label("Open Camera", systemImage: "camera.fill")
                                .font(.system(size: 17, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(!engine.isModelLoaded)

                        // Up to 10 photos for a multi-page report. iOS's
                        // built-in picker handles the multi-select UI.
                        PhotosPicker(
                            selection: $pickerItems,
                            maxSelectionCount: 10,
                            matching: .images
                        ) {
                            Label("Choose from Photos", systemImage: "photo.on.rectangle")
                                .font(.system(size: 17, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(.glass)
                        .disabled(!engine.isModelLoaded)

                        Button {
                            showPDFPicker = true
                        } label: {
                            Label("Choose a PDF", systemImage: "doc.fill")
                                .font(.system(size: 17, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(.glass)
                        .disabled(!engine.isModelLoaded)
                    }
                }

                if !engine.isModelLoaded {
                    Text("Download \(engine.selectedModel.displayName) in Profile first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }

    // MARK: - Processing (live-fill) view

    private var processingView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                ProgressView()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Analyzing")
                        .font(.system(size: 17, weight: .semibold))
                    Text(engine.processingStatus.isEmpty
                         ? "MedGemma is generating your report…"
                         : engine.processingStatus)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            // Cards fill in live as MedGemma streams each section.
            LiveReportSectionsView(streamingText: engine.streamingText)
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
        }
    }

    private func requestCameraAndOpen() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            showCamera = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        showCamera = true
                    } else {
                        showPermissionAlert = true
                    }
                }
            }
        case .denied, .restricted:
            showPermissionAlert = true
        @unknown default:
            showPermissionAlert = true
        }
    }
}

// MARK: - Live-fill section cards

/// Renders the five report sections as cards that fill in as MedGemma streams.
/// On every token, we re-parse the partial text via StructuredReport.parse —
/// since the parser is header-anchored, partial input correctly attributes
/// each chunk to its section. Whichever section currently has the latest
/// text is the "active" one (gets a pulsing dot + tinted glass + auto-scroll).
private struct LiveReportSectionsView: View {
    let streamingText: String

    private var partial: StructuredReport {
        StructuredReport.parse(from: streamingText)
    }

    /// The section being filled right now: the last in declaration order
    /// that has any content. If nothing has streamed yet, default to the
    /// first one so the visual cursor sits there waiting.
    private var activeSection: ReportSection {
        for section in ReportSection.allCases.reversed() {
            if !text(for: section).isEmpty { return section }
        }
        return .summary
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 14) {
                    ForEach(ReportSection.allCases) { section in
                        LiveSectionCard(
                            section: section,
                            text: cleanText(for: section),
                            state: state(for: section)
                        )
                        .id(section)
                    }
                }
            }
            .onChange(of: activeSection) { _, new in
                // Keep the section MedGemma is currently writing in view —
                // user shouldn't have to scroll to see fresh content.
                withAnimation(.easeInOut(duration: 0.45)) {
                    proxy.scrollTo(new, anchor: .top)
                }
            }
        }
    }

    private func text(for section: ReportSection) -> String {
        switch section {
        case .summary:     return partial.patientSummary
        case .questions:   return partial.doctorQuestions
        case .diet:        return partial.dietaryAdvice
        case .glossary:    return partial.medicalGlossary
        case .medications: return partial.medicationNotes
        }
    }

    /// Strip a trailing line that looks like an in-progress section header
    /// (e.g., "2." or "2. QUESTIONS FOR YOUR" before "DOCTOR" arrives) so
    /// the previous section's card doesn't briefly show the next header
    /// while the LLM tokenizes it.
    private func cleanText(for section: ReportSection) -> String {
        let raw = text(for: section)
        let lines = raw.components(separatedBy: "\n")
        guard let last = lines.last else { return raw }

        let stripped = last.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "#", with: "")
            .trimmingCharacters(in: .whitespaces)

        let startsWithListMarker = stripped.range(
            of: #"^\d+[\.\)]"#, options: .regularExpression
        ) != nil
        let isShortAndAllCapsish = stripped.count < 40
            && stripped.uppercased() == stripped
            && stripped.contains(where: { $0.isLetter })

        if startsWithListMarker && isShortAndAllCapsish {
            return lines.dropLast().joined(separator: "\n")
        }
        return raw
    }

    private func state(for section: ReportSection) -> LiveSectionState {
        if !text(for: section).isEmpty {
            return section == activeSection ? .active : .complete
        }
        return .pending
    }
}

private enum ReportSection: Int, CaseIterable, Identifiable {
    case summary, questions, diet, glossary, medications
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .summary:     return "Patient Summary"
        case .questions:   return "Questions for Your Doctor"
        case .diet:        return "Dietary Advice"
        case .glossary:    return "Medical Glossary"
        case .medications: return "Medication Notes"
        }
    }

    var icon: String {
        switch self {
        case .summary:     return "person.text.rectangle.fill"
        case .questions:   return "questionmark.bubble.fill"
        case .diet:        return "leaf.fill"
        case .glossary:    return "book.fill"
        case .medications: return "pills.fill"
        }
    }

    var tint: Color {
        switch self {
        case .summary:     return .blue
        case .questions:   return .purple
        case .diet:        return .green
        case .glossary:    return .orange
        case .medications: return .pink
        }
    }
}

private enum LiveSectionState {
    case pending, active, complete
}

private struct LiveSectionCard: View {
    let section: ReportSection
    let text: String
    let state: LiveSectionState

    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: section.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(state == .pending ? Color.secondary : section.tint)
                Text(section.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(state == .pending ? Color.secondary : Color.primary)
                Spacer()
                if state == .active {
                    Circle()
                        .fill(section.tint)
                        .frame(width: 8, height: 8)
                        .scaleEffect(pulse ? 1.4 : 0.85)
                        .opacity(pulse ? 0.55 : 1.0)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                                pulse = true
                            }
                        }
                        .transition(.opacity)
                }
            }

            Group {
                if !text.isEmpty {
                    Text(text)
                        .font(.system(size: 14))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                } else if state == .active {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.65)
                        Text("Generating…")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Waiting for MedGemma…")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary.opacity(0.55))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(
            state == .active
                ? .regular.tint(section.tint.opacity(0.18))
                : .regular,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay(
            // Subtle tint glow on the active card so the eye knows where to look
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(section.tint.opacity(state == .active ? 0.45 : 0), lineWidth: 1)
        )
        .opacity(state == .pending ? 0.55 : 1.0)
        .scaleEffect(state == .pending ? 0.97 : 1.0)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: state)
        .animation(.easeOut(duration: 0.18), value: text)
    }
}

// MARK: - PDF Document Picker

/// Wraps UIDocumentPickerViewController so SwiftUI can present a PDF picker
/// as a sheet. Calls `onPicked(url)` once the user selects a file. The URL
/// it hands back is a security-scoped resource — InferenceEngine.analyzePDF
/// handles the start/stopAccessingSecurityScopedResource dance.
struct PDFDocumentPicker: UIViewControllerRepresentable {
    let onPicked: (URL) -> Void
    @Environment(\.dismiss) var dismiss

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.pdf], asCopy: false)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: PDFDocumentPicker
        init(_ parent: PDFDocumentPicker) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first {
                parent.onPicked(url)
            }
            parent.dismiss()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.dismiss()
        }
    }
}

// MARK: - Apple's Native Camera UI (UIImagePickerController)

struct NativeCameraView: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.dismiss) var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.cameraDevice = .rear
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: NativeCameraView
        init(_ parent: NativeCameraView) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage {
                parent.image = img
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
