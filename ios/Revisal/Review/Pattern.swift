import Foundation

/// A small, repeatable generator (SplitMix64) for the seeded balance.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// NSRegularExpression in two calls.
enum Pattern {
    static func replace(_ pattern: String, in s: String, with template: String,
                        options: NSRegularExpression.Options = []) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return s }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        return re.stringByReplacingMatches(in: s, options: [], range: range,
                                           withTemplate: NSRegularExpression.escapedTemplate(for: template))
    }

    static func firstMatch(_ pattern: String, in s: String, options: NSRegularExpression.Options = []) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        guard let m = re.firstMatch(in: s, options: [], range: range), let r = Range(m.range, in: s) else { return nil }
        return String(s[r])
    }
}
