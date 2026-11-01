import SwiftUI

/// التحصيلي or القدرات: questions from the bundled bank, every question once before any comes again, with the
/// right answer shown after each choice (no explanation, owner 2026-11-01). No AI and no internet.
struct BankView: View {
    let track: Track
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var ai: AIClient
    @AppStorage private var count: Int
    @AppStorage private var section: String     // "" = every section
    @State private var error: String?
    @State private var opened: OpenSet?

    init(track: Track) {
        self.track = track
        _count = AppStorage(wrappedValue: ReviewRules.defaultCount, "\(track.rawValue).count")
        _section = AppStorage(wrappedValue: "", "\(track.rawValue).section")
    }

    private var bank: BankFile? { BankStore.bank(track) }

    var body: some View {
        NavigationStack {
            Form {
                if let bank {
                    Section {
                        Picker("القسم", selection: $section) {
                            Text("كل الأقسام").tag("")
                            ForEach(bank.sections) { s in Text(s.name).tag(s.id) }
                        }
                        CountPicker(count: $count)
                        Button {
                            start()
                        } label: {
                            Label("ابدأ المراجعة", systemImage: "play.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        if let error { Text(error).foregroundColor(.red) }
                    } footer: {
                        Text("تأتي الأسئلة من بنك \(track.title) بلا تكرار حتى تمر عليها كلها، ثم تبدأ دورة جديدة. وبعد كل اختيار تظهر الإجابة الصحيحة.")
                    }

                    Section("تقدّمك في البنك") {
                        ForEach(bank.sections) { s in
                            progressRow(s.name, pool: Bank.pool(bank, section: s.id))
                        }
                        progressRow("المجموع", pool: bank.questions)
                    }
                } else {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("بنك أسئلة \(track.title) يُجهَّز", systemImage: "shippingbox").font(.headline)
                            Text("تصل أسئلته في تحديث قادم للتطبيق، وتعمل بلا إنترنت ولا مفتاح.")
                                .font(.callout).foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }

                let history = store.history(track)
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
            .navigationTitle(track.title)
            .fullScreenCover(item: $opened) { open in
                RunView(setId: open.id)
            }
        }
    }

    @ViewBuilder
    private func progressRow(_ title: String, pool: [ReviewQuestion]) -> some View {
        let seen = store.bankSeen(track)
        let done = pool.filter { seen.contains($0.id) }.count
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(done) من \(pool.count)").monospacedDigit().foregroundColor(.secondary)
            }
            ProgressView(value: Double(done), total: Double(max(pool.count, 1)))
        }
    }

    private func start() {
        let source = ReviewSource(track: track, bookId: nil, unitId: nil, section: section.isEmpty ? nil : section,
                                  count: count)
        Task {
            do {
                let set = try await ReviewMaker.make(source, store: store, ai: ai) { _ in }
                error = nil
                opened = OpenSet(id: set.id)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
