import Foundation

/// A message for the student about the book or its pages, in Arabic.
struct BookError: LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Book text

enum BookRules {
    /// Pages per unit: enough for a unit, small enough for every provider.
    static let maxPages = 30
    static let minCharsPerPage = 120
    static let commonArabic: Set<String> = ["في", "من", "على", "إلى", "الى", "عن", "أن", "ان", "التي", "الذي",
                                            "هذا", "هذه", "مع", "كان", "لا", "ما", "هو", "هي"]

    /// Pages a...b (1-based) of a book of `pages` pages.
    @discardableResult
    static func checkRange(from a: Int, to b: Int, pages: Int) throws -> (from: Int, to: Int) {
        guard 1 <= a, a <= b, b <= pages else {
            throw BookError("الصفحات من 1 إلى \(pages)، والأولى قبل الأخيرة")
        }
        if b - a + 1 > maxPages {
            throw BookError("الوحدة \(maxPages) صفحة على الأكثر")
        }
        return (a, b)
    }

    static func isArabic(_ u: Unicode.Scalar) -> Bool { (0x0600...0x06FF).contains(u.value) }

    /// Presentation forms -> letters (NFKC); lines stored backwards (visual order) -> turned around, but only
    /// when the reversed common words clearly outnumber the forward ones.
    static func fixArabic(_ raw: String) -> String {
        var text = raw.precomposedStringWithCompatibilityMapping
        var words: [String] = []
        var word = String.UnicodeScalarView()
        for u in text.unicodeScalars {
            if isArabic(u) {
                word.append(u)
            } else if !word.isEmpty {
                words.append(String(word))
                word = String.UnicodeScalarView()
            }
        }
        if !word.isEmpty { words.append(String(word)) }
        let forward = words.filter { commonArabic.contains($0) }.count
        let backward = words.filter { commonArabic.contains(reversed($0)) }.count
        if backward > forward * 2 && backward >= 3 {
            text = text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
                .map { reversed(String($0)) }
                .joined(separator: "\n")
        }
        return text
    }

    /// Code point order reversed (Python's s[::-1]).
    static func reversed(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.reversed()))
    }

    /// The pages' joined text as the AI gets it: Arabic fixed, blank runs and spaces squeezed, trimmed.
    static func tidy(_ raw: String) -> String {
        var text = raw
        if text.unicodeScalars.contains(where: isArabic) {
            text = fixArabic(text)
        }
        text = Pattern.replace(#"\n{3,}"#, in: text, with: "\n\n")
        text = Pattern.replace(#"[ \t]+"#, in: text, with: " ")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// False when the pages are (mostly) scanned images: then Gemini reads the PDF itself.
    static func isReadable(_ text: String, pages: Int) -> Bool {
        Double(text.unicodeScalars.count) >= Double(minCharsPerPage) * Double(pages) * 0.5
    }
}
