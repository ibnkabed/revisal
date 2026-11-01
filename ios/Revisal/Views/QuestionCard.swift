import SwiftUI

/// The app's own look for a question (owner, 2026-11-01): not a copy of the source page, but one template per
/// question kind, a colour per section, and colours on the choice.

/// A section's colour and symbol.
struct SectionTheme {
    let name: String
    let color: Color
    let symbol: String

    static func of(_ section: String?, track: Track) -> SectionTheme {
        switch section {
        case "verbal": return SectionTheme(name: "اللفظي", color: Color(red: 0.42, green: 0.27, blue: 0.75), symbol: "text.book.closed")
        case "quant": return SectionTheme(name: "الكمي", color: Color(red: 0.11, green: 0.45, blue: 0.85), symbol: "function")
        case "math": return SectionTheme(name: "الرياضيات", color: Color(red: 0.05, green: 0.52, blue: 0.62), symbol: "x.squareroot")
        case "physics": return SectionTheme(name: "الفيزياء", color: Color(red: 0.85, green: 0.42, blue: 0.08), symbol: "atom")
        case "chemistry": return SectionTheme(name: "الكيمياء", color: Color(red: 0.80, green: 0.20, blue: 0.40), symbol: "flask")
        case "biology": return SectionTheme(name: "الأحياء", color: Color(red: 0.16, green: 0.58, blue: 0.30), symbol: "leaf")
        default: return SectionTheme(name: track.title, color: .accentColor, symbol: "book")
        }
    }
}

/// How a question is drawn, read from its text.
enum QuestionTemplate {
    case plain(String)
    case passage(passage: String, question: String)
    case comparison(intro: String, first: String, second: String)
    case analogy(left: String, right: String)
    case oddOne

    static let comparisonOptions = ["القيمة الأولى أكبر", "القيمة الثانية أكبر", "القيمتان متساويتان", "المعطيات غير كافية"]

    static func of(_ q: ReviewQuestion) -> QuestionTemplate {
        let text = q.text
        if let split = text.range(of: "\n\n") {
            let passage = String(text[..<split.lowerBound])
            if passage.count > 120 {
                return .passage(passage: passage, question: String(text[split.upperBound...]))
            }
        }
        if let first = text.range(of: "القيمة الأولى:"), let second = text.range(of: "القيمة الثانية:"),
           first.upperBound <= second.lowerBound {
            var intro = String(text[..<first.lowerBound])
            intro = intro.replacingOccurrences(of: "قارن بين:", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: " ،,:"))
            let a = String(text[first.upperBound..<second.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: " ،,"))
            let b = String(text[second.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " ،,"))
            return .comparison(intro: intro, first: a, second: b)
        }
        if q.skill == "المفردة الشاذة" { return .oddOne }
        let parts = text.components(separatedBy: " : ")
        if parts.count == 2, text.count <= 40, !text.contains("؟") {
            return .analogy(left: parts[0], right: parts[1])
        }
        return .plain(text)
    }
}

/// The question's head: its section and skill in colour, and where it is in the review.
struct QuestionHeader: View {
    let theme: SectionTheme
    let skill: String
    let number: Int
    let total: Int

    var body: some View {
        HStack(spacing: 8) {
            Label(theme.name, systemImage: theme.symbol)
                .font(.caption.weight(.bold))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(theme.color))
                .foregroundColor(.white)
            if !skill.isEmpty && skill != theme.name {
                Text(skill)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(theme.color.opacity(0.13)))
                    .foregroundColor(theme.color)
                    .lineLimit(1)
            }
            Spacer()
            Text("\(number)/\(total)")
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundColor(.secondary)
        }
    }
}

/// The body of the question, by its template.
struct QuestionBody: View {
    let question: ReviewQuestion
    let theme: SectionTheme
    @State private var showPassage = true

    var body: some View {
        switch QuestionTemplate.of(question) {
        case .plain(let text):
            stem(text)
        case .passage(let passage, let text):
            VStack(alignment: .leading, spacing: 10) {
                DisclosureGroup(isExpanded: $showPassage) {
                    ScrollView {
                        Text(passage).font(.callout).lineSpacing(5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 260)
                } label: {
                    Label("النص", systemImage: "doc.text").font(.subheadline.weight(.bold)).foregroundColor(theme.color)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 14).fill(theme.color.opacity(0.07)))
                stem(text)
            }
        case .comparison(let intro, let first, let second):
            VStack(alignment: .leading, spacing: 10) {
                Text("قارن بين").font(.headline).foregroundColor(theme.color)
                if !intro.isEmpty { Text(intro).font(.body).fixedSize(horizontal: false, vertical: true) }
                HStack(spacing: 0) {
                    valueCell("القيمة الأولى", first)
                    Rectangle().fill(theme.color.opacity(0.3)).frame(width: 1)
                    valueCell("القيمة الثانية", second)
                }
                .background(RoundedRectangle(cornerRadius: 14).fill(theme.color.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.color.opacity(0.35), lineWidth: 1))
            }
        case .analogy(let left, let right):
            VStack(spacing: 8) {
                Text("اختر العلاقة المشابهة").font(.subheadline).foregroundColor(.secondary)
                HStack(spacing: 14) {
                    Text(left)
                    Text(":").foregroundColor(theme.color)
                    Text(right)
                }
                .font(.title2.weight(.bold))
                .padding(.vertical, 14).frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 14).fill(theme.color.opacity(0.08)))
            }
        case .oddOne:
            Text("أي الكلمات لا تنتمي إلى المجموعة؟")
                .font(.title3.weight(.semibold))
        }
    }

    private func stem(_ text: String) -> some View {
        Text(text).font(.title3.weight(.semibold)).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
    }

    private func valueCell(_ title: String, _ value: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.caption.weight(.bold)).foregroundColor(theme.color)
            Text(value).font(.body.weight(.semibold)).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10).frame(maxWidth: .infinity)
    }
}
