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
                
                // Hero Icon
                ZStack {
                    Circle()
                        .fill(.blue.opacity(0.1))
                        .frame(width: 96, height: 96)
                    Image(systemName: "doc.text.viewfinder")
                        .font(.system(size: 44))
                        .foregroundColor(.blue)
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
                
                // Action Buttons or Processing Status
                VStack(spacing: 14) {
                    if engine.isProcessing {
                        GroupBox {
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
                            .padding(.vertical, 4)
                        }
                    } else {
                        Button {
                            requestCameraAndOpen()
                        } label: {
                            Label("Open Camera", systemImage: "camera.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!engine.isModelLoaded)
                        
                        PhotosPicker(selection: $pickerItem, matching: .images) {
                            Label("Choose from Photos", systemImage: "photo.on.rectangle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(!engine.isModelLoaded)
                        
                        if !engine.isModelLoaded {
                            Text("Download MedGemma in your Profile first.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                        }
                    }
                }
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
    
    /// Checks camera permission, then opens Apple's native camera UI.
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
// Now that we request permission BEFORE presenting, the black screen issue is resolved.
// UIImagePickerController gives us all of Apple's built-in camera features for free:
// lens switching, pinch-to-zoom, exposure, and the standard shutter button.

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
