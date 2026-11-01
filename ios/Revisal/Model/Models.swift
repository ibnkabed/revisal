import Foundation

/// Revisal's records (docs/DATA.md). Everything lives on the phone; decoders are lenient about missing keys so
/// older saved data and backups still load. Foundation only, so it is also compiled into RevisalCheck.

/// The three parts of the app.
enum Track: String, Codable, CaseIterable, Identifiable {
    case curriculum, tahsili, qudurat
    var id: String { rawValue }

    var title: String {
        switch self {
        case .curriculum: return "المناهج"
        case .tahsili: return "التحصيلي"
        case .qudurat: return "القدرات"
        }
    }
}

/// One "choose the right answer" question: always four options, one right, with the reason it is right.
struct ReviewQuestion: Codable, Hashable, Identifiable {
    var id: String = UUID().uuidString.lowercased()
    var skill: String             // the section, skill or style the question targets
    var text: String
    var options: [String]         // always four
    var answer: Int               // 0...3
    var explanation: String
    var image: String?            // question bank only: a picture in bank/images/
    var source: String?           // question bank only: where it came from
    var section: String?          // question bank only: verbal, quant, math, physics, chemistry, biology

    init(id: String = UUID().uuidString.lowercased(), skill: String, text: String, options: [String],
         answer: Int, explanation: String, image: String? = nil, source: String? = nil, section: String? = nil) {
        self.id = id
        self.skill = skill
        self.text = text
        self.options = options
        self.answer = answer
        self.explanation = explanation
        self.image = image
        self.source = source
        self.section = section
    }

    enum CodingKeys: String, CodingKey { case id, skill, text, options, answer, explanation, image, source, section }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? UUID().uuidString.lowercased()
        skill = (try? c.decodeIfPresent(String.self, forKey: .skill)) ?? ""
        text = try c.decode(String.self, forKey: .text)
        options = try c.decode([String].self, forKey: .options)
        answer = try c.decode(Int.self, forKey: .answer)
        explanation = (try? c.decodeIfPresent(String.self, forKey: .explanation)) ?? ""
        image = try? c.decodeIfPresent(String.self, forKey: .image)
        source = try? c.decodeIfPresent(String.self, forKey: .source)
        section = try? c.decodeIfPresent(String.self, forKey: .section)
    }
}

/// A part of a book the student names by its pages. The AI lists its sections and skills once; every review
/// then aims at the ones asked least, and the stems already asked are kept so new questions do not repeat them.
struct Unit: Codable, Hashable, Identifiable {
    var id: String = UUID().uuidString.lowercased()
    var name: String
    var pageFrom: Int
    var pageTo: Int
    var skills: [String] = []
    var asked: [String: Int] = [:]    // skill -> questions written for it
    var stems: [String] = []          // normalised stems already asked, newest last (at most ReviewRules.keptStems)

    init(name: String, pageFrom: Int, pageTo: Int) {
        self.name = name
        self.pageFrom = pageFrom
        self.pageTo = pageTo
    }

    enum CodingKeys: String, CodingKey { case id, name, pageFrom, pageTo, skills, asked, stems }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        pageFrom = (try? c.decodeIfPresent(Int.self, forKey: .pageFrom)) ?? 1
        pageTo = (try? c.decodeIfPresent(Int.self, forKey: .pageTo)) ?? 1
        skills = (try? c.decodeIfPresent([String].self, forKey: .skills)) ?? []
        asked = (try? c.decodeIfPresent([String: Int].self, forKey: .asked)) ?? [:]
        stems = (try? c.decodeIfPresent([String].self, forKey: .stems)) ?? []
    }

    var pagesText: String { pageFrom == pageTo ? "ص \(pageFrom)" : "ص \(pageFrom)–\(pageTo)" }
}

/// A curriculum book the student added (the PDF is books/<id>.pdf).
struct Book: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var subject: String = ""
    var pages: Int
    var size: Int
    var addedAt: String
    var units: [Unit] = []

    init(id: String, name: String, pages: Int, size: Int, addedAt: String) {
        self.id = id
        self.name = name
        self.pages = pages
        self.size = size
        self.addedAt = addedAt
    }

    enum CodingKeys: String, CodingKey { case id, name, subject, pages, size, addedAt, units }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        subject = (try? c.decodeIfPresent(String.self, forKey: .subject)) ?? ""
        pages = (try? c.decodeIfPresent(Int.self, forKey: .pages)) ?? 0
        size = (try? c.decodeIfPresent(Int.self, forKey: .size)) ?? 0
        addedAt = (try? c.decodeIfPresent(String.self, forKey: .addedAt)) ?? ""
        units = (try? c.decodeIfPresent([Unit].self, forKey: .units)) ?? []
    }
}

/// Where a review's questions come from, so «حدّث» can ask the same place for new ones.
struct ReviewSource: Codable, Hashable {
    var track: Track
    var bookId: String?           // curriculum
    var unitId: String?           // curriculum; nil = a random unit of the book each time
    var section: String?          // question bank; nil = every section
    var count: Int
}

/// One review: its questions, the student's choices, and when it was finished.
struct ReviewSet: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString.lowercased()
    var title: String
    var source: ReviewSource
    var createdAt: String
    var questions: [ReviewQuestion]
    var choices: [Int?]
    var finishedAt: String?

    init(title: String, source: ReviewSource, questions: [ReviewQuestion]) {
        self.title = title
        self.source = source
        self.createdAt = Stamp.now()
        self.questions = questions
        self.choices = Array(repeating: nil, count: questions.count)
    }

    var correct: Int {
        zip(questions, choices).filter { $0.1 == $0.0.answer }.count
    }

    var answered: Int { choices.compactMap { $0 }.count }

    var percent: Int {
        questions.isEmpty ? 0 : Int((Double(correct) / Double(questions.count) * 100).rounded())
    }

    /// The questions answered wrong or left blank.
    var missed: [ReviewQuestion] {
        zip(questions, choices).filter { $0.1 != $0.0.answer }.map { $0.0 }
    }
}

struct Settings: Codable, Hashable {
    /// Show right/wrong and the explanation right after each answer (otherwise only in the result).
    var explainEach = true

    init() {}

    enum CodingKeys: String, CodingKey { case explainEach }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        explainEach = (try? c.decodeIfPresent(Bool.self, forKey: .explainEach)) ?? true
    }
}

enum Stamp {
    static func string(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    static func now() -> String { string(Date()) }

    static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

enum DayFormat {
    static func formatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    static func string(from date: Date) -> String { formatter().string(from: date) }
    static func today() -> String { string(from: Date()) }
}

/// Arabic number agreement: "سؤال واحد"، "سؤالان"، "3 أسئلة"، "11 سؤالًا".
func countWord(_ n: Int, _ forms: (one: String, two: String, few: String, many: String)) -> String {
    if n == 1 { return forms.one }
    if n == 2 { return forms.two }
    return (3...10).contains(n) ? "\(n) \(forms.few)" : "\(n) \(forms.many)"
}

let questionsForms = (one: "سؤال واحد", two: "سؤالان", few: "أسئلة", many: "سؤالًا")
let pagesForms = (one: "صفحة واحدة", two: "صفحتان", few: "صفحات", many: "صفحة")
