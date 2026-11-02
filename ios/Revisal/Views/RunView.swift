import SwiftUI

/// Answering a review one question at a time, then its result. «حدّث» brings new questions from the same
/// source in place of these; «أعد أخطائي» asks again only the ones missed.
struct RunView: View {
    @State var setId: String
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var ai: AIClient
    @Environment(\.dismiss) private var dismiss

    @State private var index = 0
    @State private var refreshing = false
    @State private var lines: [String] = []
    @State private var error: String?

    private var set: ReviewSet? { store.reviewSet(setId) }

    var body: some View {
        NavigationStack {
            Group {
                if refreshing || error != nil {
                    Form { ProgressLines(lines: lines, running: refreshing, error: error) }
                } else if let set {
                    if set.finishedAt != nil {
                        ResultView(set: set, retry: retry, refresh: refresh)
                    } else {
                        QuestionPage(set: set, index: $index, explain: store.db.settings.explainEach) {
                            store.finish(set.id)
                        }
                    }
                } else {
                    Text("المراجعة غير موجودة").foregroundColor(.secondary)
                }
            }
            .navigationTitle(set?.title ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إغلاق") { dismiss() }.disabled(refreshing)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        refresh()
                    } label: {
                        Label("حدّث", systemImage: "arrow.clockwise")
                    }
                    .disabled(refreshing || set == nil)
                }
            }
        }
        .interactiveDismissDisabled(refreshing)
    }

    /// New questions from the same source (the same unit, or the next questions of the bank).
    private func refresh() {
        guard let source = set?.source else { return }
        refreshing = true
        error = nil
        lines = []
        Task {
            defer { refreshing = false }
            do {
                let fresh = try await ReviewMaker.make(source, store: store, ai: ai) { lines.append($0) }
                index = 0
                lines = []
                setId = fresh.id
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// The missed questions again, with their options in a new order.
    private func retry() {
        guard let set, !set.missed.isEmpty else { return }
        var again = set.missed
        ReviewRules.balanceKeepingFixed(&again, seed: nil)
        let next = ReviewSet(title: set.title + " · أخطائي", source: set.source, questions: again)
        store.add(next)
        index = 0
        setId = next.id
    }
}

/// One question: the skill it targets, the stem, four options. After a choice: right or wrong, and the
/// explanation (curriculum questions only) when the settings ask for it.
struct QuestionPage: View {
    let set: ReviewSet
    @Binding var index: Int
    let explain: Bool
    let onFinish: () -> Void
    @EnvironmentObject private var store: Store

    var body: some View {
        let i = min(index, max(set.questions.count - 1, 0))
        let q = set.questions[i]
        let chosen = set.choices[i]
        let theme = SectionTheme.of(q.section, track: set.source.track)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ProgressView(value: Double(i + (chosen == nil ? 0 : 1)), total: Double(set.questions.count))
                    .tint(theme.color)
                VStack(alignment: .leading, spacing: 16) {
                    QuestionHeader(theme: theme, skill: q.skill, number: i + 1, total: set.questions.count)
                    if let image = q.image, let url = BankStore.imageURL(image), let ui = UIImage(contentsOfFile: url.path) {
                        Image(uiImage: ui).resizable().scaledToFit().frame(maxWidth: .infinity)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.color.opacity(0.25)))
                    }
                    QuestionBody(question: q, theme: theme).id(q.id)
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 20).fill(Color(.secondarySystemBackground)))
                .overlay(alignment: .top) {
                    UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20)
                        .fill(theme.color).frame(height: 5)
                }
                ForEach(0..<q.options.count, id: \.self) { k in
                    OptionButton(letter: optionLetters[k], text: q.options[k], tint: theme.color,
                                 state: OptionButton.state(k, chosen: chosen, answer: q.answer, reveal: explain)) {
                        withAnimation(.easeOut(duration: 0.2)) { store.choose(set.id, question: i, option: k) }
                        if !explain {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { next(from: i) }
                        }
                    }
                    .disabled(chosen != nil)
                }
                if explain, let chosen {
                    Feedback(right: chosen == q.answer, answer: q.options[q.answer],
                             letter: optionLetters[q.answer], explanation: q.explanation)
                    ExplainBox(question: q, track: set.source.track, unitId: set.unitId).id(q.id)
                    Button {
                        next(from: i)
                    } label: {
                        Text(i + 1 < set.questions.count ? "التالي" : "النتيجة").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.color)
                    .controlSize(.large)
                }
            }
            .padding()
        }
    }

    private func next(from i: Int) {
        if i + 1 < set.questions.count {
            index = i + 1
        } else {
            onFinish()
        }
    }
}

