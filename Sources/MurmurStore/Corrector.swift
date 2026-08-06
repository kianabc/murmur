import Foundation

/// Applies learned corrections, and infers new ones from what the user edits.
///
/// Runs *before* the LLM cleanup pass so the model never sees the corrupted
/// token, and costs nothing — it's a lookup, not an inference.
public struct Corrector {
    private let store: CorrectionStore

    public init(store: CorrectionStore) {
        self.store = store
    }

    // MARK: - Applying

    /// Rewrites known mishearings. Longest phrases first, so a multi-word entry
    /// ("deploy on Versell") wins over a single-word one that overlaps it.
    public func apply(to text: String, appBundleID: String? = nil) -> String {
        let corrections = store.active(for: appBundleID)
        guard !corrections.isEmpty else { return text }

        var result = text
        for correction in corrections {
            result = Self.replace(correction.heard, with: correction.meant, in: result)
        }
        return result
    }

    /// Whole-word, case-insensitive replacement that carries the original
    /// capitalisation across — so a sentence-initial "Versell" becomes "Vercel",
    /// not "vercel".
    static func replace(_ needle: String, with replacement: String, in haystack: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: needle)
        guard let regex = try? NSRegularExpression(
            pattern: "\\b\(escaped)\\b",
            options: [.caseInsensitive]
        ) else { return haystack }

        let full = NSRange(haystack.startIndex..., in: haystack)
        var output = haystack
        // Work backwards so earlier ranges stay valid as we mutate.
        for match in regex.matches(in: haystack, range: full).reversed() {
            guard let range = Range(match.range, in: output) else { continue }
            let original = String(output[range])
            output.replaceSubrange(range, with: matchCase(of: original, to: replacement))
        }
        return output
    }

    /// Only mirrors leading-capital and all-caps; anything fancier does more harm
    /// than good on proper nouns, which are most of what lands here.
    private static func matchCase(of original: String, to replacement: String) -> String {
        guard let first = original.first else { return replacement }
        if original.count > 1, original == original.uppercased(), original.rangeOfCharacter(from: .lowercaseLetters) == nil {
            return replacement.uppercased()
        }
        if first.isUppercase {
            return replacement.prefix(1).uppercased() + replacement.dropFirst()
        }
        return replacement
    }

    // NOTE: corrections are taught explicitly, never inferred.
    //
    // An earlier version diffed the pasted text against what the user left
    // behind and learned substitutions that passed a phonetic similarity gate.
    // It was removed deliberately: people rewrite dictated text because they
    // changed their mind at least as often as because it was misheard, and a
    // wrong entry in this ledger silently corrupts text that was already right.
    // The failure is invisible and compounding, which is the worst shape a bug
    // can have in a tool you type into all day.
    //
    // If automatic detection ever comes back, it should *suggest* and never
    // apply — a queue the user approves, not a write.
}
