import SwiftUI
import UniformTypeIdentifiers

/// The student's own books and summaries (owner, 2026-11-02): add any curriculum or summary as a PDF, name its units by their pages, and review a unit.
struct CurriculaView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var ai: AIClient
    @State private var picking = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if ai.linked.isEmpty {
                    Section {
                        Label("اربط مزوّد ذكاء اصطناعي من «الإعدادات» ليكتب أسئلة كتبك وملخصاتك: Gemini مجاني ويكفي.",
                              systemImage: "key")
                            .foregroundColor(.orange)
                    }
                }
                if store.books.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("أضف كتاب أي مادة أو ملخصًا لها بصيغة PDF").font(.headline)
                            Text("ثم حدّد وحداته بصفحاتها (والملخص القصير يُراجع كله)، واختر وحدة وعدد الأسئلة. يكتب الذكاء الاصطناعي أسئلة «اختر الإجابة الصحيحة» من أربعة خيارات، موزعة على أقسام الوحدة ومهاراتها، وتحت كل سؤال زر «اشرح لي» إن أردت شرح إجابته.")
                                .font(.callout).foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                ForEach(store.books) { book in
                    NavigationLink(value: book) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(book.name).font(.headline)
                            Text((book.subject.isEmpty ? "" : book.subject + " · ") + countWord(book.pages, pagesForms)
                                 + " · " + unitsWord(book.units.count))
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    for i in offsets { store.deleteBook(store.books[i].id) }
                }
                if let error {
                    Text(error).foregroundColor(.red)
                }
            }
            .navigationTitle("المنهج")
            .navigationDestination(for: Book.self) { book in
                BookView(bookId: book.id)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        picking = true
                    } label: {
                        Label("أضف كتابًا أو ملخصًا", systemImage: "doc.badge.plus")
                    }
                }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.pdf]) { result in
                guard case .success(let url) = result else { return }
                do {
                    _ = try store.addBook(from: url)
                    error = nil
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
    }
}

func unitsWord(_ n: Int) -> String {
    n == 0 ? "بلا وحدات" : countWord(n, (one: "وحدة واحدة", two: "وحدتان", few: "وحدات", many: "وحدة"))
}

/// One book: its name and subject, its units, a review of one unit (or a random one), and its history.
struct BookView: View {
    let bookId: String
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var ai: AIClient
    @AppStorage("curriculum.count") private var count = ReviewRules.defaultCount
    @State private var unitId = ""             // "" = a random unit each time
    @State private var name = ""
    @State private var subject = ""
    @State private var editing: UnitDraft?
    @State private var running = false
    @State private var lines: [String] = []
    @State private var error: String?
    @State private var opened: OpenSet?

    private var book: Book? { store.book(bookId) }

