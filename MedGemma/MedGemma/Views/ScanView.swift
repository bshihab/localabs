import SwiftUI
import PhotosUI
import AVFoundation

struct ScanView: View {
    @EnvironmentObject var engine: InferenceEngine
    @State private var selectedImage: UIImage?
    @State private var report: StructuredReport?
    @State private var showCamera = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var navigateToDashboard = false
    @State private var showPermissionAlert = false

    var body: some View {
        NavigationStack {
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

                actionStack
                    .padding(.horizontal, 24)
                    .padding(.bottom, 40)
            }
            .navigationTitle("")
            .fullScreenCover(isPresented: $showCamera) {
                NativeCameraView(image: $selectedImage)
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
            .onChange(of: pickerItem) { _, newItem in
                guard let newItem else { return }
                Task {
                    if let data = try? await newItem.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        selectedImage = image
                    }
                    pickerItem = nil
                }
            }
            .onChange(of: selectedImage) { _, newImage in
                guard let image = newImage else { return }
                Task {
                    report = await engine.analyzeImage(image)
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

    @ViewBuilder
    private var actionStack: some View {
        if engine.isProcessing {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Analyzing")
                            .font(.system(size: 17, weight: .semibold))
                        Text(engine.processingStatus)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                if !engine.streamingText.isEmpty {
                    ScrollView {
                        Text(engine.streamingText)
                            .font(.system(size: 13, design: .rounded))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 180)
                }
            }
            .padding(16)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        } else {
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

                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label("Choose from Photos", systemImage: "photo.on.rectangle")
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
