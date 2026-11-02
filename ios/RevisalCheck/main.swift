import Foundation

// CI only (macOS): checks Revisal's pure rules without a phone.
//   RevisalCheck --review-selftest      the question checks, skills, targets, letter balance
//   RevisalCheck --bank-selftest        bank loading and the no-repeat draw
//   RevisalCheck --bank-check <folder>  every bank/<track>.json in the repository loads without an error

var failures = 0

func check(_ ok: Bool, _ what: String) {
    if ok {
        print("ok   \(what)")
    } else {
        failures += 1
        print("FAIL \(what)")
    }
}

func json(_ s: String) -> Any { try! JSONSerialization.jsonObject(with: Data(s.utf8)) }

func reviewSelftest() {
    let good = json(#"{"skill":"المبني للمجهول","text":"ما الفعل المبني للمجهول في الجملة؟","options":["كُتب","كتب","يكتب","اكتب"],"answer":0,"explanation":"كُتب فعل ماضٍ ضُمّ أوله وكُسر ما قبل آخره، فهو مبني للمجهول."}"#)
    let q = ReviewRules.clean(good, skills: ["المبني للمجهول", "الفاعل"], fallback: "الفاعل")
    check(q != nil && q?.answer == 0 && q?.skill == "المبني للمجهول", "a good question passes with its skill")

    let letter = json(#"{"skill":"غير مذكورة","text":"What is the capital of Saudi Arabia?","options":["Jeddah","Riyadh","Dammam","Abha"],"answer":"ب","explanation":"Riyadh is the capital city of the Kingdom."}"#)
    let l = ReviewRules.clean(letter, skills: ["Reading"], fallback: "Reading")
    check(l?.answer == 1 && l?.skill == "Reading", "answer letter ب is option 2 and an unknown skill takes the asked one")

    let banned = json(#"{"skill":"x","text":"أي مما يأتي صحيح؟","options":["أ","ب","ج","جميع ما سبق"],"answer":3,"explanation":"لأن الخيارات كلها صحيحة كما في النص."}"#)
    check(ReviewRules.clean(banned, skills: [], fallback: "x") == nil, "«جميع ما سبق» is refused")

    let three = json(#"{"skill":"x","text":"سؤال بثلاثة بدائل فقط؟","options":["1","2","3"],"answer":0,"explanation":"شرح كافٍ للإجابة الصحيحة."}"#)
    check(ReviewRules.clean(three, skills: [], fallback: "x") == nil, "three options are refused")

    let same = json(#"{"skill":"x","text":"سؤال ببديلين متماثلين؟","options":["نعم","نعم.","لا","ربما"],"answer":0,"explanation":"شرح كافٍ للإجابة الصحيحة."}"#)
    check(ReviewRules.clean(same, skills: [], fallback: "x") == nil, "repeated options are refused")

    let noWhy = json(#"{"skill":"x","text":"سؤال بلا شرح للإجابة؟","options":["1","2","3","4"],"answer":0,"explanation":""}"#)
    check(ReviewRules.clean(noWhy, skills: [], fallback: "x") != nil, "a question without an explanation is kept (explained on request)")
    check(ReviewRules.clean(good, skills: [], fallback: "x")?.explanation == "", "a written explanation is dropped")
    check(!ReviewRules.systemPrompt("ar").contains("\"explanation\""), "the writer is not asked for an explanation")

    let fenced = "```json\n{\"skills\":[\"القواعد\",\"المفردات\",\"القواعد \",\"\",\"الفهم القرائي\"]}\n```"
    check(ReviewRules.parseSkills(fenced) == ["القواعد", "المفردات", "الفهم القرائي"], "skills: fences, blanks and repeats removed")

    var rng = SplitMix64(seed: 7)
    let skills = ["a", "b", "c", "d", "e", "f"]
    let t1 = ReviewRules.targets(skills: skills, asked: ["a": 2, "b": 2, "c": 0, "d": 1, "e": 0, "f": 1], count: 2, using: &rng)
    check(Set(t1) == ["c", "e"], "the least asked skills come first")
    let t2 = ReviewRules.targets(skills: ["a", "b", "c"], asked: [:], count: 7, using: &rng)
    check(t2.count == 7 && Set(t2) == ["a", "b", "c"], "more questions than skills go round again")

    // refreshing walks through every skill: three reviews of 4 over 12 skills ask each once
    var unit = Unit(name: "u", pageFrom: 1, pageTo: 2)
    unit.skills = (1...12).map { "s\($0)" }
    var covered = Set<String>()
    for _ in 0..<3 {
        let t = ReviewRules.targets(skills: unit.skills, asked: unit.asked, count: 4, using: &rng)
        covered.formUnion(t)
        unit = ReviewRules.record(t.map { ReviewQuestion(skill: $0, text: "q \($0)", options: ["1", "2", "3", "4"],
                                                         answer: 0, explanation: "e") }, in: unit)
    }
    check(covered.count == 12, "three refreshes of 4 cover all 12 skills")

    var items = (0..<10).map { i in
        ReviewQuestion(skill: "s", text: "q\(i)", options: ["r\(i)", "w1", "w2", "w3"], answer: 0, explanation: "e")
    }
    ReviewRules.balance(&items, seed: 42)
    let letters = items.map(\.answer)
    let counts = (0..<4).map { k in letters.filter { $0 == k }.count }
    check(counts.max()! - counts.min()! <= 1, "answer letters spread evenly \(counts)")
    check(!ReviewRules.hasTripleRun(letters), "no three equal letters in a row")
    check(items.enumerated().allSatisfy { $0.element.options[$0.element.answer] == "r\($0.offset)" }, "the right option stays right")

    check(ReviewRules.language(of: "هذا نص عربي about") == "ar", "Arabic text is ar")
    check(ReviewRules.language(of: "This is English نص") == "en", "English text is en")

    var many = Unit(name: "u", pageFrom: 1, pageTo: 1)
    many.stems = (0..<ReviewRules.keptStems).map { "old \($0)" }
    many = ReviewRules.record([ReviewQuestion(skill: "k", text: "New?", options: ["1", "2", "3", "4"], answer: 0, explanation: "e")], in: many)
    check(many.stems.count == ReviewRules.keptStems && many.stems.last == "new" && many.asked["k"] == 1, "stems are capped, newest kept")

    var mixed = (0..<8).map { i in ReviewQuestion(skill: "s", text: "q\(i)", options: ["r\(i)", "w1", "w2", "w3"], answer: 0, explanation: "") }
    mixed.insert(ReviewQuestion(skill: "المقارنة", text: "قارن", options: ReviewRules.comparisonOptions, answer: 2, explanation: ""), at: 3)
    ReviewRules.balanceKeepingFixed(&mixed, seed: 7)
    check(mixed[3].options == ReviewRules.comparisonOptions && mixed[3].answer == 2, "bank: comparison options keep their order")
    check(Set(mixed.enumerated().filter { $0.offset != 3 }.map { $0.element.answer }).count > 1
          && mixed.allSatisfy { $0.options[$0.answer].hasPrefix("r") || $0.text == "قارن" }, "bank: other options are shuffled, the right one kept")
    let bankQ = ReviewQuestion(skill: "التناظر", text: "قلم : كتابة", options: ["كتاب : مكتبة", "مقص : قص", "ورق : شجر", "معلم : طالب"],
                               answer: 1, explanation: "")
    let ask = ReviewRules.explainMessages(bankQ, track: .qudurat, hasImage: true)
    check(ask.count == 2 && ask[1]["content"]!.contains("الإجابة الصحيحة: ب) مقص : قص") && ask[1]["content"]!.contains("الصورة")
          && ask[0]["content"]!.contains("القدرات"), "explain: the bank's right answer and the figure are in the request")
    check(ReviewRules.cleanExplanation("```\n## الحل\n**المقص** أداة للقص.\n\n\n\nكما القلم للكتابة.\n```") == "الحل\nالمقص أداة للقص.\n\nكما القلم للكتابة.",
          "explain: fences, Markdown marks and blank runs are removed")
    let unitAsk = ReviewRules.explainMessages(bankQ, track: .curriculum, hasImage: false, reference: "نص الوحدة")
    check(unitAsk[1]["content"]!.hasSuffix("نص الوحدة") && !unitAsk[1]["content"]!.contains("الصورة"),
          "explain: a curriculum question carries its unit's pages")
    check(ReviewRules.cleanExplanation("  \n ") == nil, "explain: an empty reply is refused")
    check(ReviewRules.cleanExplanation(String(repeating: "ا", count: 2000))!.count == ReviewRules.maxExplanation + 1,
          "explain: a long reply is capped")
    let prompt = ReviewRules.userPrompt(subject: "لغتي", targets: ["أ", "ب"], text: "النص", avoid: ["قديم"])
    check(prompt.contains("1. أ") && prompt.contains("2. ب") && prompt.contains("- قديم"), "the prompt lists the skills and the old stems")
}

let sampleBank = """
{"track":"qudurat","version":1,
 "sections":[{"id":"verbal","name":"اللفظي"},{"id":"quant","name":"الكمي"}],
 "questions":[
  {"id":"q1","section":"verbal","skill":"التناظر اللفظي","text":"قلم : كتابة","options":["مقص : قص","باب : خشب","ماء : بحر","شمس : نهار"],"answer":0,"explanation":"القلم أداة الكتابة، والمقص أداة القص."},
  {"id":"q2","section":"verbal","skill":"إكمال الجمل","text":"العلم ...... والجهل ظلام","options":["نور","ماء","طريق","باب"],"answer":0,"explanation":"المقابلة بين النور والظلام."},
  {"id":"q3","section":"verbal","skill":"التناظر اللفظي","text":"طبيب : مستشفى","options":["معلم : مدرسة","كتاب : ورق","سيارة : طريق","قمر : ليل"],"answer":0,"explanation":"مكان العمل."},
  {"id":"q4","section":"quant","skill":"الحساب","text":"٢ + ٣ × ٤ = ؟","options":["14","20","24","9"],"answer":0,"explanation":"الضرب قبل الجمع: ٣×٤=١٢ ثم +٢."},
  {"id":"q5","section":"quant","skill":"الهندسة","text":"مجموع زوايا المثلث؟","options":["180","90","360","270"],"answer":0,"explanation":"مجموع زوايا أي مثلث ١٨٠ درجة."}
 ]}
"""

func bankSelftest() {
    guard let bank = try? Bank.load(Data(sampleBank.utf8)) else {
        check(false, "the sample bank loads")
        return
    }
    check(bank.questions.count == 5 && bank.section["q4"] == "quant", "the sample bank loads with its sections")
    check(Bank.pool(bank, section: "verbal").count == 3 && Bank.pool(bank, section: nil).count == 5, "pools by section")

    let dup = sampleBank.replacingOccurrences(of: "\"id\":\"q2\"", with: "\"id\":\"q1\"")
    check((try? Bank.load(Data(dup.utf8))) == nil, "a repeated id is refused")
    let noWhy = sampleBank.replacingOccurrences(of: "\"explanation\":\"مكان العمل.\"", with: "\"explanation\":\"\"")
    check((try? Bank.load(Data(noWhy.utf8))) != nil, "a bank question needs no explanation")
    let badSection = sampleBank.replacingOccurrences(of: "\"section\":\"quant\",\"skill\":\"الهندسة\"", with: "\"section\":\"x\",\"skill\":\"الهندسة\"")
    check((try? Bank.load(Data(badSection.utf8))) == nil, "an unknown section is refused")

    var rng = SplitMix64(seed: 3)
    let pool = bank.questions
    var seen = Set<String>()
    var firstRound: [String] = []
    for _ in 0..<2 {
        let d = Bank.draw(pool, count: 2, seen: seen, using: &rng)
        firstRound += d.questions.map(\.id)
        seen = d.seen
    }
    check(Set(firstRound).count == 4, "no question comes twice before the pool is done")
    let last = Bank.draw(pool, count: 2, seen: seen, using: &rng)
    check(last.questions.count == 2 && Set(last.questions.map(\.id)).count == 2, "the round's end fills from a new round, no repeat in one review")
    check(last.questions.contains { !firstRound.contains($0.id) }, "the last unseen question comes in the round's end")
    check(last.seen.count == 2, "the new round counts both questions it gave as seen")

    let spread = Bank.spread(Bank.pool(bank, section: "verbal"), count: 2, using: &rng)
    check(Set(spread.map(\.skill)).count == 2, "two questions of a section cover two skills")

    let mixed = Bank.draw(pool, count: 10, seen: [], using: &rng)
    check(mixed.questions.count == 5, "asking more than the pool gives the whole pool once")
}

func bankCheck(_ folder: String) {
    for track in [Track.tahsili, Track.qudurat] {
        let url = URL(fileURLWithPath: folder).appendingPathComponent("\(track.rawValue).json")
        do {
            let bank = try Bank.load(Data(contentsOf: url))
            check(bank.track == track, "\(track.rawValue).json: \(bank.questions.count) questions, \(bank.sections.count) sections")
            let images = Set(bank.questions.compactMap(\.image))
            for name in images {
                let path = URL(fileURLWithPath: folder).appendingPathComponent("images").appendingPathComponent(name).path
                check(FileManager.default.fileExists(atPath: path), "\(track.rawValue): image \(name) is in bank/images")
            }
        } catch {
            check(false, "\(track.rawValue).json: \(error.localizedDescription)")
        }
    }
}

let args = CommandLine.arguments
if args.contains("--review-selftest") { reviewSelftest() }
if args.contains("--bank-selftest") { bankSelftest() }
if let i = args.firstIndex(of: "--bank-check"), i + 1 < args.count { bankCheck(args[i + 1]) }
if args.count < 2 {
    print("RevisalCheck --review-selftest | --bank-selftest | --bank-check <folder>")
    exit(2)
}
print(failures == 0 ? "all checks passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
