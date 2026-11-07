import PhotosUI
import SwiftUI
import VisionKit

// MARK: - Review before saving

/// Shows what was recognized (photo / text / barcode), lets the user fix matches and
/// amounts, then saves to the diary and Apple Health.
struct DraftReviewView: View {
    @Binding var drafts: [FoodDraft]
    let source: FoodEntry.Source
    let day: Date
    let onSaved: () -> Void
    @State private var saving = false

    var body: some View {
        List {
            Section {
                ForEach($drafts) { $draft in
                    DraftRow(draft: $draft)
                }
            } footer: {
                Text("הקלוריות מחושבות לפי מאגר צמרת של משרד הבריאות. אם אין התאמה, משתמשים בהערכה. אפשר לשנות התאמה וכמות.")
            }
            Section {
                let total = drafts.filter(\.include).map(\.kcal).reduce(0, +)
                HStack {
                    Text("סה\"כ").font(.headline)
                    Spacer()
                    Text("\(Int(total).formatted()) קק\"ל").font(.headline).monospacedDigit()
                }
                Button {
                    saving = true
                    Task {
                        await FoodLog.shared.add(drafts, source: source, at: FoodLog.entryDate(for: day))
                        saving = false
                        onSaved()
                    }
                } label: {
                    HStack {
                        if saving { ProgressView() }
                        Text("שמור ביומן").bold()
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(saving || !drafts.contains(where: \.include))
            }
        }
    }
}

private struct DraftRow: View {
    @Binding var draft: FoodDraft
    @State private var gramsText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Toggle(isOn: $draft.include) { EmptyView() }
                    .labelsHidden()
                    .accessibilityLabel("כלול את \(draft.displayName)")
                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.label).font(.body.weight(.semibold))
                    Menu {
                        ForEach(FoodDatabase.shared.search(draft.label, limit: 12)) { item in
                            Button("\(item.name) · \(Int(item.kcal)) ל‑100 ג׳") { draft.food = item }
                        }
                        Button("בלי התאמה (הערכה)") { draft.food = nil }
                    } label: {
                        HStack(spacing: 4) {
                            Text(draft.food?.name ?? "ללא התאמה במאגר: הערכה")
                                .font(.caption)
                                .multilineTextAlignment(.leading)
                                .lineLimit(2)
                            Image(systemName: "chevron.down").font(.caption2)
                        }
                    }
                    .accessibilityLabel("התאמה במאגר: \(draft.food?.name ?? "ללא")")
                }
                Spacer()
                Text("\(Int(draft.kcal))")
                    .font(.headline)
                    .monospacedDigit()
            }
            HStack(spacing: 8) {
                Text("כמות")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("גרם", text: $gramsText)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .onChange(of: gramsText) { value in
                        if let g = Double(value.replacingOccurrences(of: ",", with: ".")), g > 0 { draft.grams = g }
                    }
                Text("ג׳").font(.caption)
                if let portions = draft.food?.portions, !portions.isEmpty {
                    Menu {
                        ForEach(portions, id: \.self) { p in
                            Button("\(p.name) (\(Int(p.grams)) ג׳)") {
                                draft.grams = p.grams
                                gramsText = String(Int(p.grams))
                            }
                        }
                    } label: {
                        Label("מנה", systemImage: "square.stack.3d.down.right")
                            .font(.caption)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .opacity(draft.include ? 1 : 0.5)
        .onAppear { gramsText = String(Int(draft.grams)) }
    }
}

// MARK: - Photo

struct PhotoAnalyzeView: View {
    let day: Date
    @Environment(\.dismiss) private var dismiss
    @State private var showCamera = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var note = ""
    @State private var drafts: [FoodDraft] = []
    @State private var analyzing = false
    @State private var error: String?
    @State private var started: Date?

    var body: some View {
        NavigationStack {
            Group {
                if !drafts.isEmpty {
                    DraftReviewView(drafts: $drafts, source: .photo, day: day) { dismiss() }
                } else {
                    ScrollView {
                        VStack(spacing: 16) {
                            if let image {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxHeight: 280)
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                                    .accessibilityLabel("תמונת הארוחה")
                            } else {
                                Image(systemName: "camera.metering.matrix")
                                    .font(.system(size: 56))
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 24)
                                Text("צלם את הצלחת מלמעלה, באור טוב, כשכל המאכלים נראים.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            HStack {
                                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                                    Button { showCamera = true } label: {
                                        Label("צלם", systemImage: "camera.fill").frame(maxWidth: .infinity, minHeight: 44)
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                                PhotosPicker(selection: $pickerItem, matching: .images) {
                                    Label("מהגלריה", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity, minHeight: 44)
                                }
                                .buttonStyle(.bordered)
                            }
                            TextField("הערה (לא חובה), למשל \"חצי מנה\"", text: $note)
                                .textFieldStyle(.roundedBorder)
                            if image != nil {
                                Button {
                                    Task { await analyze() }
                                } label: {
                                    HStack {
                                        if analyzing { ProgressView().tint(.white) }
                                        Text(analyzing ? "מנתח את הארוחה…" : "נתח ארוחה").bold()
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 48)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(analyzing)
                                if analyzing {
                                    Text("בדרך כלל 5–15 שניות.").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            if let error { Notice(symbol: "exclamationmark.triangle.fill", color: .red, text: error) }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle("ארוחה מצילום")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("ביטול") { dismiss() } } }
            .sheet(isPresented: $showCamera) {
                CameraPicker { image = $0 }.ignoresSafeArea()
            }
            .onChange(of: pickerItem) { item in
                Task {
                    if let data = try? await item?.loadTransferable(type: Data.self), let ui = UIImage(data: data) {
                        image = ui
                    }
                }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
    }

    private func analyze() async {
        analyzing = true
        error = nil
        defer { analyzing = false }
        do {
            let result = try await MealAnalyzer.analyze(image: image, text: note)
            if result.isEmpty { error = "לא זוהה אוכל בתמונה." } else { drafts = result }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Wraps the system camera.
struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

// MARK: - Text description

struct TextAnalyzeView: View {
    let day: Date
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var drafts: [FoodDraft] = []
    @State private var analyzing = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if !drafts.isEmpty {
                    DraftReviewView(drafts: $drafts, source: .text, day: day) { dismiss() }
                } else {
                    Form {
                        Section {
                            TextEditor(text: $text)
                                .frame(minHeight: 120)
                        } header: {
                            Text("מה אכלת?")
                        } footer: {
                            Text("למשל: \"2 פרוסות לחם מלא עם חומוס, ביצה קשה וסלט ירקות קטן\"")
                        }
                        Section {
                            Button {
                                Task { await analyze() }
                            } label: {
                                HStack {
                                    if analyzing { ProgressView() }
                                    Text(analyzing ? "מנתח…" : "נתח").bold()
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .disabled(analyzing || text.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        if let error {
                            Section { Text(error).foregroundStyle(.red).font(.footnote) }
                        }
                    }
                }
            }
            .navigationTitle("תיאור ארוחה")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("ביטול") { dismiss() } } }
        }
        .environment(\.layoutDirection, .rightToLeft)
    }

    private func analyze() async {
        analyzing = true
        error = nil
        defer { analyzing = false }
        do {
            let result = try await MealAnalyzer.analyze(image: nil, text: text)
            if result.isEmpty { error = "לא זוהה אוכל בתיאור." } else { drafts = result }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Search (Tzameret)

struct FoodSearchView: View {
    let day: Date
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [FoodItem] = []
    @State private var drafts: [FoodDraft] = []

    var body: some View {
        NavigationStack {
            Group {
                if !drafts.isEmpty {
                    DraftReviewView(drafts: $drafts, source: .search, day: day) { dismiss() }
                } else {
                    List(results) { item in
                        Button {
                            let grams = item.portions.first(where: { $0.name.contains("בינונית") })?.grams
                                ?? item.portions.first?.grams ?? 100
                            drafts = [FoodDraft(label: item.name, food: item, grams: grams,
                                                kcalPer100: item.kcal, proteinPer100: item.protein,
                                                carbsPer100: item.carbs, fatPer100: item.fat)]
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name).foregroundStyle(.primary)
                                Text("\(Int(item.kcal)) קק\"ל ל‑100 ג׳ · חלבון \(String(format: "%.1f", item.protein)) ג׳")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .overlay {
                        if results.isEmpty {
                            Text(query.isEmpty ? "חפש מאכל בעברית, למשל \"שניצל עוף\" או \"חומוס\"" : "לא נמצאו תוצאות")
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding()
                        }
                    }
                    .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "חיפוש במאגר צמרת")
                    .onChange(of: query) { q in
                        let current = q
                        Task.detached(priority: .userInitiated) {
                            let found = FoodDatabase.shared.search(current)
                            await MainActor.run { if current == query { results = found } }
                        }
                    }
                }
            }
            .navigationTitle("חיפוש מאכל")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("ביטול") { dismiss() } } }
        }
        .environment(\.layoutDirection, .rightToLeft)
    }
}

// MARK: - Barcode

struct BarcodeAddView: View {
    let day: Date
    @Environment(\.dismiss) private var dismiss
    @State private var code: String?
    @State private var drafts: [FoodDraft] = []
    @State private var looking = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if !drafts.isEmpty {
                    DraftReviewView(drafts: $drafts, source: .barcode, day: day) { dismiss() }
                } else if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    ZStack(alignment: .bottom) {
                        BarcodeScanner { scanned in
                            guard code == nil else { return }
                            code = scanned
                            Task { await lookup(scanned) }
                        }
                        .ignoresSafeArea()
                        VStack(spacing: 8) {
                            if looking { ProgressView("מחפש את המוצר…") }
                            if let error {
                                Text(error).font(.footnote)
                                Button("סרוק שוב") { code = nil; self.error = nil }
                                    .buttonStyle(.borderedProminent)
                            } else if !looking {
                                Text("כוון את המצלמה לברקוד של המוצר").font(.footnote)
                            }
                        }
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .padding()
                    }
                } else {
                    Text("סריקת ברקוד לא זמינה במכשיר הזה (צריך לאשר גישה למצלמה בהגדרות).")
                        .padding()
                        .multilineTextAlignment(.center)
                }
            }
            .navigationTitle("סריקת ברקוד")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("ביטול") { dismiss() } } }
        }
        .environment(\.layoutDirection, .rightToLeft)
    }

    private func lookup(_ barcode: String) async {
        looking = true
        defer { looking = false }
        do {
            guard let p = try await OpenFoodFacts.lookup(barcode: barcode), p.kcal > 0 else {
                error = "המוצר לא נמצא במאגר Open Food Facts. אפשר להשתמש בחיפוש או בצילום."
                return
            }
            drafts = [FoodDraft(label: p.name, food: nil, grams: p.servingGrams ?? 100,
                                kcalPer100: p.kcal, proteinPer100: p.protein,
                                carbsPer100: p.carbs, fatPer100: p.fat)]
        } catch {
            self.error = "החיפוש נכשל: \(error.localizedDescription)"
        }
    }
}

/// Live barcode scanning with VisionKit.
struct BarcodeScanner: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.ean13, .ean8, .upce, .code128])],
            qualityLevel: .balanced, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (String) -> Void
        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            for item in addedItems {
                if case .barcode(let barcode) = item, let value = barcode.payloadStringValue {
                    onScan(value)
                    return
                }
            }
        }
    }
}
