import Foundation

/// The review writer's pure rules: the prompts, the JSON parsing, the local checks on each question, which
/// skills a review aims at, and the answer-letter balance. Foundation only, so it is also compiled into
/// RevisalCheck (`--review-selftest`). The steps that talk to the providers are in ReviewMaker.swift.

/// A message for the student, in Arabic.
struct ReviewError: LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum ReviewRules {
    /// Questions per review (owner's decision 2026-11-01).
    static let minCount = 1
    static let maxCount = 10
    static let defaultCount = 10
    /// The unit's text sent to a provider, in characters.
    static let maxText = 60000
    /// Stems kept per unit so new reviews do not repeat them; the newest 80 are listed in the prompt.
    static let keptStems = 400
    static let listedStems = 80
    static let maxSkills = 24
    static let maxSkillLength = 60

    static let transcribePrompt = "Transcribe all the text of these pages faithfully, in their original "
        + "language and reading order. Plain text only, no commentary."

    private static let banned = #"(all of the above|none of the above|both a and b|جميع ما سبق|كل ما سبق|لا شيء مما سبق|جميع الإجابات|(أ|أ\.) و ?(ب|ب\.) معًا)"#

    // MARK: language

    /// "ar" when Arabic letters outnumber Latin ones, else "en".
    static func language(of text: String) -> String {
        var arabic = 0, latin = 0
        for u in text.unicodeScalars {
            if (0x0600...0x06FF).contains(u.value) {
                arabic += 1
            } else if ("a"..."z").contains(u) || ("A"..."Z").contains(u) {
                latin += 1
            }
        }
        return arabic >= latin ? "ar" : "en"
    }

    // MARK: the unit's skills

    /// Asks for the unit's own sections, skills and question styles: every curriculum has its own way.
    static func skillsMessages(subject: String, text: String, language: String) -> [[String: String]] {
        let labels = language == "ar" ? "بالعربية" : "in the language of the content (English for an English book)"
        let system = "أنت خبير مناهج سعودي. تقرأ جزءًا من كتاب مدرسي وتستخرج أقسامه ومهاراته وأساليب الأسئلة التي تقيس فهمه، "
            + "بحسب طبيعة المادة نفسها: في اللغة مثلًا القواعد والمفردات والفهم القرائي والإملاء، وفي العلوم المفاهيم والتطبيق "
            + "وتفسير الظواهر، وفي الرياضيات أنواع المسائل، وهكذا. اكتب كل عنوان قصيرًا محددًا (لا يتجاوز 50 حرفًا) \(labels)، "
            + "من 4 إلى 20 عنوانًا تغطي الجزء كله بلا تكرار. "
            + #"أعد JSON فقط: {"skills":["...","..."]}"#
        let head = subject.isEmpty ? "" : "المادة: \(subject).\n"
        return [["role": "system", "content": system],
                ["role": "user", "content": head + "نص الصفحات:\n" + text]]
    }

    /// The skills from the provider's reply: trimmed, short, no repeats, at most maxSkills.
    static func parseSkills(_ reply: String) -> [String] {
        let list = parseJSON(reply)["skills"] as? [Any] ?? []
        var seen = Set<String>()
        var out: [String] = []
        for item in list {
            let s = squash(pyString(item))
            guard !s.isEmpty, s.unicodeScalars.count <= maxSkillLength, !seen.contains(norm(s)) else { continue }
            seen.insert(norm(s))
            out.append(s)
            if out.count == maxSkills { break }
        }
        return out
    }

    /// The skills a review of `count` questions aims at: the least asked first (ties in a random order), one
    /// question per skill, going round again only when the count is larger than the skills. So more questions
    /// mean more kinds, and refreshing walks through every skill of the unit.
    static func targets<G: RandomNumberGenerator>(skills: [String], asked: [String: Int], count: Int,
                                                  using rng: inout G) -> [String] {
        guard !skills.isEmpty, count > 0 else { return [] }
        let order = skills.shuffled(using: &rng).sorted { (asked[$0] ?? 0) < (asked[$1] ?? 0) }
        return (0..<count).map { order[$0 % order.count] }
    }

    static func targets(skills: [String], asked: [String: Int], count: Int) -> [String] {
        var rng = SystemRandomNumberGenerator()
        return targets(skills: skills, asked: asked, count: count, using: &rng)
    }

    // MARK: writing

