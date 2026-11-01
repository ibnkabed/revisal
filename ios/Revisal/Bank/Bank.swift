import Foundation

/// The question banks of التحصيلي and القدرات, bundled in the app as bank/<track>.json (docs/BANK.md), and
/// how a review draws from them: every question once before any comes again, and each review spread over as
/// many skills as it can. Bank questions carry no explanation (owner, 2026-11-01): the question, its four
/// options and the right one. Foundation only, so it is also compiled into RevisalCheck (`--bank-selftest`).

struct BankSection: Codable, Hashable, Identifiable {
    var id: String
    var name: String
}

struct BankFile: Codable {
    var track: Track
    var version: Int
    var sections: [BankSection]
    var questions: [ReviewQuestion]
    var section: [String: String] = [:]   // question id -> section id (filled by `load`)

    enum CodingKeys: String, CodingKey { case track, version, sections, questions }
}

enum Bank {
    struct BankError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// One bank question as stored: a ReviewQuestion with its section id.
    private struct Stored: Decodable {
        let section: String
        let question: ReviewQuestion

        enum CodingKeys: String, CodingKey { case section }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            section = try c.decode(String.self, forKey: .section)
            question = try ReviewQuestion(from: decoder)
        }
    }

    private struct Raw: Decodable {
        let track: Track
        let version: Int
        let sections: [BankSection]
        let questions: [Stored]
    }

    /// Reads and checks a bank: known sections, unique ids, four different options, answer 0-3. A faulty question is an error naming its id, so a broken bank never ships.
    static func load(_ data: Data) throws -> BankFile {
        let raw: Raw
        do {
            raw = try JSONDecoder().decode(Raw.self, from: data)
        } catch {
            throw BankError(message: "ملف البنك غير صالح: \(error)")
        }
        let known = Set(raw.sections.map(\.id))
        var ids = Set<String>()
        var file = BankFile(track: raw.track, version: raw.version, sections: raw.sections, questions: [])
        for s in raw.questions {
            let q = s.question
            guard known.contains(s.section) else { throw BankError(message: "\(q.id): قسم غير معروف \(s.section)") }
            guard ids.insert(q.id).inserted else { throw BankError(message: "\(q.id): رقم مكرر") }
            guard q.options.count == 4, Set(q.options.map(ReviewRules.norm)).count == 4,
                  !q.options.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
                throw BankError(message: "\(q.id): البدائل ليست أربعة مختلفة")
            }
            guard (0...3).contains(q.answer) else { throw BankError(message: "\(q.id): رقم الإجابة خارج 0-3") }
            guard !q.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || q.image != nil else {
                throw BankError(message: "\(q.id): سؤال بلا نص ولا صورة")
            }
            file.questions.append(q)
            file.section[q.id] = s.section
        }
        return file
    }

    /// The questions of one section, or of every section when nil.
    static func pool(_ bank: BankFile, section: String?) -> [ReviewQuestion] {
        guard let section else { return bank.questions }
        return bank.questions.filter { bank.section[$0.id] == section }
    }

    /// `count` questions of the pool and the ids seen afterwards. Unseen questions come first; when fewer
    /// are left than asked, the pool starts a new round (its ids leave `seen`) and the rest come from it,
    /// never twice in one review. Within the draw, skills take turns, so ten questions cover ten skills
    /// when the pool has them.
    static func draw<G: RandomNumberGenerator>(_ pool: [ReviewQuestion], count: Int, seen: Set<String>,
                                               using rng: inout G) -> (questions: [ReviewQuestion], seen: Set<String>) {
        guard !pool.isEmpty, count > 0 else { return ([], seen) }
        var seen = seen
        var picked: [ReviewQuestion] = []
        var fresh = pool.filter { !seen.contains($0.id) }
        if fresh.count < count {
            picked = spread(fresh, count: fresh.count, using: &rng)
            for q in pool { seen.remove(q.id) }
            let taken = Set(picked.map(\.id))
            fresh = pool.filter { !taken.contains($0.id) }
        }
        picked += spread(fresh, count: min(count - picked.count, fresh.count), using: &rng)
        for q in picked { seen.insert(q.id) }
        return (picked, seen)
    }

    static func draw(_ pool: [ReviewQuestion], count: Int, seen: Set<String>) -> (questions: [ReviewQuestion], seen: Set<String>) {
        var rng = SystemRandomNumberGenerator()
        return draw(pool, count: count, seen: seen, using: &rng)
    }

    /// `count` of the questions, skills taking turns in a random order, each skill's questions shuffled.
    static func spread<G: RandomNumberGenerator>(_ questions: [ReviewQuestion], count: Int,
                                                 using rng: inout G) -> [ReviewQuestion] {
        var groups: [String: [ReviewQuestion]] = [:]
        for q in questions { groups[q.skill, default: []].append(q) }
        var keys = groups.keys.sorted()
        keys.shuffle(using: &rng)
        for k in keys { groups[k]?.shuffle(using: &rng) }
        var out: [ReviewQuestion] = []
        while out.count < count {
            var moved = false
            for k in keys where out.count < count {
                if var list = groups[k], !list.isEmpty {
                    out.append(list.removeFirst())
                    groups[k] = list
                    moved = true
                }
            }
            if !moved { break }
        }
        return out
    }

    /// The key a track's seen questions are remembered under in the store's `bankSeen`: one set for the
    /// whole track, so a question seen in «كل الأقسام» is not new again in its own section.
    static func seenKey(_ track: Track) -> String { track.rawValue }
}
