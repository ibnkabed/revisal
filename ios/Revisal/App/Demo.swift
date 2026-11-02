import Foundation

/// Screenshot mode for the README (2026-11-02): `-demo <screen>` opens the app on sample data in a folder of
/// its own, never the student's. Screens: curricula, bank, question, answered, result, settings. The CI job
/// `screenshots.yml` launches each one in the simulator and saves the screen.
enum Demo {
    static let screen: String? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-demo"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }()

    /// The tab the screen lives in: 0 المنهج, 1 التحصيلي, 2 القدرات, 3 الإعدادات.
    static var tab: Int {
        switch screen {
        case "curricula": return 0
        case "answered": return 1
        case "settings": return 3
        default: return 2
        }
    }

    /// The review opened over the tab, if the screen is one.
    static var openSet: String? {
        switch screen {
        case "question": return "demo-quant"
        case "answered": return "demo-physics"
        case "result": return "demo-result"
        default: return nil
        }
    }

    /// A fresh folder with one book, three reviews, an explanation and bank progress.
    @MainActor
    static func folder() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RevisalDemo", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var db = StoreFile()

        var book = Book(id: "demo-book", name: "الأحياء ٣ — ملخص الفصل الأول", pages: 48, size: 2_400_000,
                        addedAt: Stamp.now())
        book.subject = "الأحياء"
        var unit = Unit(name: "الوراثة الجزيئية", pageFrom: 1, pageTo: 16)
        unit.skills = ["تركيب DNA", "تضاعف DNA", "بناء البروتين", "الطفرات"]
        book.units = [unit, Unit(name: "الجهاز العصبي", pageFrom: 17, pageTo: 32), Unit(name: "الهرمونات", pageFrom: 33, pageTo: 48)]
        db.books = [book]

        let qudurat = BankStore.bank(.qudurat)?.questions ?? []
        let tahsili = BankStore.bank(.tahsili)?.questions ?? []
        let quant = qudurat.filter { $0.section == "quant" && $0.image == nil }
        let comparison = quant.filter { ReviewRules.fixedOrder($0) }
        let quantSet = Array((comparison.prefix(1) + quant.filter { !ReviewRules.fixedOrder($0) }.prefix(9)))
        let physics = Array(tahsili.filter { $0.section == "physics" && $0.image == nil && $0.text.count < 120 }.prefix(10))
        let verbal = Array(qudurat.filter { $0.section == "verbal" }.prefix(10))

        var sets: [ReviewSet] = []
        if !quantSet.isEmpty {
            var s = ReviewSet(title: "القدرات · الكمي", source: ReviewSource(track: .qudurat, section: "quant", count: 10),
                              questions: quantSet)
            s.id = "demo-quant"
            sets.append(s)
        }
        if let first = physics.first {
            var s = ReviewSet(title: "التحصيلي · الفيزياء", source: ReviewSource(track: .tahsili, section: "physics", count: 10),
                              questions: physics)
            s.id = "demo-physics"
            s.choices[0] = (first.answer + 1) % 4
            sets.append(s)
            db.explanations[first.id] = "الإجابة الصحيحة «\(first.options[first.answer])»: "
                + "هذا ما يعطيه القانون مباشرة عند التعويض بالقيم المعطاة في السؤال، أما الخيار الذي اخترته فينتج عن "
                + "الخلط بين الكميتين، فتأكد من وحدة كل منهما قبل التعويض."
        }
        if !verbal.isEmpty {
            var s = ReviewSet(title: "القدرات · اللفظي", source: ReviewSource(track: .qudurat, section: "verbal", count: 10),
                              questions: verbal)
            s.id = "demo-result"
            for (i, q) in verbal.enumerated() { s.choices[i] = [1, 4, 7].contains(i) ? (q.answer + 1) % 4 : q.answer }
            s.finishedAt = Stamp.now()
            sets.append(s)
        }
        db.sets = sets
        db.bankSeen[Bank.seenKey(.qudurat)] = Array(qudurat.prefix(qudurat.count / 3).map(\.id))
        db.bankSeen[Bank.seenKey(.tahsili)] = Array(tahsili.prefix(tahsili.count / 5).map(\.id))
        if let data = try? JSONEncoder().encode(db) {
            try? data.write(to: folder.appendingPathComponent("store.json"))
        }
        return folder
    }
}
