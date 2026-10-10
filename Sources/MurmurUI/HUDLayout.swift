import AppKit

/// How the live transcript fits the popup.
///
/// It used to be one SwiftUI Text limited to two lines with head truncation,
/// which keeps the *first* line pinned and truncates the start of the last —
/// so the top line froze and the bottom line slid sideways as words arrived.
/// Instead the text wraps normally, the popup grows to three lines, and past
/// that the oldest line leaves from the top. Measured here with TextKit, so the
/// height and the text shown can be tested without drawing anything.
public enum HUDLayout {
    public static let width: CGFloat = 360
    public static let maxTranscriptLines = 3

    static let horizontalPadding: CGFloat = 14
    static let verticalPadding: CGFloat = 11
    /// Every leading widget — meter, dots, icon — sits in a column this wide,
    /// so the text column is the same width in every state.
    static let leadingWidth: CGFloat = 28
    static let spacing: CGFloat = 11
    static let hintSpacing: CGFloat = 2

    public static var textWidth: CGFloat {
        width - horizontalPadding * 2 - leadingWidth - spacing
    }

    static func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    static let transcriptFont = rounded(13, .medium)
    static let hintFont = rounded(11, .regular)

    static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(NSLayoutManager().defaultLineHeight(for: font))
    }

    /// The last `maxLines` lines of `text` as it wraps at the popup's width.
    /// The cut is made exactly at a line start, so what remains wraps the same
    /// way it did in context.
    public static func tail(of text: String, maxLines: Int = maxTranscriptLines) -> (text: String, lines: Int) {
        guard !text.isEmpty else { return ("", 1) }
        let storage = NSTextStorage(string: text, attributes: [.font: transcriptFont])
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: textWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)

        var starts: [Int] = []
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { _, _, _, glyphs, _ in
            starts.append(manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil).location)
        }
        let lines = max(1, starts.count)
        guard lines > maxLines else { return (text, lines) }
        let cut = starts[lines - maxLines]
        let from = String.Index(utf16Offset: cut, in: text)
        return (String(text[from...]), maxLines)
    }

    public static func height(transcriptLines: Int, hint: Bool) -> CGFloat {
        let lines = CGFloat(min(max(transcriptLines, 1), maxTranscriptLines))
        var h = verticalPadding * 2 + lines * lineHeight(transcriptFont)
        if hint { h += hintSpacing + lineHeight(hintFont) }
        // Never shorter than the level meter plus its padding.
        return max(h, 26 + verticalPadding * 2)
    }

    /// Title over instruction.
    public static var noticeHeight: CGFloat {
        verticalPadding * 2 + lineHeight(rounded(13, .semibold)) + hintSpacing + lineHeight(rounded(12, .regular))
    }

    /// The tallest the popup gets. Placement reserves this much, so growing
    /// never pushes it off-screen or over the line being typed on.
    public static var maxHeight: CGFloat {
        height(transcriptLines: maxTranscriptLines, hint: true)
    }
}
