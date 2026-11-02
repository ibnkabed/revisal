import Foundation

/// Makes a review from its source: a curriculum unit (written by the linked AI providers) or a question bank
/// (drawn on the phone, no provider). «حدّث» calls the same function with the same source.
///
/// A unit: its text (read once and kept; scanned pages are transcribed by Gemini) -> its skills (listed once
/// by the AI) -> the least-asked skills -> one question per skill as JSON -> local checks (ReviewRules) -> a
/// second linked provider checks the answers, and the faulty ones are written again ->
/// the answer letters are balanced -> the unit remembers the skills and stems asked.
enum ReviewMaker {
    /// True while a review is being written (one at a time).
    @MainActor private static var running = false

    @MainActor
    static func make(_ source: ReviewSource, store: Store, ai: AIClient,
                     progress: @escaping (String) -> Void) async throws -> ReviewSet {
        let count = min(max(source.count, ReviewRules.minCount), ReviewRules.maxCount)
        var src = source
        src.count = count
        switch source.track {
        case .curriculum:
            if running { throw ReviewError("مراجعة أخرى تُكتب الآن، انتظرها") }
            running = true
            defer { running = false }
            do {
                return try await curriculum(src, store: store, ai: ai, progress: progress)
            } catch let e as ReviewError {
                throw e
            } catch let e as AIError {
                throw e
            } catch let e as BookError {
                throw e
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ReviewError("خطأ غير متوقع أثناء كتابة الأسئلة")
            }
        case .tahsili, .qudurat:
            return try bank(src, store: store)
        }
    }

    // MARK: question banks

    @MainActor
    private static func bank(_ src: ReviewSource, store: Store) throws -> ReviewSet {
        guard let file = BankStore.bank(src.track) else {
            throw ReviewError("بنك أسئلة \(src.track.title) يُجهَّز، ويصل في تحديث قادم للتطبيق")
        }
        let pool = Bank.pool(file, section: src.section)
        if pool.isEmpty { throw ReviewError("لا أسئلة في هذا القسم بعد") }
        let drawn = Bank.draw(pool, count: src.count, seen: store.bankSeen(src.track))
        store.setBankSeen(src.track, drawn.seen)
        let sectionName = file.sections.first { $0.id == src.section }?.name
        var questions = drawn.questions
        ReviewRules.balanceKeepingFixed(&questions, seed: nil)
        let set = ReviewSet(title: src.track.title + (sectionName.map { " · \($0)" } ?? ""), source: src,
                            questions: questions)
        store.add(set)
        return set
    }

    // MARK: curriculum

    @MainActor
    private static func curriculum(_ src: ReviewSource, store: Store, ai: AIClient,
                                   progress: @escaping (String) -> Void) async throws -> ReviewSet {
        guard let book = store.book(src.bookId) else { throw ReviewError("الكتاب غير موجود") }
        if book.units.isEmpty { throw ReviewError("أضف وحدة واحدة على الأقل بصفحاتها") }
        if ai.linked.isEmpty {
            throw ReviewError("اربط مزوّد ذكاء اصطناعي من «الإعدادات» أولًا: Gemini مجاني ويكفي")
        }
        guard var unit = src.unitId.flatMap({ id in book.units.first { $0.id == id } }) ?? book.units.randomElement() else {
            throw ReviewError("الوحدة غير موجودة")
        }
        if src.unitId == nil { progress("الوحدة المختارة: \(unit.name)") }

        let text = try await unitText(book, unit, store: store, ai: ai, progress: progress)
        let language = ReviewRules.language(of: text)

        if unit.skills.isEmpty {
            progress("أستخرج أقسام الوحدة ومهاراتها…")
            let reply = try await ai.chat(ReviewRules.skillsMessages(subject: book.subject, text: text, language: language),
                                          jsonMode: true, temperature: 0.2)
            unit.skills = ReviewRules.parseSkills(reply.text)
            if unit.skills.isEmpty { unit.skills = [language == "ar" ? "فهم المحتوى" : "Understanding the content"] }
            store.recordUnit(book.id, unit)
        }

        let targets = ReviewRules.targets(skills: unit.skills, asked: unit.asked, count: src.count)
        var used: [String] = []
        var items: [ReviewQuestion] = []
        for round in 0..<3 {
            let need = Array(targets.dropFirst(items.count))
            if need.isEmpty { break }
            progress(round == 0 ? "أكتب \(countWord(need.count, questionsForms))…" : "أكمل الأسئلة الناقصة…")
            items += try await writeRound(book: book, unit: unit, targets: need, text: text,
                                          have: items, ai: ai, used: &used)
        }

        let writer = used.first
        if ai.linked.contains(where: { $0.id != writer }) && !items.isEmpty {
            progress("مزوّد ثانٍ يراجع الإجابات…")
            do {
                let reply = try await ai.chat(ReviewRules.reviewMessages(text: text, items: items), jsonMode: true,
                                              exclude: writer.map { [$0] } ?? [], temperature: 0.1)
                var bad = Set<Int>()
                for entry in ReviewRules.parseJSON(reply.text)["bad"] as? [Any] ?? [] {
                    guard let d = entry as? [String: Any], let n = ReviewRules.reviewNumber(d["n"]) else { continue }
                    if n >= 1 && n <= items.count { bad.insert(n - 1) }
                }
                if !bad.isEmpty {
                    progress("أعيد كتابة \(countWord(bad.count, questionsForms)) لم تجتز المراجعة…")
                    let again = bad.sorted().map { items[$0].skill }
                    let kept = items.enumerated().filter { !bad.contains($0.offset) }.map { $0.element }
                    let rejected = bad.sorted().map { items[$0] }
                    let rewritten = try await writeRound(book: book, unit: unit, targets: again, text: text,
                                                         have: kept + rejected, ai: ai, used: &used)
                    items = kept + rewritten
                }
            } catch is AIError {
                progress("تعذّرت المراجعة الثانية، فبقيت الأسئلة كما كُتبت")
            }
        }

        if items.isEmpty { throw ReviewError("لم يُكتب أي سؤال صالح. جرّب مرة أخرى أو مزوّدًا آخر.") }
        ReviewRules.balance(&items, seed: nil)
        store.recordUnit(book.id, ReviewRules.record(items, in: unit))
        var set = ReviewSet(title: book.name + " · " + unit.name, source: src, questions: items)
        set.unitId = unit.id
        store.add(set)
        return set
    }

