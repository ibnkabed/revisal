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
        ReviewRules.balance(&again, seed: nil)
        let next = ReviewSet(title: set.title + " · أخطائي", source: set.source, questions: again)
        store.add(next)
        index = 0
        setId = next.id
    }
}

/// One question: the skill it targets, the stem, four options. After a choice: right or wrong, and the
/// explanation when the settings ask for it.
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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("السؤال \(i + 1) من \(set.questions.count)").font(.subheadline).foregroundColor(.secondary)
                    Spacer()
                }
                ProgressView(value: Double(i + (chosen == nil ? 0 : 1)), total: Double(set.questions.count))
                SkillTag(skill: q.skill)
                if let image = q.image, let url = BankStore.imageURL(image), let ui = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: ui).resizable().scaledToFit().frame(maxWidth: .infinity)
                }
                Text(q.text).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                ForEach(0..<q.options.count, id: \.self) { k in
                    OptionButton(letter: optionLetters[k], text: q.options[k],
                                 state: OptionButton.state(k, chosen: chosen, answer: q.answer, reveal: explain)) {
                        store.choose(set.id, question: i, option: k)
                        if !explain { next(from: i) }
                    }
                    .disabled(chosen != nil)
                }
                if explain, let chosen {
                    Feedback(right: chosen == q.answer, answer: q.options[q.answer],
                             letter: optionLetters[q.answer], explanation: q.explanation)
                    Button {
                        next(from: i)
                    } label: {
                        Text(i + 1 < set.questions.count ? "التالي" : "النتيجة").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
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
    enum State { case idle, right, wrong, dim }
    let letter: String
    let text: String
    let state: State
    let action: () -> Void

    static func state(_ k: Int, chosen: Int?, answer: Int, reveal: Bool) -> State {
        guard let chosen else { return .idle }
        if !reveal { return k == chosen ? .right : .dim }
        if k == answer { return .right }
        return k == chosen ? .wrong : .dim
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Text(letter).font(.headline).frame(width: 28, height: 28)
                    .background(Circle().fill(tint.opacity(0.18)))
                Text(text).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if state == .right { Image(systemName: "checkmark.circle.fill").foregroundColor(.green) }
                if state == .wrong { Image(systemName: "xmark.circle.fill").foregroundColor(.red) }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(tint.opacity(state == .idle ? 0.06 : 0.12)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(tint.opacity(0.5), lineWidth: state == .idle ? 0.5 : 1.5))
            .opacity(state == .dim ? 0.55 : 1)
        }
        .buttonStyle(.plain)
    }

    private var tint: Color {
        switch state {
        case .right: return .green
        case .wrong: return .red
        default: return .accentColor
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
            Text(explanation).fixedSize(horizontal: false, vertical: true)
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
                    ForEach(skillLines, id: \.skill) { line in
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
                    AnswerRow(n: i + 1, question: q, chosen: set.choices[i])
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

    private var skillLines: [(skill: String, right: Int, total: Int)] {
        var order: [String] = []
        var right: [String: Int] = [:], total: [String: Int] = [:]
        for (q, c) in zip(set.questions, set.choices) where !q.skill.isEmpty {
            if total[q.skill] == nil { order.append(q.skill) }
            total[q.skill, default: 0] += 1
            if c == q.answer { right[q.skill, default: 0] += 1 }
        }
        return order.count > 1 ? order.map { ($0, right[$0] ?? 0, total[$0] ?? 0) } : []
    }
}

struct AnswerRow: View {
    let n: Int
    let question: ReviewQuestion
    let chosen: Int?

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
            Text(question.explanation).font(.callout).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}
