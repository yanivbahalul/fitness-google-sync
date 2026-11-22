import PhotosUI
import SwiftUI
import VisionKit

// MARK: - Review before saving

/// Shows what was recognized (photo / text / barcode / search), lets the user fix matches
/// and amounts, add or remove foods, then saves to the diary and Apple Health.
struct DraftReviewView: View {
    @Binding var drafts: [FoodDraft]
    let source: FoodEntry.Source
    let day: Date
    var image: UIImage? = nil
    let onSaved: () -> Void
    @State private var saving = false
    @State private var addingFood = false
    @FocusState private var focused: UUID?

    private var included: [FoodDraft] { drafts.filter(\.include) }

    var body: some View {
        List {
            if let image {
                Section {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: 180)
                        .clipShape(RoundedRectangle(cornerRadius: DS.tileRadius, style: .continuous))
                        .listRowInsets(EdgeInsets())
                        .accessibilityLabel("תמונת הארוחה")
                }
            }
            Section {
                // Removed foods are only hidden (include = false), which keeps the row bindings valid.
                ForEach($drafts) { $draft in
                    if draft.include {
                        DraftRow(draft: $draft, focused: $focused) { draft.include = false }
                    }
                }
                Button {
                    addingFood = true
                } label: {
                    Label("הוסף מאכל", systemImage: "plus.circle.fill")
                        .frame(minHeight: DS.minTap)
                }
            } header: {
                Text("בדוק את הכמויות לפני השמירה")
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) { saveBar }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("סיום") { focused = nil }
            }
        }
        .sheet(isPresented: $addingFood) {
            FoodPickerSheet { item in
                drafts.append(FoodDraft(label: item.name, food: item, grams: item.defaultGrams,
                                        kcalPer100: item.kcal, proteinPer100: item.protein,
                                        carbsPer100: item.carbs, fatPer100: item.fat))
            }
        }
    }

    /// Total and the save button, always visible at the bottom.
    private var saveBar: some View {
        let kcal = included.map(\.kcal).reduce(0, +)
        let protein = included.map(\.protein).reduce(0, +)
        let carbs = included.map(\.carbs).reduce(0, +)
        let fat = included.map(\.fat).reduce(0, +)
        return VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Int(safe: kcal).formatted()) קק\"ל")
                        .font(.title3.bold())
                        .monospacedDigit()
                    Text("חלבון \(Int(safe: protein)) · פחמימות \(Int(safe: carbs)) · שומן \(Int(safe: fat)) ג׳")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                Spacer()
            }
            PrimaryButton(title: "שמור ביומן", symbol: "checkmark", busy: saving) {
                saving = true
                Task {
                    await FoodLog.shared.add(drafts, source: source, at: FoodLog.entryDate(for: day))
                    saving = false
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    onSaved()
                }
            }
            .disabled(saving || included.isEmpty)
        }
        .padding(.horizontal, DS.pagePadding)
        .padding(.vertical, 12)
        .background(.bar)
    }
}

private struct DraftRow: View {
    @Binding var draft: FoodDraft
    var focused: FocusState<UUID?>.Binding
    let onDelete: () -> Void
    @State private var gramsText = ""
    @State private var searching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(draft.label)
                    .font(.body.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text("\(Int(safe: draft.kcal)) קק\"ל")
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
            }

            matchMenu

            if draft.lowConfidence {
                Label("לא בטוח מה זה. כדאי לבדוק.", systemImage: "questionmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if let note = draft.portionNote {
                Text("הוערך: \(note)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                stepButton("minus", label: "הפחת 10 גרם") { setGrams(max(1, draft.grams - 10)) }
                TextField("גרם", text: $gramsText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.center)
                    .font(.body.monospacedDigit())
                    .frame(minWidth: 64, maxWidth: 90, minHeight: DS.minTap)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .focused(focused, equals: draft.id)
                    .accessibilityLabel("כמות בגרם")
                    .onChange(of: gramsText) { value in
                        if let g = Double(value.replacingOccurrences(of: ",", with: ".")), g > 0 { draft.grams = g }
                    }
                Text("ג׳").foregroundStyle(.secondary)
                stepButton("plus", label: "הוסף 10 גרם") { setGrams(draft.grams + 10) }
                Spacer(minLength: 4)
                if let portions = draft.food?.portions, !portions.isEmpty {
                    Menu {
                        ForEach(portions, id: \.self) { p in
                            Button("\(p.name) (\(Int(safe: p.grams)) ג׳)") { setGrams(p.grams) }
                        }
                    } label: {
                        Text("מנות").font(.subheadline.weight(.semibold)).frame(minHeight: DS.minTap)
                    }
                    .accessibilityLabel("בחר מנה מוכנה")
                }
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash").frame(width: DS.minTap, height: DS.minTap)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("הסר את \(draft.label)")
            }
        }
        .padding(.vertical, 6)
        .onAppear { gramsText = String(Int(safe: draft.grams)) }
        .sheet(isPresented: $searching) {
            FoodPickerSheet(initialQuery: draft.label) { draft.food = $0 }
        }
    }

