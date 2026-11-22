import AVFoundation
import PhotosUI
import SwiftUI
import Vision

// Live meal scanner.
//
// While aiming, Apple's on-device Vision marks the distinct objects it sees (plates,
// cups, items) with frames in real time, so it's clear what's in view. After the shutter,
// Claude identifies each food and where it is, and the photo comes back with a labelled
// frame on every food (name, amount, calories). Tap a frame to include or skip it; if
// something wasn't recognized, type it.

// MARK: - Camera

/// Camera session: live preview, on-device object frames, and still capture.
final class ScannerCamera: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate,
                           AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    /// Objects in view: fractions of the frame, top-left origin, portrait.
    @Published var boxes: [CGRect] = []
    /// Size of the live frames (portrait), for placing the frames on screen.
    @Published var frameSize = CGSize(width: 1080, height: 1920)
    /// nil until the user answered the camera permission prompt.
    @Published var authorized: Bool?

    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "healthbridge.scanner")
    private var configured = false
    private var lastAnalysis = Date.distantPast
    private var onPhoto: ((UIImage) -> Void)?

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async { self.authorized = granted }
            guard granted else { return }
            self.queue.async {
                self.configureIfNeeded()
                if !self.session.isRunning { self.session.startRunning() }
            }
        }
    }

    func stop() {
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    private func configureIfNeeded() {
        guard !configured else { return }
        configured = true
        session.beginConfiguration()
        session.sessionPreset = .photo
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        for output in [videoOutput, photoOutput] as [AVCaptureOutput] {
            if let connection = output.connection(with: .video), connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
        }
        session.commitConfiguration()
    }

    // Live frames: find distinct objects a few times a second (on-device, no network).
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard Date().timeIntervalSince(lastAnalysis) > 0.3,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastAnalysis = Date()
        let size = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
        let request = VNGenerateObjectnessBasedSaliencyImageRequest()
        try? VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up).perform([request])
        let found = (request.results?.first?.salientObjects ?? [])
            .filter { $0.confidence > 0.3 && $0.boundingBox.width > 0.08 && $0.boundingBox.height > 0.05 }
            .map { o in CGRect(x: o.boundingBox.minX, y: 1 - o.boundingBox.maxY,
                               width: o.boundingBox.width, height: o.boundingBox.height) }
        DispatchQueue.main.async {
            self.frameSize = size
            self.boxes = found
        }
    }

    func capture(_ done: @escaping (UIImage) -> Void) {
        onPhoto = done
        photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let data = photo.fileDataRepresentation(), let image = UIImage(data: data) else { return }
        DispatchQueue.main.async {
            self.onPhoto?(image)
            self.onPhoto = nil
        }
    }
}

/// The live camera image.
private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

/// Places a fraction-of-image rectangle on screen for an image drawn aspect-fill or aspect-fit.
private func place(_ r: CGRect, image: CGSize, in view: CGSize, fill: Bool) -> CGRect {
    guard image.width > 0, image.height > 0 else { return .zero }
    let scale = fill ? max(view.width / image.width, view.height / image.height)
                     : min(view.width / image.width, view.height / image.height)
    let w = image.width * scale, h = image.height * scale
    let ox = (view.width - w) / 2, oy = (view.height - h) / 2
    return CGRect(x: ox + r.minX * w, y: oy + r.minY * h, width: r.width * w, height: r.height * h)
}

/// Corner brackets, the scanner look.
private struct Brackets: Shape {
    func path(in rect: CGRect) -> Path {
        let l = min(22, rect.width / 3, rect.height / 3)
        var p = Path()
        for (corner, dx, dy) in [(CGPoint(x: rect.minX, y: rect.minY), 1.0, 1.0),
                                 (CGPoint(x: rect.maxX, y: rect.minY), -1.0, 1.0),
                                 (CGPoint(x: rect.minX, y: rect.maxY), 1.0, -1.0),
                                 (CGPoint(x: rect.maxX, y: rect.maxY), -1.0, -1.0)] {
            p.move(to: CGPoint(x: corner.x + dx * l, y: corner.y))
            p.addLine(to: corner)
            p.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * l))
        }
        return p
    }
}

// MARK: - Scanner screen