    var body: some View {
        Form {
            if let book {
                Section("الملف") {
                    TextField("اسم الكتاب أو الملخص", text: $name, onCommit: saveInfo)
                    TextField("المادة (مثال: لغتي، العلوم، English)", text: $subject, onCommit: saveInfo)
                    LabeledContent("الصفحات", value: "\(book.pages)")
                }

                Section {
                    ForEach(book.units) { unit in
                        Button {
                            editing = UnitDraft(unit: unit)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(unit.name).foregroundColor(.primary)
                                Text(unit.pagesText + (unit.skills.isEmpty ? "" : " · " + skillsWord(unit.skills.count)))
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                    .onDelete { store.deleteUnits(bookId, at: $0) }
                    Button {
                        let last = book.units.last?.pageTo ?? 0
                        let from = min(last + 1, book.pages)
                        editing = UnitDraft(unit: Unit(name: "", pageFrom: from,
                                                       pageTo: min(from + 9, book.pages)), isNew: true)
                    } label: {
                        Label("أضف وحدة", systemImage: "plus")
                    }
                } header: {
                    Text("الوحدات")
                } footer: {
                    Text("سمِّ كل وحدة وحدّد صفحاتها كما في الملف نفسه، \(BookRules.maxPages) صفحة على الأكثر. ويستخرج الذكاء الاصطناعي أقسام الوحدة ومهاراتها في أول مراجعة لها.")
                }

                if !book.units.isEmpty {
                    Section {
                        Picker("الوحدة", selection: $unitId) {
                            Text("عشوائية من الوحدات").tag("")
                            ForEach(book.units) { u in Text(u.name).tag(u.id) }
                        }
                        CountPicker(count: $count)
                        Button {
                            start()
                        } label: {
                            Label("ابدأ المراجعة", systemImage: "play.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(running || ai.linked.isEmpty)
                    } header: {
                        Text("مراجعة")
                    } footer: {
                        Text("كل سؤال يبيّن القسم أو المهارة التي يقيسها، وكلما زاد العدد تنوّعت المهارات حتى تغطي الوحدة كلها. وزر «حدّث» يأتي بأسئلة جديدة لم تُسأل من قبل.")
                    }
                    ProgressLines(lines: lines, running: running, error: error)
                }

                let history = store.history(.curriculum, bookId: bookId)
                if !history.isEmpty {
                    Section("المراجعات السابقة") {
                        ForEach(history) { set in
                            Button { opened = OpenSet(id: set.id) } label: { HistoryRow(set: set) }
                                .foregroundColor(.primary)
                        }
                        .onDelete { offsets in
                            for i in offsets { store.deleteSet(history[i].id) }
                        }
                    }
                }
            }
        }
        .navigationTitle(book?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            name = book?.name ?? ""
            subject = book?.subject ?? ""
        }
        .onDisappear(perform: saveInfo)
        .sheet(item: $editing) { draft in
            UnitEditor(bookId: bookId, pages: book?.pages ?? 1, draft: draft)
        }
        .fullScreenCover(item: $opened) { open in
            RunView(setId: open.id)
        }
    }

    private func saveInfo() {
        guard let book, name != book.name || subject != book.subject else { return }
        store.updateBook(bookId, name: name, subject: subject)
    }

    private func start() {
        saveInfo()
        let source = ReviewSource(track: .curriculum, bookId: bookId, unitId: unitId.isEmpty ? nil : unitId,
                                  section: nil, count: count)
        running = true
        error = nil
        lines = []
        Task {
            defer { running = false }
            do {
                let set = try await ReviewMaker.make(source, store: store, ai: ai) { lines.append($0) }
                lines = []
                opened = OpenSet(id: set.id)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

func skillsWord(_ n: Int) -> String {
    countWord(n, (one: "مهارة واحدة", two: "مهارتان", few: "مهارات", many: "مهارة"))
}

struct UnitDraft: Identifiable {
    var unit: Unit
    var isNew = false
    var id: String { unit.id }
}

/// A unit's name and pages, and the skills the AI found in it.
struct UnitEditor: View {
    let bookId: String
    let pages: Int
    @State var draft: UnitDraft
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("الوحدة") {
                    TextField("اسم الوحدة (مثال: الوحدة الأولى)", text: $draft.unit.name)
                    Stepper("من صفحة \(draft.unit.pageFrom)", value: $draft.unit.pageFrom, in: 1...max(pages, 1))
                    Stepper("إلى صفحة \(draft.unit.pageTo)", value: $draft.unit.pageTo, in: 1...max(pages, 1))
                }
                if !draft.unit.skills.isEmpty {
                    Section {
                        ForEach(draft.unit.skills, id: \.self) { s in
                            HStack {
                                Text(s)
                                Spacer()
                                Text("\(draft.unit.asked[s] ?? 0)").foregroundColor(.secondary).monospacedDigit()
                            }
                        }
                    } header: {
                        Text("أقسام الوحدة ومهاراتها")
                    } footer: {
                        Text("بجانب كل مهارة عدد ما سُئل فيها. تغيير الصفحات يجعل الذكاء الاصطناعي يستخرجها من جديد.")
                    }
                }
                if let error {
                    Text(error).foregroundColor(.red)
                }
            }
            .navigationTitle(draft.isNew ? "وحدة جديدة" : "الوحدة")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إلغاء") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("احفظ") { save() }
                }
            }
        }
    }

    private func save() {
        do {
            if draft.isNew {
                try store.addUnit(bookId, name: draft.unit.name, from: draft.unit.pageFrom, to: draft.unit.pageTo)
            } else {
                var u = draft.unit
                let n = u.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !n.isEmpty { u.name = String(n.prefix(60)) }
                try store.updateUnit(bookId, u)
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
