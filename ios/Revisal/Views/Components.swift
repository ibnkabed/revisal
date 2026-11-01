import SwiftUI

/// How many questions: 1 to 10 (owner's decision 2026-11-01), remembered per part of the app.
struct CountPicker: View {
    @Binding var count: Int

    var body: some View {
        Stepper(value: $count, in: ReviewRules.minCount...ReviewRules.maxCount) {
            HStack {
                Text("عدد الأسئلة")
                Spacer()
                Text("\(count)").font(.body.monospacedDigit().bold())
            }
        }
    }
}

/// The status lines while a review is made, and its error.
struct ProgressLines: View {
    let lines: [String]
    let running: Bool
    let error: String?

    var body: some View {
        if running || !lines.isEmpty || error != nil {
            Section {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.callout)
                }
                if running { ProgressView() }
                if let error { Text(error).foregroundColor(.red) }
            }
        }
    }
}

/// One past review in a list: its title, date and score.
struct HistoryRow: View {
    let set: ReviewSet

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(set.title).lineLimit(1)
                Text(Self.day(set.createdAt)).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if set.finishedAt != nil {
                Text("\(set.correct)/\(set.questions.count)")
                    .font(.callout.monospacedDigit().bold())
                    .foregroundColor(ScoreColor.of(set.percent))
            } else {
                Text("لم تكتمل").font(.caption).foregroundColor(.orange)
            }
        }
    }

    static func day(_ stamp: String) -> String {
        guard let d = Stamp.date(stamp) else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ar")
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: d)
    }
}

enum ScoreColor {
    static func of(_ percent: Int) -> Color {
        percent >= 85 ? .green : percent >= 60 ? .orange : .red
    }
}

/// The option letters of «اختر الإجابة الصحيحة».
let optionLetters = ["أ", "ب", "ج", "د"]