struct SkillTag: View {
    let skill: String

    var body: some View {
        if !skill.isEmpty {
            Label(skill, systemImage: "target")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                .foregroundColor(.accentColor)
        }
    }
}

struct OptionButton: View {
    enum Look { case idle, picked, right, wrong, dim }
    let letter: String
    let text: String
    var tint: Color = .accentColor
    let state: Look
    let action: () -> Void

    static func state(_ k: Int, chosen: Int?, answer: Int, reveal: Bool) -> Look {
        guard let chosen else { return .idle }
        if !reveal { return k == chosen ? .picked : .dim }
        if k == answer { return .right }
        return k == chosen ? .wrong : .dim
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Text(letter).font(.headline).frame(width: 30, height: 30)
                    .foregroundColor(state == .idle || state == .dim ? color : .white)
                    .background(Circle().fill(state == .idle || state == .dim ? color.opacity(0.15) : color))
                Text(text).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if state == .right { Image(systemName: "checkmark.circle.fill").foregroundColor(.green) }
                if state == .wrong { Image(systemName: "xmark.circle.fill").foregroundColor(.red) }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(color.opacity(state == .idle ? 0.05 : 0.14)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(color.opacity(state == .idle ? 0.3 : 0.9), lineWidth: state == .idle ? 1 : 2))
            .scaleEffect(state == .picked || state == .right ? 1.01 : 1)
            .opacity(state == .dim ? 0.5 : 1)
        }
        .buttonStyle(.plain)
    }

    private var color: Color {
        switch state {
        case .right: return .green
        case .wrong: return .red
        default: return tint
        }
    }
}

struct Feedback: View {
    let right: Bool
    let answer: String
    let letter: String
    let explanation: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(right ? "إجابة صحيحة" : "الإجابة الصحيحة: \(letter)) \(answer)",
                  systemImage: right ? "checkmark.seal.fill" : "lightbulb.fill")
                .font(.headline)
                .foregroundColor(right ? .green : .orange)
            if !explanation.isEmpty {
                Text(explanation).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
    }
}

/// The score, then every question with the student's choice, the right answer and why it is right.
struct ResultView: View {
    let set: ReviewSet
    let retry: () -> Void
    let refresh: () -> Void

    var body: some View {
        List {
            Section {
                VStack(spacing: 6) {
                    Text("\(set.correct) من \(set.questions.count)")
                        .font(.system(size: 44, weight: .bold).monospacedDigit())
                        .foregroundColor(ScoreColor.of(set.percent))
                    Text(verdict).font(.headline)
                    Text("\(set.percent)٪").foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                if !set.missed.isEmpty {
                    Button(action: retry) {
                        Label("أعد أخطائي (\(set.missed.count))", systemImage: "arrow.uturn.backward")
                    }
                }
                Button(action: refresh) {
                    Label(set.source.track == .curriculum ? "حدّث: أسئلة جديدة" : "حدّث: أسئلة أخرى من البنك",
                          systemImage: "arrow.clockwise")
                }
            }
            if !skillLines.isEmpty {
                Section("حسب المهارة") {
                    ForEach(skillLines) { line in
                        HStack {
                            Text(line.skill).lineLimit(2)
                            Spacer()
                            Text("\(line.right)/\(line.total)").monospacedDigit()
                                .foregroundColor(line.right == line.total ? .green : .orange)
                        }
                    }
                }
            }
            Section("الأسئلة") {
                ForEach(Array(set.questions.enumerated()), id: \.element.id) { i, q in
                    AnswerRow(n: i + 1, question: q, chosen: set.choices[i], track: set.source.track, unitId: set.unitId)
                }
            }
        }
    }

    private var verdict: String {
        switch set.percent {
        case 100: return "ممتاز، فهمك للمحتوى كامل"
        case 85...: return "ممتاز، راجع ما أخطأت فيه"
        case 60...: return "جيد، وتحتاج مراجعة بعض النقاط"
        default: return "راجع هذا الجزء ثم أعد المحاولة"
        }
    }

    struct SkillLine: Identifiable {
        let skill: String
        let right: Int
        let total: Int
        var id: String { skill }
    }

    private var skillLines: [SkillLine] {
        var order: [String] = []
        var right: [String: Int] = [:], total: [String: Int] = [:]
        for (q, c) in zip(set.questions, set.choices) where !q.skill.isEmpty {
            if total[q.skill] == nil { order.append(q.skill) }
            total[q.skill, default: 0] += 1
            if c == q.answer { right[q.skill, default: 0] += 1 }
        }
        return order.count > 1 ? order.map { SkillLine(skill: $0, right: right[$0] ?? 0, total: total[$0] ?? 0) } : []
    }
}

struct AnswerRow: View {
    let n: Int
    let question: ReviewQuestion
    let chosen: Int?
    let track: Track
    let unitId: String?