    /// Which database food the calories come from; tap to change.
    private var matchMenu: some View {
        Menu {
            let options = draft.alternatives.isEmpty ? FoodDatabase.shared.search(draft.label, limit: 10) : draft.alternatives
            ForEach(options) { item in
                Button("\(item.name) · \(Int(safe: item.kcal)) ל‑100 ג׳") { draft.food = item }
            }
            Divider()
            Button { searching = true } label: { Label("חיפוש במאגר…", systemImage: "magnifyingglass") }
            Button { draft.food = nil } label: { Label("הערכה, בלי מאגר", systemImage: "sparkles") }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: draft.food == nil ? "sparkles" : "checkmark.seal.fill")
                    .foregroundStyle(draft.food == nil ? Color.secondary : Theme.accent)
                Text(draft.food.map { "מאגר צמרת: \($0.name)" } ?? "הערכה (לא נמצא במאגר)")
                    .font(.subheadline)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                Image(systemName: "chevron.down").font(.caption)
            }
            .frame(minHeight: DS.minTap, alignment: .leading)
        }
        .accessibilityLabel("מקור הערכים: \(draft.food?.name ?? "הערכה")")
        .accessibilityHint("הקש כדי לבחור מאכל אחר מהמאגר")
    }

    private func stepButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(width: DS.minTap, height: DS.minTap)
                .background(Color(.tertiarySystemFill), in: Circle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
    }

    private func setGrams(_ grams: Double) {
        draft.grams = grams.rounded()
        gramsText = String(Int(safe: draft.grams))
    }
}

extension FoodItem {
    /// A sensible starting amount: a medium household portion if there is one, else 100 g.
    var defaultGrams: Double {
        portions.first(where: { $0.name.contains("בינונ") })?.grams ?? portions.first?.grams ?? 100
    }
}

/// Search the Tzameret database and pick one food.
struct FoodPickerSheet: View {
    var initialQuery = ""
    let onPick: (FoodItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [FoodItem] = []

    var body: some View {
        NavigationStack {
            List(results) { item in
                Button {
                    onPick(item)
                    dismiss()
                } label: {
                    FoodResultRow(item: item)
                }
            }
            .overlay {
                if results.isEmpty {
                    Text(query.isEmpty ? "חפש מאכל בעברית" : "לא נמצאו תוצאות")
                        .foregroundStyle(.secondary)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "חיפוש במאגר צמרת")
            .onChange(of: query) { search($0) }
            .onAppear {
                if query.isEmpty, !initialQuery.isEmpty { query = initialQuery; search(initialQuery) }
            }
            .navigationTitle("בחר מאכל")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("ביטול") { dismiss() } } }
        }
        .appChrome()
    }

    private func search(_ q: String) {
        let current = q
        Task.detached(priority: .userInitiated) {
            let found = FoodDatabase.shared.search(current)
            await MainActor.run { if current == query { results = found } }
        }
    }
}

/// One database food in a search list.
struct FoodResultRow: View {
    let item: FoodItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.name).foregroundStyle(.primary)
            Text("\(Int(safe: item.kcal)) קק\"ל ל‑100 ג׳ · חלבון \(String(format: "%.1f", item.protein)) ג׳")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: DS.minTap, alignment: .leading)
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
                            drafts = [FoodDraft(label: item.name, food: item, grams: item.defaultGrams,
                                                kcalPer100: item.kcal, proteinPer100: item.protein,
                                                carbsPer100: item.carbs, fatPer100: item.fat)]
                        } label: {
                            FoodResultRow(item: item)
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
        .appChrome()
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
        .appChrome()
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
