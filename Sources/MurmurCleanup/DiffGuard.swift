import Foundation

/// Rejects a cleanup that changed too much.
///
/// This is the single most important safety net in the app. The same capability
/// that turns "3, sorry 4, books" into "4 books" will happily invent a clause —
/// and text is pasted straight into Slack and email, where one hallucinated
/// sentence destroys trust permanently. A wrong-but-unedited transcript is
/// always the better failure (SPEC.md §1, §5).
public enum DiffGuard {
    public enum Verdict: Equatable {
        case accept
        case reject(String)

        public var isAccepted: Bool { self == .accept }
    }

    /// Fraction of tokens allowed to change. Disfluency removal and
    /// self-correction resolution legitimately delete a lot, so this is loose —
    /// it's here to catch invention, not to police editing.
    public static let maxChangeRatio = 0.5

    public static func check(raw: String, cleaned: String) -> Verdict {
        let cleanedTrimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedTrimmed.isEmpty else { return .reject("empty output") }

        // A model that opens with "Here is the cleaned text:" ignored the schema.
        // Only when the speaker didn't open that way themselves: people begin
        // sentences with "Okay" and "Sure" constantly, and rejecting those threw
        // away cleanups that had already been paid for.
        let preamble = #"^(here('| i)s|sure|okay|certainly|cleaned|output)\b"#
        let rawTrimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedOpensThatWay = cleanedTrimmed.range(
            of: preamble, options: [.regularExpression, .caseInsensitive]
        ) != nil
        let rawOpensThatWay = rawTrimmed.range(
            of: preamble, options: [.regularExpression, .caseInsensitive]
        ) != nil
        if cleanedOpensThatWay && !rawOpensThatWay {
            return .reject("preamble in output")
        }

        let rawTokens = tokens(raw)
        let cleanTokens = tokens(cleanedTrimmed)
        guard !rawTokens.isEmpty else { return .accept }

        // Growth is the strongest invention signal — cleanup should shrink text
        // or leave it roughly the same, never balloon it.
        if cleanTokens.count > Int(Double(rawTokens.count) * 1.4) + 3 {
            return .reject("output grew \(rawTokens.count)→\(cleanTokens.count) tokens")
        }

        // Every content word in the output should trace back to the input.
        // Punctuation and capitalisation are fair game; new *words* are not.
        let rawSet = Set(rawTokens.map(normalise))
        let invented = cleanTokens.map(normalise).filter { token in
            token.count > 3 && !rawSet.contains(token)
        }
        if Double(invented.count) > Double(cleanTokens.count) * 0.25 {
            return .reject("invented words: \(invented.prefix(4).joined(separator: ", "))")
        }

        let distance = editDistance(rawTokens.map(normalise), cleanTokens.map(normalise))
        let ratio = Double(distance) / Double(rawTokens.count)
        if ratio > maxChangeRatio {
            return .reject(String(format: "changed %.0f%% of tokens", ratio * 100))
        }

        return .accept
    }

    private static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static func normalise(_ token: String) -> String {
        token.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func editDistance(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(current[j - 1] + 1, previous[j] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