    var body: some View {
        let right = chosen == question.answer
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Image(systemName: right ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(right ? .green : .red)
                Text("\(n). \(question.text)").font(.body.weight(.medium))
            }
            SkillTag(skill: question.skill)
            if let chosen, !right {
                Text("إجابتك: \(optionLetters[chosen])) \(question.options[chosen])").foregroundColor(.red).font(.callout)
            } else if chosen == nil {
                Text("لم تُجب").foregroundColor(.red).font(.callout)
            }
            Text("الصحيحة: \(optionLetters[question.answer])) \(question.options[question.answer])")
                .foregroundColor(.green).font(.callout)
            if !question.explanation.isEmpty {
                Text(question.explanation).font(.callout).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ExplainBox(question: question, track: track, unitId: unitId)
        }
        .padding(.vertical, 4)
    }
}

/// «اشرح لي» under every question, bank or المنهج (owner, 2026-11-02): the student's own linked provider explains
/// why the answer is right, once; the explanation is kept on the phone. A question with a figure goes to Gemini,
/// which sees the picture; an المنهج question sends its unit's pages as the reference. A review saved before
/// 2026-11-02 shows the explanation it was written with instead.
struct ExplainBox: View {
    let question: ReviewQuestion
    let track: Track
    var unitId: String? = nil
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var ai: AIClient
    @State private var asking = false
    @State private var error: String?

    var body: some View {
        if question.explanation.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if let text = store.explanation(question.id) {
                    Label("الشرح", systemImage: "text.bubble").font(.subheadline.weight(.bold)).foregroundColor(.secondary)
                    Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
                } else if asking {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("أطلب الشرح…").foregroundColor(.secondary)
                    }
                } else {
                    Button(action: explain) {
                        Label("اشرح لي", systemImage: "text.bubble")
                    }
                    .buttonStyle(.bordered)
                }
                if let error {
                    Text(error).font(.callout).foregroundColor(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func explain() {
        if ai.linked.isEmpty {
            error = "الشرح يكتبه الذكاء الاصطناعي بمفتاحك المجاني: اربط مزوّدًا من «الإعدادات»، وGemini يكفي."
            return
        }
        asking = true
        error = nil
        Task {
            defer { asking = false }
            do {
                let image = question.image.flatMap { BankStore.imageURL($0) }.flatMap { url in
                    (try? Data(contentsOf: url)).map { (data: $0, ext: url.pathExtension.lowercased()) }
                }
                let messages = ReviewRules.explainMessages(question, track: track, hasImage: image != nil,
                                                           reference: unitId.flatMap { store.unitText($0) })
                let reply: String
                if let image {
                    let prompt = messages.map { $0["content"] ?? "" }.joined(separator: "\n\n")
                    reply = try await ai.gemini(image.data, mime: image.ext == "png" ? "image/png" : "image/jpeg", prompt: prompt,
                                                missing: "في هذا السؤال شكل يراه Gemini وحده: اربط Gemini من «الإعدادات» ليشرحه.")
                } else {
                    reply = try await ai.chat(messages, jsonMode: false, temperature: 0.3).text
                }
                guard let text = ReviewRules.cleanExplanation(reply) else {
                    error = "لم يصل شرح. جرّب مرة أخرى."
                    return
                }
                store.saveExplanation(question.id, text)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