    static func systemPrompt(_ language: String) -> String {
        let lang = language == "ar"
            ? "السؤال والبدائل بالعربية الفصحى السليمة"
            : "the question and its options in clear correct English, as in the book"
        return "أنت معلم سعودي خبير يكتب أسئلة مراجعة لطالب يريد التأكد من فهمه للمنهج، من صفحات الكتاب المعطاة فقط. "
            + "كل سؤال من نوع «اختر الإجابة الصحيحة»: \(lang)، وأربعة بدائل مختلفة ومعقولة وقصيرة، واحد منها فقط صحيح يقينًا، "
            + "ولا «جميع ما سبق» ولا «لا شيء مما سبق». يقيس السؤال الفهم لا الحفظ الحرفي متى أمكن، ويُجاب من النص وحده. "
            + "اكتب لكل سؤال المهارة التي يقيسها كما أُعطيت لك حرفيًا، وشرحًا بالعربية (لا يتجاوز 400 حرف) يبيّن لماذا الإجابة "
            + "صحيحة ولماذا أقرب البدائل الخاطئة خطأ، ليتعلم الطالب من خطئه. "
            + "أعد JSON فقط بهذا الشكل: "
            + #"{"questions":[{"skill":"...","text":"...","options":["...","...","...","..."],"answer":0,"explanation":"..."}]}"#
            + " حيث answer رقم البديل الصحيح من 0 إلى 3."
    }

    /// One question for each target skill (a skill listed twice gets two different questions).
    static func userPrompt(subject: String, targets: [String], text: String, avoid: [String]) -> String {
        var head = subject.isEmpty ? "" : "المادة: \(subject).\n"
        head += "اكتب \(targets.count == 1 ? "سؤالًا واحدًا" : "\(targets.count) أسئلة")، سؤالًا لكل سطر من هذه المهارات بالترتيب:\n"
        head += targets.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        if !avoid.isEmpty {
            head += "\nلا تكرر هذه الأسئلة التي سُئلها الطالب من قبل، ولا تسأل عن النقطة نفسها بصياغة أخرى:\n"
                + avoid.suffix(listedStems).map { "- \($0)" }.joined(separator: "\n")
        }
        return head + "\n\nنص الصفحات:\n" + text
    }

    /// The second provider's review of the answers and explanations, listing the faulty ones by number.
    static func reviewMessages(text: String, items: [ReviewQuestion]) -> [[String: String]] {
        let system = "أنت مراجع أسئلة دقيق. افحص كل سؤال على النص: هل الإجابة المعلّمة صحيحة يقينًا؟ هل يوجد بديل آخر صحيح أيضًا؟ "
            + "هل الشرح صحيح ومطابق للإجابة؟ هل اللغة سليمة والسؤال واضح؟ "
            + #"أعد JSON فقط: {"bad":[{"n":رقم,"why":"السبب"}]} ولا تذكر السليم."#
        let user = "الأسئلة:\n" + shownJSON(items) + "\n\nالنص:\n" + text
        return [["role": "system", "content": system], ["role": "user", "content": user]]
    }

    static func shownJSON(_ items: [ReviewQuestion]) -> String {
        let parts = items.enumerated().map { pair -> String in
            let q = pair.element
            return "{\"n\": \(pair.offset + 1), \"text\": \(jsonString(q.text)), \"options\": ["
                + q.options.map(jsonString).joined(separator: ", ") + "], \"answer\": \(q.answer), \"explanation\": "
                + jsonString(q.explanation) + "}"
        }
        return "[" + parts.joined(separator: ", ") + "]"
    }

