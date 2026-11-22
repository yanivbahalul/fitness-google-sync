import ARKit
import AVFoundation
import CoreImage
import PhotosUI
import RealityKit
import SwiftUI
import Vision

// Live meal scanner.
//
// While aiming, the current camera frame is sent to the fast model whenever the phone is
// still and the middle of the view isn't known yet. Each recognized food is anchored to
// its real place in the room with ARKit world tracking, so its label stays on the food
// while the phone moves, reappears at once when you come back to it, and is never asked
// about again in this session. While a look is in progress, its spot shows "processing"
// and waits there for the answer. The shutter takes a full photo for a precise analysis.

// MARK: - AR camera

/// ARKit session with world-anchored spots for recognized foods.
final class ARScanner: NSObject, ObservableObject, ARSessionDelegate, @unchecked Sendable {
    /// A place in the room: four corners and a center, in world coordinates (meters).
    struct Spot {
        var corners: [SIMD3<Float>]
        var center: SIMD3<Float>
    }

    /// nil until the user answered the camera permission prompt.
    @Published var authorized: Bool?
    /// Where each spot is on screen now (view points); missing = out of view.
    @Published private(set) var onScreen: [UUID: CGRect] = [:]
    /// The phone is moving (from ARKit's camera pose).
    @Published private(set) var moving = false
    /// When the phone last stopped moving.
    private(set) var stillSince = Date()

    private weak var view: ARView?
    private var spots: [UUID: Spot] = [:]
    private var lastPose: simd_float4x4?
    private var lastMove = Date.distantPast
    private var running = false
    private let ciContext = CIContext()

