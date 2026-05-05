import SwiftUI
import Vision

/// Interactive document viewer that displays the original scanned image
/// with tappable text overlays. Users can select text and ask follow-up questions.
struct DocumentViewerView: View {
    let report: StructuredReport
    @EnvironmentObject var engine: InferenceEngine
    
    @State private var scanImage: UIImage?
    @State private var recognizedBlocks: [TextBlock] = []
    @State private var selectedBlocks: Set<UUID> = []
    @State private var showChat = false
    @State private var imageSize: CGSize = .zero
    
    struct TextBlock: Identifiable {
        let id = UUID()
        let text: String
        let boundingBox: CGRect // Normalized (0-1) coordinates from Vision
    }
    
    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()
            
            if let image = scanImage {
                GeometryReader { geo in
                    ScrollView {
                        ZStack(alignment: .topLeading) {
                            // Original scan image
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(width: geo.size.width)
                                .background(
                                    GeometryReader { imgGeo in
                                        Color.clear.onAppear {
                                            imageSize = imgGeo.size
                                        }
                                    }
                                )
                            
                            // Text overlay blocks (tappable)
                            ForEach(recognizedBlocks) { block in
                                let rect = convertRect(block.boundingBox, in: imageSize)
                                
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(selectedBlocks.contains(block.id)
                                          ? Color.blue.opacity(0.3)
                                          : Color.clear)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 3)
                                            .stroke(selectedBlocks.contains(block.id)
                                                    ? Color.blue : Color.clear, lineWidth: 2)
                                    )
                                    .frame(width: rect.width, height: rect.height)
                                    .position(x: rect.midX, y: rect.midY)
                                    .onTapGesture {
                                        withAnimation(.easeInOut(duration: 0.15)) {
                                            if selectedBlocks.contains(block.id) {
                                                selectedBlocks.remove(block.id)
                                            } else {
                                                selectedBlocks.insert(block.id)
                                            }
                                        }
                                    }
                            }
                        }
                    }
                }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "doc.questionmark")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("Original scan not available")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Scan Viewer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !selectedBlocks.isEmpty {
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        showChat = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles")
                            Text("Ask about \(selectedBlocks.count) selection\(selectedBlocks.count > 1 ? "s" : "")")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(.blue)
                        .foregroundColor(.white)
                        .cornerRadius(14)
                    }
                }
            }
        }
        .sheet(isPresented: $showChat) {
            FollowUpChatView(
                selectedText: getSelectedText(),
                fullReportContext: report.patientSummary,
                ocrText: report.rawText
            )
            .environmentObject(engine)
        }
        .onAppear {
            loadImage()
        }
    }
    
    private func loadImage() {
        guard let url = report.imageURL,
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else { return }
        
        scanImage = image
        recognizeText(in: image)
    }
    
    /// Runs VisionKit text recognition to get bounding boxes for each text block.
    private func recognizeText(in image: UIImage) {
        guard let cgImage = image.cgImage else { return }
        
        let request = VNRecognizeTextRequest { request, error in
            guard let observations = request.results as? [VNRecognizedTextObservation] else { return }
            
            DispatchQueue.main.async {
                self.recognizedBlocks = observations.compactMap { obs in
                    guard let topCandidate = obs.topCandidates(1).first else { return nil }
                    return TextBlock(text: topCandidate.string, boundingBox: obs.boundingBox)
                }
            }
        }
        
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        
        DispatchQueue.global(qos: .userInitiated).async {
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])
        }
    }
    
    /// Converts a normalized Vision bounding box to view coordinates.
    /// Vision uses bottom-left origin with normalized (0-1) coordinates.
    private func convertRect(_ visionRect: CGRect, in size: CGSize) -> CGRect {
        let x = visionRect.origin.x * size.width
        let y = (1 - visionRect.origin.y - visionRect.height) * size.height
        let w = visionRect.width * size.width
        let h = visionRect.height * size.height
        return CGRect(x: x, y: y, width: w, height: h)
    }
    
    private func getSelectedText() -> String {
        recognizedBlocks
            .filter { selectedBlocks.contains($0.id) }
            .map(\.text)
            .joined(separator: "\n")
    }
}

// MARK: - Follow-Up Chat View

struct FollowUpChatView: View {
    let selectedText: String
    let fullReportContext: String
    let ocrText: String
    @EnvironmentObject var engine: InferenceEngine
    @Environment(\.dismiss) var dismiss
    
    @State private var messages: [ChatMessage] = []
    @State private var inputText = ""
    @State private var isThinking = false
    
    struct ChatMessage: Identifiable {
        let id = UUID()
        let role: Role
        let content: String
        enum Role { case user, ai }
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Chat messages
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            // Context banner
                            GroupBox {
                                VStack(alignment: .leading, spacing: 8) {
                                    Label("Selected Text", systemImage: "text.quote")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.blue)
                                    Text(selectedText)
                                        .font(.system(size: 14))
                                        .foregroundStyle(.primary)
                                }
                            }
                            .padding(.horizontal)
                            
                            ForEach(messages) { message in
                                HStack(alignment: .top, spacing: 10) {
                                    if message.role == .ai {
                                        Image(systemName: "brain.head.profile")
                                            .font(.system(size: 20))
                                            .foregroundColor(.blue)
                                            .padding(.top, 2)
                                    }
                                    
                                    VStack(alignment: message.role == .user ? .trailing : .leading) {
                                        Text(message.content)
                                            .padding(12)
                                            .background(
                                                message.role == .user
                                                ? Color.blue
                                                : Color(.secondarySystemGroupedBackground)
                                            )
                                            .foregroundColor(message.role == .user ? .white : .primary)
                                            .cornerRadius(16)
                                    }
                                    .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
                                    
                                    if message.role == .user {
                                        Image(systemName: "person.circle.fill")
                                            .font(.system(size: 20))
                                            .foregroundColor(.secondary)
                                            .padding(.top, 2)
                                    }
                                }
                                .padding(.horizontal)
                                .id(message.id)
                            }
                            
                            if isThinking {
                                HStack(spacing: 10) {
                                    Image(systemName: "brain.head.profile")
                                        .font(.system(size: 20))
                                        .foregroundColor(.blue)
                                    ProgressView()
                                    Text("Thinking...")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal)
                            }
                        }
                        .padding(.vertical)
                    }
                    .onChange(of: messages.count) { _, _ in
                        if let last = messages.last {
                            withAnimation {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
                
                Divider()
                
                // Input bar
                HStack(spacing: 12) {
                    TextField("Ask about this text...", text: $inputText, axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                    
                    Button {
                        sendMessage()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(inputText.isEmpty ? .gray : .blue)
                    }
                    .disabled(inputText.isEmpty || isThinking)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
            }
            .navigationTitle("Ask MedGemma")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                // Auto-send the initial question about the selected text
                let autoQuestion = "What does this mean in simple terms? Is this normal?"
                inputText = autoQuestion
                sendMessage()
            }
        }
    }
    
    private func sendMessage() {
        let question = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        
        messages.append(ChatMessage(role: .user, content: question))
        inputText = ""
        isThinking = true
        
        Task {
            let answer = await engine.askFollowUp(
                question: question,
                selectedText: selectedText,
                reportContext: fullReportContext,
                ocrText: ocrText
            )
            messages.append(ChatMessage(role: .ai, content: answer))
            isThinking = false
        }
    }
}
