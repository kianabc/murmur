import Foundation
import MurmurCore

/// Whether a transcript is simple enough not to be worth sending to a model.
///
/// "Change it to 15" has nothing in it for a language model to do: no filler to
/// strip, no self-correction to resolve, no ambiguity to settle from context.
/// Sending it anyway costs a round trip you wait through, which is felt far more
/// on a four-word phrase than on a paragraph.
///
/// The rule is word count and nothing cleverer, deliberately. Anything smarter —
/// guessing whether a phrase "looks like it needs help" — would make it
/// unpredictable which dictations get cleaned, and being able to trust what the
/// app is about to do matters more than squeezing out the last few calls.
public enum ShortPhrasePolicy {
    /// Counts words the way a person would: runs of non-space separated by space.
    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace)
            .filter { $0.contains(where: \.isLetter) || $0.contains(where: \.isNumber) }
            .count
    }

    public static func isShort(_ text: String, maxWords: Int) -> Bool {
        wordCount(text) <= maxWords
    }
}

public enum ShortPhrasePreference {
    private static let enabledKey = "com.torimi.murmur.cleanup.skipShort"
    private static let maxWordsKey = "com.torimi.murmur.cleanup.skipShortMaxWords"

    /// Offered in the UI, in words.
    public static let choices = [3, 6, 10, 15]

    /// Six covers "change it to 15" and "remind me tomorrow morning" while
    /// leaving anything sentence-shaped to the model.
    public static let defaultMaxWords = 6

    public static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    public static var maxWords: Int {
        get { UserDefaults.standard.object(forKey: maxWordsKey) as? Int ?? defaultMaxWords }
        set { UserDefaults.standard.set(newValue, forKey: maxWordsKey) }
    }

    /// The single question the dictation path asks.
    public static func shouldSkip(_ text: String) -> Bool {
        isEnabled && ShortPhrasePolicy.isShort(text, maxWords: maxWords)
    }
}
