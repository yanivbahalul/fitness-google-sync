import AVFoundation
import CoreImage
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
///
/// `@unchecked Sendable`: the capture state is only touched on `queue`, and the published
/// values only on the main queue, so the closures that hop between them are safe.
final class ScannerCamera: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate,
                           AVCapturePhotoCaptureDelegate, @unchecked Sendable {
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
    private var latestFrame: CVPixelBuffer?
    private let ciContext = CIContext()

    /// The current camera frame as an image (for the live look-up), or nil.
    func snapshot() async -> UIImage? {
        await withCheckedContinuation { continuation in
            queue.async {
                guard let frame = self.latestFrame,
                      let cg = self.ciContext.createCGImage(CIImage(cvPixelBuffer: frame),
                                                            from: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(frame),
                                                                         height: CVPixelBufferGetHeight(frame)))
                else { continuation.resume(returning: nil); return }
                continuation.resume(returning: UIImage(cgImage: cg))
            }
        }
    }

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
        latestFrame = pixels
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
    /// What the quick live look-up sees in the camera right now.
    @State private var liveItems: [FoodDraft] = []
    @State private var liveBusy = false
    /// Foods added live (tapped while aiming), before any photo.
    @State private var tray: [FoodDraft] = []
    /// Labels flying from a tapped food down to the Continue button.
    @State private var flyers: [Flyer] = []
    @State private var trayBump = false

    struct Flyer: Identifiable {
        let id = UUID()
        let text: String
        let from: CGPoint
        var arrived = false
    }

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
            .task { await liveLoop() }
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
        if !tray.isEmpty { return "נבחרו \(tray.count)" }
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
                            .stroke(.white.opacity(liveItems.isEmpty ? 1 : 0.4), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .frame(width: r.width, height: r.height)
                            .position(x: r.midX, y: r.midY)
                            .animation(.easeOut(duration: 0.25), value: camera.boxes)
                    }
                    // Recognized foods: tap the label to add it, no photo needed.
                    ForEach(liveItems) { item in
                        if let box = item.box {
                            let r = place(box, image: camera.frameSize, in: geo.size, fill: true)
                            Brackets()
                                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                .frame(width: r.width, height: r.height)
                                .position(x: r.midX, y: r.midY)
                            let at = CGPoint(x: min(max(r.midX, 90), geo.size.width - 90), y: max(r.minY - 24, 70))
                            liveChip(item, at: at, bottom: CGPoint(x: geo.size.width / 2, y: geo.size.height - 40))
                                .position(at)
                        }
                    }
                    // The "added" animation: the label shrinks and flies to Continue.
                    ForEach(flyers) { f in
                        Label(f.text, systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .frame(minHeight: DS.minTap)
                            .background(Color.green, in: Capsule())
                            .environment(\.layoutDirection, .rightToLeft)
                            .fixedSize()
                            .scaleEffect(f.arrived ? 0.35 : 1.1)
                            .opacity(f.arrived ? 0 : 1)
                            .position(f.arrived ? CGPoint(x: geo.size.width / 2, y: geo.size.height - 40) : f.from)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .environment(\.layoutDirection, .leftToRight)
            }
            .ignoresSafeArea()
            .overlay(alignment: .top) { liveStatus }
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
            let unplaced = liveItems.filter { $0.box == nil }
            if !unplaced.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) { ForEach(unplaced) { liveChip($0, at: nil, bottom: nil) } }
                }
            }
            if !tray.isEmpty {
                let kcal = tray.map(\.kcal).reduce(0, +)
                PrimaryButton(title: "המשך · \(tray.count) פריטים · \(Int(safe: kcal).formatted()) קק\"ל", symbol: "checkmark") {
                    drafts = tray
                    reviewing = true
                }
                .scaleEffect(trayBump ? 1.06 : 1)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
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

    /// A recognized food while aiming: name, amount, calories; tap to add.
    private func liveChip(_ item: FoodDraft, at point: CGPoint?, bottom: CGPoint?) -> some View {
        let added = tray.contains { $0.label == item.label }
        return Button {
            guard !added else { return }
            var copy = item
            copy.id = UUID()
            copy.box = nil
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { tray.append(copy) }
            if let point {
                let flyer = Flyer(text: item.label, from: point)
                flyers.append(flyer)
                DispatchQueue.main.async {
                    withAnimation(.easeIn(duration: 0.55)) {
                        if let i = flyers.firstIndex(where: { $0.id == flyer.id }) { flyers[i].arrived = true }
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    flyers.removeAll { $0.id == flyer.id }
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) { trayBump = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { trayBump = false }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: added ? "checkmark.circle.fill" : "plus.circle.fill")
                Text("\(item.label) · \(Int(safe: item.grams)) ג׳ · \(Int(safe: item.kcal)) קק\"ל")
                    .lineLimit(1)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(minHeight: DS.minTap)
            .background(added ? Color.green : Theme.accent, in: Capsule())
            .environment(\.layoutDirection, .rightToLeft)
            .fixedSize()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(added ? "\(item.label) נוסף" : "הוסף \(item.label), \(Int(safe: item.kcal)) קלוריות")
    }

    /// "Recognizing…" / what to do, at the top of the live view.
    private var liveStatus: some View {
        HStack(spacing: 6) {
            if liveBusy { ProgressView().controlSize(.small).tint(.white) }
            Text(liveItems.isEmpty ? (liveBusy ? "מזהה…" : "כוון אל האוכל") : "הקש על מאכל כדי להוסיף")
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.black.opacity(0.5), in: Capsule())
        .padding(.top, 8)
    }

    /// While aiming (no photo yet), look at the current frame every ~2.5 s with the fast
    /// model and show what it recognizes, so foods can be added without taking a photo.
    private func liveLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard image == nil, !reviewing, !liveBusy, camera.authorized == true,
                  !camera.boxes.isEmpty, AnthropicKeyStore.key != nil,
                  let frame = await camera.snapshot() else { continue }
            liveBusy = true
            if let found = try? await MealAnalyzer.analyze(image: frame, text: nil, live: true), image == nil {
                withAnimation(.easeOut(duration: 0.2)) { liveItems = found }
            }
            liveBusy = false
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
        liveItems = []
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
                drafts = tray + result
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