struct MealScannerView: View {
    let day: Date
    /// Search or barcode chosen here; the parent opens it after the scanner closes.
    let onOther: (AddMode) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = ScannerCamera()
    @State private var image: UIImage?
    @State private var drafts: [FoodDraft] = []
    @State private var analyzing = false
    @State private var analyzed = false
    @State private var error: String?
    @State private var pickerItem: PhotosPickerItem?
    @State private var typing = false
    @State private var typedText = ""
    @State private var reviewing = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    ResultCanvas(image: image, drafts: $drafts, analyzing: analyzing)
                } else {
                    liveView
                }
            }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.body.weight(.semibold))
                    }
                    .accessibilityLabel("סגור")
                }
                ToolbarItem(placement: .principal) {
                    Text(title).font(.headline).foregroundStyle(.white)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $reviewing) {
                DraftReviewView(drafts: $drafts, source: .photo, day: day, image: image) { dismiss() }
                    .navigationTitle("בדיקה ושמירה")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .onAppear { camera.start() }
            .onDisappear { camera.stop() }
            .onChange(of: pickerItem) { item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let ui = UIImage(data: data) {
                        use(ui)
                    } else {
                        error = "התמונה לא נטענה (ייתכן שהיא שמורה רק ב‑iCloud)."
                    }
                }
            }
            .alert("מה יש בצלחת?", isPresented: $typing) {
                TextField("למשל: קפה הפוך גדול, 2 פרוסות לחם", text: $typedText)
                Button("הוסף") { Task { await analyze(typed: typedText) } }
                Button("ביטול", role: .cancel) {}
            } message: {
                Text(image == nil ? "תאר את הארוחה ואזהה אותה." : "תאר מה לא זוהה, ואוסיף את זה.")
            }
        }
        .environment(\.colorScheme, .dark)
        .appChrome()
    }

    private var title: String {
        if analyzing { return "מזהה…" }
        if image != nil && analyzed { return drafts.contains(where: \.include) ? "הקש על מאכל כדי לבחור" : "לא זוהה אוכל" }
        return "כוון אל הצלחת"
    }

    // MARK: Live

    @ViewBuilder private var liveView: some View {
        switch camera.authorized {
        case .some(false):
            VStack(spacing: 12) {
                Image(systemName: "camera.fill").font(.largeTitle)
                Text("אין גישה למצלמה. אפשר לאשר בהגדרות ← HealthBridge ← מצלמה, או לבחור תמונה מהגלריה.")
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.white)
            .padding(32)
        default:
            GeometryReader { geo in
                ZStack {
                    CameraPreview(session: camera.session)
                    ForEach(Array(camera.boxes.enumerated()), id: \.offset) { _, box in
                        let r = place(box, image: camera.frameSize, in: geo.size, fill: true)
                        Brackets()
                            .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .frame(width: r.width, height: r.height)
                            .position(x: r.midX, y: r.midY)
                            .animation(.easeOut(duration: 0.25), value: camera.boxes)
                    }
                }
                .environment(\.layoutDirection, .leftToRight)
            }
            .ignoresSafeArea()
            .accessibilityElement()
            .accessibilityLabel("מצלמה. כוון אל הצלחת ולחץ על כפתור הצילום.")
        }
    }

    // MARK: Bottom bar

    @ViewBuilder private var bottomBar: some View {
        VStack(spacing: 12) {
            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
            }
            if image != nil && analyzed && !analyzing {
                resultActions
            } else {
                captureControls
            }
        }
        .padding(.horizontal, DS.pagePadding)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private var captureControls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                chip("ברקוד", symbol: "barcode.viewfinder") { onOther(.barcode) }
                chip("חיפוש במאגר", symbol: "magnifyingglass") { onOther(.search) }
            }
            .disabled(analyzing)
            shutterRow
        }
    }

    private func chip(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(minHeight: 40)
                .background(.white.opacity(0.15), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var shutterRow: some View {
        HStack {
            PhotosPicker(selection: $pickerItem, matching: .images) {
                sideLabel("גלריה", symbol: "photo.on.rectangle")
            }
            .disabled(analyzing)
            Spacer()
            Button {
                camera.capture { use($0) }
            } label: {
                ZStack {
                    Circle().fill(.white).frame(width: 68, height: 68)
                    Circle().stroke(.white, lineWidth: 4).frame(width: 80, height: 80)
                }
            }
            .disabled(analyzing || camera.authorized != true || image != nil)
            .accessibilityLabel("צלם ונתח")
            Spacer()
            Button { typedText = ""; typing = true } label: {
                sideLabel("הקלדה", symbol: "keyboard")
            }
            .disabled(analyzing)
        }
    }

    private var resultActions: some View {
        VStack(spacing: 10) {
            if drafts.contains(where: \.include) {
                let kcal = drafts.filter(\.include).map(\.kcal).reduce(0, +)
                PrimaryButton(title: "המשך · \(Int(safe: kcal).formatted()) קק\"ל", symbol: "checkmark") {
                    reviewing = true
                }
            }
            HStack(spacing: 10) {
                Button { typedText = ""; typing = true } label: {
                    Label(drafts.isEmpty ? "לא זוהה, לחץ כדי להקליד" : "משהו חסר? הקלד", systemImage: "keyboard")
                        .frame(maxWidth: .infinity, minHeight: DS.minTap)
                }
                .buttonStyle(.bordered)
                Button { retake() } label: {
                    Label("צלם שוב", systemImage: "camera.rotate")
                        .frame(maxWidth: .infinity, minHeight: DS.minTap)
                }
                .buttonStyle(.bordered)
            }
            .font(.subheadline.weight(.semibold))
        }
    }

    private func sideLabel(_ title: String, symbol: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.title2)
            Text(title).font(.caption.weight(.semibold))
        }
        .foregroundStyle(.white)
        .frame(width: 72, height: 60)
    }

    // MARK: Actions

    private func use(_ photo: UIImage) {
        image = photo
        camera.stop()
        Task { await analyze(typed: nil) }
    }

    private func retake() {
        image = nil
        drafts = []
        analyzed = false
        error = nil
        camera.start()
    }

    /// Analyzes the photo (and/or a typed description). Typed text after a photo adds to
    /// what was already found.
    private func analyze(typed: String?) async {
        analyzing = true
        error = nil
        defer { analyzing = false; analyzed = true }
        do {
            let typedOnly = typed.map { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? false
            // A typed addition after a photo is analyzed as text, so it adds new foods only.
            let result = try await MealAnalyzer.analyze(image: (typedOnly && !drafts.isEmpty) ? nil : image, text: typed)
            if typedOnly && !drafts.isEmpty {
                drafts += result
            } else {
                drafts = result
            }
            if result.isEmpty { error = typedOnly ? "גם מהתיאור לא זוהה אוכל. נסה לנסח אחרת." : nil }
            if image == nil, !drafts.isEmpty { reviewing = true }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Result over the photo

/// The photo with a labelled frame on every food. Tap a frame to include or skip it.
private struct ResultCanvas: View {
    let image: UIImage
    @Binding var drafts: [FoodDraft]
    let analyzing: Bool
    @State private var pulse = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .opacity(analyzing ? 0.6 : 1)
                    .accessibilityHidden(true)

                if analyzing {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.large).tint(.white)
                        Text("מזהה את המאכלים…").font(.headline).foregroundStyle(.white)
                    }
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DS.cardRadius))
                }

                ForEach($drafts) { $draft in
                    if let box = draft.box {
                        let r = place(box, image: image.size, in: geo.size, fill: false)
                        Button {
                            draft.include.toggle()
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } label: {
                            ZStack(alignment: .topLeading) {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(draft.include ? Theme.accent : .white.opacity(0.7),
                                            style: StrokeStyle(lineWidth: 3, dash: draft.include ? [] : [6, 5]))
                                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.001)))
                                label(for: draft)
                                    .offset(y: r.minY > 44 ? -38 : 4)
                            }
                            .frame(width: r.width, height: r.height)
                        }
                        .buttonStyle(.plain)
                        .position(x: r.midX, y: r.midY)
                        .accessibilityLabel("\(draft.label), \(Int(safe: draft.grams)) גרם, \(Int(safe: draft.kcal)) קלוריות")
                        .accessibilityValue(draft.include ? "נבחר" : "לא נבחר")
                        .accessibilityHint("הקש כדי לבחור או לבטל")
                    }
                }
            }
            .environment(\.layoutDirection, .leftToRight)
        }
        .ignoresSafeArea(edges: .top)
        .overlay(alignment: .bottom) { unplacedList }
    }

    private func label(for draft: FoodDraft) -> some View {
        HStack(spacing: 4) {
            Image(systemName: draft.include ? "checkmark.circle.fill" : "circle")
            Text("\(draft.label) · \(Int(safe: draft.grams)) ג׳ · \(Int(safe: draft.kcal))")
                .lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(draft.include ? Theme.accent : Color.black.opacity(0.6), in: Capsule())
        .environment(\.layoutDirection, .rightToLeft)
        .fixedSize()
    }

    /// Foods the model found but couldn't place in the photo (e.g. a described drink).
    @ViewBuilder private var unplacedList: some View {
        let unplaced = drafts.indices.filter { drafts[$0].box == nil }
        if !unplaced.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(unplaced, id: \.self) { i in
                        Button { drafts[i].include.toggle() } label: {
                            label(for: drafts[i])
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, DS.pagePadding)
            }
            .padding(.bottom, 8)
        }
    }
}