    static func jsonString(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 {
                    out += String(format: "\\u%04x", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        return out + "\""
    }

    // MARK: parsing and checks

    /// The provider's reply as a JSON object: ``` fences removed; else the outermost {...}; else empty.
    static func parseJSON(_ reply: String) -> [String: Any] {
        var t = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        t = Pattern.replace(#"^```(?:json)?\s*|\s*```$"#, in: t, with: "")
        if let obj = try? JSONSerialization.jsonObject(with: Data(t.utf8)) {
            return obj as? [String: Any] ?? [:]
        }
        if let m = Pattern.firstMatch(#"\{.*\}"#, in: t, options: [.dotMatchesLineSeparators]),
           let obj = try? JSONSerialization.jsonObject(with: Data(m.utf8)) as? [String: Any] {
            return obj
        }
        return [:]
    }

    /// Lower-cased, every run of non-word characters made one space (for "is this the same question?").
    static func norm(_ s: String) -> String {
        Pattern.replace(#"[^\p{L}\p{N}_]+"#, in: s.lowercased(), with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One question from the provider's JSON, or nil when it fails the local checks: a stem of 5-300
    /// characters; four different non-empty options of at most 120 characters, none "all/none of the above";
    /// answer 0-3 (or "0"-"3", "A"-"D", "أ"-"د"); an explanation of 10-700 characters. A skill not among
    /// `skills` takes `fallback` (the skill it was asked for).
    static func clean(_ raw: Any, skills: [String], fallback: String) -> ReviewQuestion? {
        guard let d = raw as? [String: Any] else { return nil }
        let text = squash(pyString(d["text"]))
        guard (5...300).contains(text.unicodeScalars.count) else { return nil }

        guard let list = d["options"] as? [Any] else { return nil }
        let options = list.map { squash(pyString($0)) }
        guard options.count == 4,
              !options.contains(where: { $0.isEmpty || $0.unicodeScalars.count > 120 }),
              Set(options.map(norm)).count == 4,
              !options.contains(where: { Pattern.firstMatch(banned, in: $0, options: [.caseInsensitive]) != nil })
        else { return nil }

        guard let answer = answerIndex(d["answer"]) else { return nil }

        let explanation = pyString(d["explanation"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard (10...700).contains(explanation.unicodeScalars.count) else { return nil }

        let asked = squash(pyString(d["skill"]))
        let skill = skills.first { norm($0) == norm(asked) } ?? fallback
        return ReviewQuestion(skill: skill, text: text, options: options, answer: answer, explanation: explanation)
    }

    /// 0-3 from a JSON number, a digit string, or a letter A-D / أ-د.
    static func answerIndex(_ v: Any?) -> Int? {
        var answer: Int?
        if let s = v as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if let n = decimalValue(t) {
                answer = n
            } else if t.count == 1 {
                answer = ["A", "B", "C", "D"].firstIndex(of: t.uppercased()) ?? ["أ", "ب", "ج", "د"].firstIndex(of: t)
            }
        } else {
            answer = jsonInt(v)
        }
        guard let answer, (0...3).contains(answer) else { return nil }
        return answer
    }

    /// Shuffles the options so the right letters are spread evenly (each as often as the others, within one)
    /// and never three equal letters in a row; the right option stays the right one.
    static func balance<G: RandomNumberGenerator>(_ questions: inout [ReviewQuestion], using rng: inout G) {
        var pool = (0..<questions.count).map { $0 % 4 }
        for _ in 0..<200 {
            pool.shuffle(using: &rng)
            if !hasTripleRun(pool) { break }
        }
        for (index, target) in pool.enumerated() {
            var q = questions[index]
            guard q.options.count == 4, (0...3).contains(q.answer) else { continue }
            let right = q.options[q.answer]
            var others = q.options.enumerated().filter { $0.offset != q.answer }.map { $0.element }
            others.shuffle(using: &rng)
            others.insert(right, at: target)
            q.options = others
            q.answer = target
            questions[index] = q
        }
    }

    static func balance(_ questions: inout [ReviewQuestion], seed: UInt64?) {
        if let seed {
            var rng = SplitMix64(seed: seed)
            balance(&questions, using: &rng)
        } else {
            var rng = SystemRandomNumberGenerator()
            balance(&questions, using: &rng)
        }
    }

    static func hasTripleRun(_ letters: [Int]) -> Bool {
        guard letters.count >= 3 else { return false }
        for i in 2..<letters.count where letters[i] == letters[i - 1] && letters[i - 1] == letters[i - 2] {
            return true
        }
        return false
    }

    /// The unit after a review was written: each skill's count raised, the new stems kept (newest last).
    static func record(_ questions: [ReviewQuestion], in unit: Unit) -> Unit {
        var u = unit
        for q in questions {
            u.asked[q.skill, default: 0] += 1
            u.stems.append(norm(q.text))
        }
        if u.stems.count > keptStems { u.stems = Array(u.stems.suffix(keptStems)) }
        return u
    }

    // MARK: JSON values

    /// The value as text: nil, null, false and 0 give "".
    static func pyString(_ v: Any?) -> String {
        guard let v, !(v is NSNull) else { return "" }
        if let s = v as? String { return s }
        if let n = v as? NSNumber {
            if isBoolNumber(n) { return n.boolValue ? "True" : "" }
            if n.doubleValue == 0 { return "" }
            return CFNumberIsFloatType(n as CFNumber) ? "\(n.doubleValue)" : n.stringValue
        }
        return String(describing: v)
    }

    /// A JSON whole number (never true/false or a fraction).
    static func jsonInt(_ v: Any?) -> Int? {
        guard let v, let n = v as? NSNumber, !isBoolNumber(n), !CFNumberIsFloatType(n as CFNumber) else { return nil }
        return n.intValue
    }

    static func isBoolNumber(_ n: NSNumber) -> Bool {
        CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    /// Decimal digits of any script ("3", "٣") as a number.
    static func decimalValue(_ s: String) -> Int? {
        guard !s.isEmpty, s.unicodeScalars.count <= 18 else { return nil }
        var n = 0
        for u in s.unicodeScalars {
            guard u.properties.numericType == .decimal, let v = u.properties.numericValue else { return nil }
            n = n * 10 + Int(v)
        }
        return n
    }

    /// A review's question number from a whole number or a string of digits.
    static func reviewNumber(_ v: Any?) -> Int? {
        if let s = v as? String { return decimalValue(s) }
        guard let n = jsonInt(v), n >= 0 else { return nil }
        return n
    }

    /// Every whitespace run made one space, trimmed.
    static func squash(_ s: String) -> String {
        Pattern.replace(#"\s+"#, in: s, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
