import Foundation

/// A compact phonetic key, used to decide whether an edit was a *mishearing*
/// ("Versell" → "Vercel") or a *change of mind* ("books" → "notebooks").
///
/// This gate is what makes automatic correction-learning usable — without it,
/// post-paste diffs are too noisy to learn from, because people edit dictated
/// text for all sorts of reasons that aren't transcription errors.
///
/// Deliberately spelling-based and therefore imperfect: "Neev" and "Niamh" sound
/// identical but key differently, because English orthography doesn't encode
/// that. Explicit corrections skip this gate entirely for exactly that reason —
/// when the user tells us directly, we don't need to guess.
public enum Phonetics {
    /// Maps a word to a rough consonant skeleton. Vowels are dropped after the
    /// first character, and letters that commonly sound alike collapse together.
    public static func key(_ word: String) -> String {
        let lower = word.lowercased().filter { $0.isLetter }
        guard !lower.isEmpty else { return "" }

        var out = ""
        var previous: Character = " "
        for (index, char) in lower.enumerated() {
            let code = reduce(char, previous: previous)
            // Keep a leading vowel — it's load-bearing for short names — but drop
            // interior ones, which is where most transcription variance lives.
            if code == "*" {
                if index == 0 { out.append("A") }
                previous = char
                continue
            }
            if out.last != code { out.append(code) }
            previous = char
        }
        return out
    }

    private static func reduce(_ char: Character, previous: Character) -> Character {
        switch char {
        case "a", "e", "i", "o", "u", "y": return "*"
        case "b", "p": return "P"
        case "c", "k", "q": return "K"
        case "d", "t": return "T"
        case "f", "v": return "F"
        case "g", "j": return "J"
        case "l": return "L"
        case "m", "n": return "N"
        case "r": return "R"
        case "s", "z", "x": return "S"
        case "w", "h": return "W"
        default: return "*"
        }
    }

    /// True when two words are close enough to plausibly be the same utterance
    /// heard two ways.
    public static func soundAlike(_ a: String, _ b: String) -> Bool {
        let ka = key(a), kb = key(b)
        guard !ka.isEmpty, !kb.isEmpty else { return false }
        if ka == kb { return true }
        // Allow one substitution/insertion in the skeleton — "Verscel" vs
        // "Vercel" shouldn't need an exact match to count.
        return editDistance(ka, kb) <= 1 && min(ka.count, kb.count) >= 3
    }

    /// Levenshtein distance. Also used by the cleanup diff guard (SPEC.md §5).
    public static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }

        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)

        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = min(current[j - 1] + 1, previous[j] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[y.count]
    }
}