    /// The unit's text, read once and kept: the PDF's own text, or Gemini's transcription of scanned pages.
    @MainActor
    private static func unitText(_ book: Book, _ unit: Unit, store: Store, ai: AIClient,
                                 progress: @escaping (String) -> Void) async throws -> String {
        if let kept = store.unitText(unit.id), !kept.isEmpty { return kept }
        progress("أقرأ صفحات الوحدة…")
        let url = store.bookURL(book.id)
        let a = unit.pageFrom, b = unit.pageTo
        let read = try await Task.detached(priority: .userInitiated) {
            try BookText.text(url, from: a, to: b)
        }.value
        var text = read.text
        if !read.readable {
            progress("صفحات الوحدة صور: يقرؤها Gemini…")
            let pdf = try await Task.detached(priority: .userInitiated) {
                try BookText.subset(url, from: a, to: b)
            }.value
            text = try await ai.geminiPDF(pdf, prompt: ReviewRules.transcribePrompt)
            if text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count < 200 {
                throw ReviewError("لم يُستخرج نص كافٍ من صفحات هذه الوحدة")
            }
        }
        text = String(String.UnicodeScalarView(text.unicodeScalars.prefix(ReviewRules.maxText)))
        store.saveUnitText(unit.id, text)
        return text
    }

    /// One writing call for `targets`: keeps the questions that pass the checks and are not repeats of
    /// `have` or of the unit's earlier stems, at most one per target.
    @MainActor
    private static func writeRound(book: Book, unit: Unit, targets: [String], text: String, have: [ReviewQuestion],
                                   ai: AIClient, used: inout [String]) async throws -> [ReviewQuestion] {
        let avoid = unit.stems + have.map { ReviewRules.norm($0.text) }
        let messages = [["role": "system", "content": ReviewRules.systemPrompt(ReviewRules.language(of: text))],
                        ["role": "user", "content": ReviewRules.userPrompt(subject: book.subject, targets: targets,
                                                                           text: text, avoid: avoid)]]
        let reply = try await ai.chat(messages, jsonMode: true, temperature: 0.7)
        used.append(reply.provider)
        var seen = Set(avoid)
        var out: [ReviewQuestion] = []
        let raws = ReviewRules.parseJSON(reply.text)["questions"] as? [Any] ?? []
        for (i, raw) in raws.enumerated() where out.count < targets.count {
            let fallback = targets[min(i, targets.count - 1)]
            guard let q = ReviewRules.clean(raw, skills: unit.skills, fallback: fallback) else { continue }
            let key = ReviewRules.norm(q.text)
            if !seen.contains(key) {
                seen.insert(key)
                out.append(q)
            }
        }
        return out
    }
}

/// The bundled banks (bank/tahsili.json, bank/qudurat.json), read once; nil when a bank has no questions yet.
@MainActor
enum BankStore {
    private static var cache: [Track: BankFile?] = [:]

    static func bank(_ track: Track) -> BankFile? {
        if let hit = cache[track] { return hit }
        let file = read(track)
        cache[track] = file
        return file
    }

    /// Reads both banks off the main thread when the app opens (2026-11-02), so opening التحصيلي or القدرات
    /// the first time does not wait for a large JSON file; a tab opened before it finishes reads it itself.
    static func preload() {
        for track in [Track.tahsili, .qudurat] where cache[track] == nil {
            Task.detached(priority: .utility) {
                let file = read(track)
                await MainActor.run { if cache[track] == nil { cache[track] = file } }
            }
        }
    }

    nonisolated private static func read(_ track: Track) -> BankFile? {
        guard let url = Bundle.main.url(forResource: track.rawValue, withExtension: "json", subdirectory: "bank"),
              let data = try? Data(contentsOf: url), let loaded = try? Bank.load(data), !loaded.questions.isEmpty
        else { return nil }
        return loaded
    }

    static func imageURL(_ name: String) -> URL? {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        return Bundle.main.url(forResource: base, withExtension: ext.isEmpty ? nil : ext, subdirectory: "bank/images")
    }
}