    func attach(_ view: ARView) {
        self.view = view
        view.session.delegate = self
        runIfReady()
    }

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                self.authorized = granted
                self.runIfReady()
            }
        }
    }

    func stop() {
        view?.session.pause()
        running = false
    }

    private func runIfReady() {
        guard authorized == true, !running, let view, ARWorldTrackingConfiguration.isSupported else { return }
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        view.session.run(config)
        running = true
    }

    // MARK: Spots

    func set(_ id: UUID, _ spot: Spot) { spots[id] = spot }

    func remove(_ id: UUID) {
        spots[id] = nil
        onScreen[id] = nil
    }

    /// Where a box from the camera image (portrait fractions) appears in the view.
    func viewRect(for box: CGRect, imageSize: CGSize) -> CGRect? {
        guard let view else { return nil }
        return place(box, image: imageSize, in: view.bounds.size, fill: true)
    }

    func center(of id: UUID) -> SIMD3<Float>? { spots[id]?.center }

    /// True when a known spot sits in the middle of the view: that area was already
    /// looked at (or is being looked at), so there's no need to ask again.
    func middleIsKnown() -> Bool {
        guard let view else { return false }
        let b = view.bounds
        let middle = CGRect(x: b.width * 0.2, y: b.height * 0.15, width: b.width * 0.6, height: b.height * 0.55)
        return onScreen.values.contains { middle.contains(CGPoint(x: $0.midX, y: $0.midY)) }
    }

    /// Anchors a box from a frame (fractions of the portrait image, top-left origin) to the
    /// room: the center hits the nearest surface, the corners sit at the same distance.
    func anchor(_ box: CGRect, from frame: ARFrame) -> Spot? {
        guard let session = view?.session else { return nil }
        // Portrait image fractions → the camera image's own (landscape) fractions.
        func imagePoint(_ u: CGFloat, _ v: CGFloat) -> CGPoint { CGPoint(x: v, y: 1 - u) }
        let query = frame.raycastQuery(from: imagePoint(box.midX, box.midY), allowing: .estimatedPlane, alignment: .any)
        let direction = simd_normalize(query.direction)
        let center: SIMD3<Float>
        if let hit = session.raycast(query).first {
            let p = hit.worldTransform.columns.3
            center = SIMD3(p.x, p.y, p.z)
        } else {
            center = query.origin + direction * 0.45
        }
        let distance = simd_distance(center, query.origin)
        let corners = [(box.minX, box.minY), (box.maxX, box.minY), (box.minX, box.maxY), (box.maxX, box.maxY)]
            .map { (u, v) -> SIMD3<Float> in
                let q = frame.raycastQuery(from: imagePoint(u, v), allowing: .estimatedPlane, alignment: .any)
                return q.origin + simd_normalize(q.direction) * distance
            }
        return Spot(corners: corners, center: center)
    }

    // MARK: Frames

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let pose = frame.camera.transform
        if let last = lastPose {
            let moved = simd_distance(SIMD3(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z),
                                      SIMD3(last.columns.3.x, last.columns.3.y, last.columns.3.z))
            let f1 = simd_normalize(SIMD3(pose.columns.2.x, pose.columns.2.y, pose.columns.2.z))
            let f0 = simd_normalize(SIMD3(last.columns.2.x, last.columns.2.y, last.columns.2.z))
            let turned = acos(min(1, max(-1, simd_dot(f1, f0))))
            let now = Date()
            if moved > 0.002 || turned > 0.005 {
                lastMove = now
                if !moving { moving = true }
            } else if moving, now.timeIntervalSince(lastMove) > 0.3 {
                moving = false
                stillSince = now
            }
        }
        lastPose = pose
        project(frame)
    }

    private func project(_ frame: ARFrame) {
        guard let view, !spots.isEmpty else {
            if !onScreen.isEmpty { onScreen = [:] }
            return
        }
        let toCamera = frame.camera.transform.inverse
        func inFront(_ p: SIMD3<Float>) -> Bool { (toCamera * SIMD4(p.x, p.y, p.z, 1)).z < -0.05 }
        var next: [UUID: CGRect] = [:]
        for (id, spot) in spots where inFront(spot.center) {
            let points = spot.corners.filter(inFront).compactMap { view.project($0) }
            guard points.count >= 2 else { continue }
            let xs = points.map(\.x), ys = points.map(\.y)
            var rect = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            rect = rect.insetBy(dx: min(0, (rect.width - 56) / 2), dy: min(0, (rect.height - 56) / 2))
            guard rect.intersects(view.bounds) else { continue }
            // Smooth out the tiny frame-to-frame tremble of the camera pose (strongest up
            // close); a big jump (the spot just came into view) is taken as is.
            if let old = onScreen[id], abs(old.midX - rect.midX) + abs(old.midY - rect.midY) < 160 {
                let k: CGFloat = 0.3
                rect = CGRect(x: old.minX + (rect.minX - old.minX) * k, y: old.minY + (rect.minY - old.minY) * k,
                              width: old.width + (rect.width - old.width) * k,
                              height: old.height + (rect.height - old.height) * k)
            }
            next[id] = rect
        }
        onScreen = next
    }

    // MARK: Images

    /// Snaps a rough box from the model (fractions of `image`, top-left origin) to the
    /// object the phone sees there, so the frame sits on that one cup or plate. Uses
    /// Vision's per-object segmentation (iOS 17+), which keeps neighbouring things apart;
    /// a candidate much bigger than the model's box (two objects merged) is rejected.
    func refine(_ box: CGRect, in image: UIImage) -> CGRect {
        guard let cg = image.cgImage else { return box }
        let objects = Self.detectObjects(cg)
        func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
            let i = a.intersection(b)
            guard !i.isNull, i.width > 0, i.height > 0 else { return 0 }
            let u = a.union(b)
            return (i.width * i.height) / (u.width * u.height)
        }
        let area = box.width * box.height
        let center = CGPoint(x: box.midX, y: box.midY)
        let fitting = objects.filter { o in
            o.width * o.height <= area * 2.5 && (o.contains(center) || overlap(o, box) > 0.15)
        }
        return fitting.max { overlap($0, box) < overlap($1, box) } ?? box
    }

    /// The separate objects in an image (fractions, top-left origin): per-object
    /// segmentation on iOS 17+, saliency otherwise.
    static func detectObjects(_ cg: CGImage) -> [CGRect] {
        if #available(iOS 17.0, *) {
            let boxes = instanceBoxes(cg)
            if !boxes.isEmpty { return boxes }
        }
        let request = VNGenerateObjectnessBasedSaliencyImageRequest()
        try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
        return (request.results?.first?.salientObjects ?? []).map { o in
            CGRect(x: o.boundingBox.minX, y: 1 - o.boundingBox.maxY, width: o.boundingBox.width, height: o.boundingBox.height)
        }
    }

    // MARK: Visual memory

    /// A visual fingerprint of every food recognized in this session, to find it again on
    /// the phone itself (no network) when it shows up somewhere else.
    private var prints: [UUID: VNFeaturePrintObservation] = [:]

    @discardableResult
    func remember(_ id: UUID, box: CGRect, in image: UIImage) -> VNFeaturePrintObservation? {
        guard let cg = image.cgImage, let print = Self.featurePrint(box, in: cg) else { return nil }
        prints[id] = print
        return print
    }

    func forget(_ id: UUID) { prints[id] = nil }

    var rememberedPrints: [(UUID, VNFeaturePrintObservation)] { prints.map { ($0.key, $0.value) } }

    static func featurePrint(_ box: CGRect, in cg: CGImage) -> VNFeaturePrintObservation? {
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let rect = CGRect(x: box.minX * w, y: box.minY * h, width: box.width * w, height: box.height * h).integral
        guard rect.width >= 16, rect.height >= 16, let crop = cg.cropping(to: rect) else { return nil }
        let request = VNGenerateImageFeaturePrintRequest()
        request.imageCropAndScaleOption = .scaleFill
        try? VNImageRequestHandler(cgImage: crop, options: [:]).perform([request])
        return request.results?.first
    }

    /// Finds remembered foods among the objects in `image`: each object's fingerprint is
    /// compared with the remembered ones; a close enough match is that food. Runs on the
    /// phone in a few tens of milliseconds.
    /// `strictness` per fingerprint: 1 for this session's foods, lower (stricter) for
    /// foods from earlier sessions, where light and angle differ more.
    static func findRemembered(in image: UIImage, among prints: [(UUID, VNFeaturePrintObservation, Float)]) -> [(UUID, CGRect)] {
        guard !prints.isEmpty, let cg = image.cgImage else { return [] }
        // Fingerprints from the newer model (iOS 17+) are normalized: same object ≈ 0.2-0.5,
        // different objects ≈ 0.8+. The older model uses a much larger scale.
        let threshold: Float
        if #available(iOS 17.0, *) { threshold = 0.6 } else { threshold = 16 }
        var used = Set<UUID>()
        var found: [(UUID, CGRect)] = []
        let objects = detectObjects(cg).sorted { $0.width * $0.height > $1.width * $1.height }.prefix(6)
        for object in objects {
            guard let print = featurePrint(object, in: cg) else { continue }
            // Nearest neighbour per food (a food can have several example fingerprints).
            var nearest: [UUID: (distance: Float, limit: Float)] = [:]
            for (id, known, strictness) in prints where !used.contains(id) {
                var distance: Float = .greatestFiniteMagnitude
                try? print.computeDistance(&distance, to: known)
                if distance < (nearest[id]?.distance ?? .greatestFiniteMagnitude) {
                    nearest[id] = (distance, threshold * strictness)
                }
            }
            let ranked = nearest.sorted { $0.value.distance < $1.value.distance }
            guard let best = ranked.first, best.value.distance < best.value.limit else { continue }
            // Ambiguous (two foods almost equally close): don't guess, let Claude decide.
            if ranked.count > 1, best.value.distance > ranked[1].value.distance * 0.85 { continue }
            used.insert(best.key)
            found.append((best.key, object))
        }
        return found
    }

    /// How good a crop is as an example: bigger and better-looking (sharp, well lit) is
    /// better. Uses Vision's image-quality model on iOS 18+.
    static func quality(_ box: CGRect, in image: UIImage) -> Float {
        guard let cg = image.cgImage else { return 0 }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let rect = CGRect(x: box.minX * w, y: box.minY * h, width: box.width * w, height: box.height * h).integral
        var score = Float(box.width * box.height)
        if #available(iOS 18.0, *), let crop = cg.cropping(to: rect) {
            let request = VNCalculateImageAestheticsScoresRequest()
            try? VNImageRequestHandler(cgImage: crop, options: [:]).perform([request])
            if let overall = request.results?.first?.overallScore { score *= (1 + overall) }
        }
        return score
    }

    /// Bounding boxes of the separate objects Vision finds (fractions, top-left origin).
    @available(iOS 17.0, *)
    private static func instanceBoxes(_ cg: CGImage) -> [CGRect] {
        let request = VNGenerateForegroundInstanceMaskRequest()
        try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
        guard let result = request.results?.first else { return [] }
        let mask = result.instanceMask
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return [] }
        let w = CVPixelBufferGetWidth(mask), h = CVPixelBufferGetHeight(mask)
        let rowBytes = CVPixelBufferGetBytesPerRow(mask)
        var minX = [Int: Int](), minY = [Int: Int](), maxX = [Int: Int](), maxY = [Int: Int]()
        for y in 0..<h {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w {
                let label = Int(row[x])
                guard label != 0 else { continue }
                minX[label] = min(minX[label] ?? x, x); maxX[label] = max(maxX[label] ?? x, x)
                minY[label] = min(minY[label] ?? y, y); maxY[label] = max(maxY[label] ?? y, y)
            }
        }
        return minX.keys.compactMap { label in
            guard let x0 = minX[label], let x1 = maxX[label], let y0 = minY[label], let y1 = maxY[label] else { return nil }
            return CGRect(x: CGFloat(x0) / CGFloat(w), y: CGFloat(y0) / CGFloat(h),
                          width: CGFloat(x1 - x0 + 1) / CGFloat(w), height: CGFloat(y1 - y0 + 1) / CGFloat(h))
        }
    }

    /// The current frame as a small portrait image for the live look-up, with the frame
    /// itself (its camera pose anchors the answer to the room).
    func snapshot() -> (UIImage, ARFrame)? {
        guard let frame = view?.session.currentFrame, let image = image(from: frame.capturedImage, maxSide: 512) else { return nil }
        return (image, frame)
    }

    /// A full photo (the highest resolution ARKit offers).
    func capture(_ done: @escaping (UIImage) -> Void) {
        guard let session = view?.session else { return }
        session.captureHighResolutionFrame { frame, _ in
            guard let pixels = (frame ?? session.currentFrame)?.capturedImage,
                  let image = self.image(from: pixels, maxSide: nil) else { return }
            DispatchQueue.main.async { done(image) }
        }
    }

    private func image(from pixels: CVPixelBuffer, maxSide: CGFloat?) -> UIImage? {
        var ci = CIImage(cvPixelBuffer: pixels).oriented(.right)
        if let maxSide {
            let scale = min(1, maxSide / max(ci.extent.width, ci.extent.height))
            ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// The live AR camera image.
private struct ARCameraView: UIViewRepresentable {
    let scanner: ARScanner

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        scanner.attach(view)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
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
    @StateObject private var camera = ARScanner()
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
    /// Spots with a look still in progress ("processing" waits there).
    @State private var pending: Set<UUID> = []
    /// The on-phone model's instant guess for the spot being looked at (before Claude).
    @State private var quickGuess: FoodDraft?
    /// Scanner item id → its entry in the on-phone food memory.
    @State private var memoryLink: [UUID: UUID] = [:]
    /// The food being corrected ("this is actually…"), and what the user typed.
    @State private var correcting: FoodDraft?
    @State private var correctionText = ""
    @State private var showCorrection = false
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
                    ResultCanvas(image: image, drafts: $drafts, analyzing: analyzing) { startCorrection($0) }
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
            .alert("מה זה באמת?", isPresented: $showCorrection) {
                TextField("למשל: סוכריות גומי GOOM", text: $correctionText)
                Button("עדכן") {
                    if let item = correcting { Task { await correct(item, as: correctionText) } }
                }
                Button("ביטול", role: .cancel) {}
            } message: {
                Text(correcting.map { "זוהה כ\"\($0.label)\". כתוב מה זה, ואעדכן את הערכים." } ?? "")
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
                    ARCameraView(scanner: camera)
                    // A steady aiming frame in the middle while nothing known is in view.
                    if camera.onScreen.isEmpty {
                        let side = min(geo.size.width, geo.size.height) * 0.62
                        Brackets()
                            .stroke(.white.opacity(0.75), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .frame(width: side, height: side)
                            .position(x: geo.size.width / 2, y: geo.size.height * 0.45)
                            .allowsHitTesting(false)
                    }
                    // A look in progress waits at its spot until the answer arrives.
                    ForEach(Array(pending), id: \.self) { id in
                        if let r = camera.onScreen[id] {
                            ProcessingSpot()
                                .frame(width: r.width, height: r.height)
                                .position(x: r.midX, y: r.midY)
                                .allowsHitTesting(false)
                            // The instant guess, tappable already; Claude confirms in a moment.
                            if let guess = quickGuess {
                                let at = CGPoint(x: min(max(r.midX, 90), geo.size.width - 90), y: max(r.minY - 24, 70))
                                liveChip(guess, at: at, bottom: CGPoint(x: geo.size.width / 2, y: geo.size.height - 40))
                                    .opacity(0.9)
                                    .position(at)
                            }
                        }
                    }
                    // Recognized foods stay on the food (anchored in the room); tap to add.
                    ForEach(liveItems) { item in
                        if let r = camera.onScreen[item.id] {
                            Brackets()
                                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                .frame(width: r.width, height: r.height)
                                .position(x: r.midX, y: r.midY)
                                .allowsHitTesting(false)
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
            let unplaced = liveItems.filter { camera.center(of: $0.id) == nil }
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
        .accessibilityHint("לחיצה ארוכה לתיקון אם זוהה לא נכון")
        .contextMenu {
            Button { startCorrection(item) } label: { Label("זה בעצם…", systemImage: "pencil") }
        }
    }

    private func startCorrection(_ item: FoodDraft) {
        correcting = item
        correctionText = ""
        showCorrection = true
    }

    /// Replaces a misrecognized food with what the user says it is (values from the
    /// accurate model, same place and roughly the same amount).
    private func correct(_ item: FoodDraft, as text: String) async {
        let name = text.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        do {
            let result = try await MealAnalyzer.analyze(
                image: nil, text: "\(name). כמות משוערת לפי התמונה: \(Int(safe: item.grams)) גרם.")
            guard var fixed = result.first else {
                error = "לא הצלחתי למצוא ערכים ל\"\(name)\". נסה לנסח אחרת."
                return
            }
            fixed.id = item.id
            fixed.box = item.box
            // Learn the correction, so this food is recognized correctly next time.
            if let entry = memoryLink[item.id] { FoodMemory.shared.correct(entry, with: fixed) }
            withAnimation(.easeOut(duration: 0.2)) {
                if let i = liveItems.firstIndex(where: { $0.id == item.id }) { liveItems[i] = fixed }
                if let i = drafts.firstIndex(where: { $0.id == item.id }) { drafts[i] = fixed }
                // Already added before the fix: replace the added copy too.
                if let i = tray.firstIndex(where: { $0.label == item.label }) {
                    var copy = fixed
                    copy.id = tray[i].id
                    copy.box = nil
                    tray[i] = copy
                }
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// "Recognizing…" / what to do, at the top of the live view.
    private var liveStatus: some View {
        HStack(spacing: 6) {
            if liveBusy { ProgressView().controlSize(.small).tint(.white) }
            Text(liveBusy ? "מזהה…" : (liveItems.isEmpty ? "כוון אל האוכל והחזק רגע" : "הקש על מאכל כדי להוסיף"))
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.black.opacity(0.5), in: Capsule())
        .padding(.top, 8)
    }

    /// While aiming (no photo yet): whenever the phone is still and the middle of the view
    /// isn't known yet, look at the frame with the fast model. Answers are anchored to the
    /// room from the frame they were taken from, so moving meanwhile doesn't matter.
    private func liveLoop() async {
        var lastLocalLook = Date.distantPast
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard image == nil, !reviewing, !liveBusy, camera.authorized == true, !camera.moving,
                  Date().timeIntervalSince(camera.stillSince) > 0.3 else { continue }

            // 1. On the phone: find remembered foods in view (e.g. the cup was moved) and put
            //    their labels there at once, without asking Claude again.
            let remembered = camera.rememberedPrints.map { ($0.0, $0.1, Float(1)) }
                + FoodMemory.shared.prints(excluding: Set(memoryLink.values)).map { ($0.0, $0.1, Float(0.8)) }
            if !remembered.isEmpty, Date().timeIntervalSince(lastLocalLook) > 0.6, let snap = camera.snapshot() {
                lastLocalLook = Date()
                let (frame, arFrame) = snap
                let matches = await Task.detached(priority: .userInitiated) {
                    ARScanner.findRemembered(in: frame, among: remembered)
                }.value
                for (matchID, box) in matches {
                    var id = matchID
                    // A food from an earlier session: bring it into this scan from memory.
                    if !liveItems.contains(where: { $0.id == matchID }) {
                        guard var item = FoodMemory.shared.draft(for: matchID) else { continue }
                        item.box = box
                        id = item.id
                        memoryLink[id] = matchID
                        camera.remember(id, box: box, in: frame)
                        withAnimation(.easeOut(duration: 0.25)) { liveItems.append(item) }
                    }
                    // Already shown right there: leave it. Elsewhere or out of view: move it here.
                    if let shown = camera.onScreen[id], let here = camera.viewRect(for: box, imageSize: frame.size),
                       here.contains(CGPoint(x: shown.midX, y: shown.midY)) { continue }
                    if let spot = camera.anchor(box, from: arFrame) {
                        withAnimation(.easeOut(duration: 0.2)) { camera.set(id, spot) }
                    }
                }
            }

            // 2. Ask Claude only about what's new in the middle of the view.
            guard !camera.middleIsKnown(), AnthropicKeyStore.key != nil, let snap = camera.snapshot() else { continue }
            let (frame, arFrame) = snap

            // Mark the spot being looked at: it shows "processing" and isn't asked again.
            let lookID = UUID()
            if let spot = camera.anchor(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.35), from: arFrame) {
                camera.set(lookID, spot)
                pending.insert(lookID)
            }
            liveBusy = true
            // Instant guess on the phone while Claude looks (only when the model is bundled).
            if QuickFoodGuess.isAvailable {
                let guess = await Task.detached(priority: .userInitiated) {
                    QuickFoodGuess.guess(frame, region: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.45))
                }.value
                if let guess { withAnimation(.easeOut(duration: 0.15)) { quickGuess = QuickFoodGuess.draft(for: guess) } }
            }
            let found = (try? await MealAnalyzer.analyze(image: frame, text: nil, live: true)) ?? []
            liveBusy = false
            withAnimation(.easeOut(duration: 0.15)) { quickGuess = nil }
            pending.remove(lookID)
            guard image == nil else { camera.remove(lookID); continue }

            var added = false
            for item in found {
                if let rough = item.box {
                    let box = camera.refine(rough, in: frame)
                    guard let spot = camera.anchor(box, from: arFrame) else { continue }
                    // The same food seen again: it's the one already found. If it's somewhere
                    // else now (the cup was moved), move its frame there and resize it.
                    if let known = liveItems.first(where: { $0.label == item.label }) {
                        camera.set(known.id, spot)
                        if let print = camera.remember(known.id, box: box, in: frame) {
                            memoryLink[known.id] = FoodMemory.shared.learn(known, print: print,
                                                                           quality: ARScanner.quality(box, in: frame),
                                                                           foodID: memoryLink[known.id])
                        }
                        added = true
                        continue
                    }
                    camera.set(item.id, spot)
                    if let print = camera.remember(item.id, box: box, in: frame) {
                        memoryLink[item.id] = FoodMemory.shared.learn(item, print: print,
                                                                      quality: ARScanner.quality(box, in: frame))
                    }
                    withAnimation(.easeOut(duration: 0.25)) { liveItems.append(item) }
                    added = true
                } else if item.box == nil, !liveItems.contains(where: { $0.label == item.label }) {
                    withAnimation(.easeOut(duration: 0.25)) { liveItems.append(item) }
                }
            }
            if added {
                camera.remove(lookID)
            } else {
                // Nothing there: remember the empty spot for a while so it isn't asked again
                // right away, then let it be looked at again (food may be put down later).
                Task {
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    camera.remove(lookID)
                }
            }
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
    /// Long-press a frame: "this is actually…".
    let onCorrect: (FoodDraft) -> Void
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
                        .accessibilityHint("הקש כדי לבחור או לבטל. לחיצה ארוכה לתיקון")
                        .contextMenu {
                            Button { onCorrect(draft) } label: { Label("זה בעצם…", systemImage: "pencil") }
                        }
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

/// A spot still being recognized: pulsing frame with "processing".
private struct ProcessingSpot: View {
    @State private var pulse = false

    var body: some View {
        ZStack {
            Brackets()
                .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .opacity(pulse ? 1 : 0.45)
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).tint(.white)
                Text("מעבד…")
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.55), in: Capsule())
            .environment(\.layoutDirection, .rightToLeft)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}
