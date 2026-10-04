import AppKit

/// Release notes as formatted text for an alert.
///
/// `NSAlert.informativeText` is plain, so the markdown the notes are written in
/// — `**bold**`, `- ` bullets — showed up as literal asterisks and dashes. This
/// renders the inline markdown and swaps list dashes for bullets, inside a
/// scrolling view so several versions' worth fits.
public enum ReleaseNotesView {
    public static func make(markdown: String, width: CGFloat = 440, height: CGFloat = 240) -> NSView {
        let prepared = markdown
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix("- ") ? "•  " + trimmed.dropFirst(2) : String(line)
            }
            .joined(separator: "\n")

        let rendered: NSAttributedString
        if let attributed = try? AttributedString(
            markdown: prepared,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            rendered = NSAttributedString(attributed)
        } else {
            rendered = NSAttributedString(string: prepared)
        }

        let body = NSMutableAttributedString(attributedString: rendered)
        let whole = NSRange(location: 0, length: body.length)
        body.addAttribute(.foregroundColor, value: NSColor.labelColor, range: whole)
        // Keep the bold the markdown asked for; set size and family underneath.
        body.enumerateAttribute(.font, in: whole) { value, range, _ in
            let existing = value as? NSFont
            let bold = existing?.fontDescriptor.symbolicTraits.contains(.bold) == true
            body.addAttribute(.font, value: bold
                ? NSFont.systemFont(ofSize: 12, weight: .semibold)
                : NSFont.systemFont(ofSize: 12), range: range)
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 2
        body.addAttribute(.paragraphStyle, value: paragraph, range: whole)

        // Bullet points get a hanging indent, so a wrapped line sits under the
        // text rather than back at the margin under the bullet.
        let bulletIndent = ("•  " as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
        let hanging = NSMutableParagraphStyle()
        hanging.paragraphSpacing = 2
        hanging.headIndent = bulletIndent
        // Version headings get a little air above them.
        let heading = NSMutableParagraphStyle()
        heading.paragraphSpacingBefore = 6
        heading.paragraphSpacing = 2
        let string = body.string as NSString
        string.enumerateSubstrings(in: whole, options: .byParagraphs) { sub, range, _, _ in
            guard let sub else { return }
            if sub.hasPrefix("•") {
                body.addAttribute(.paragraphStyle, value: hanging, range: range)
            } else if sub.hasPrefix("Murmur ") {
                body.addAttribute(.paragraphStyle, value: heading, range: range)
            }
        }

        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 4, height: 6)
        text.textStorage?.setAttributedString(body)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        text.autoresizingMask = [.width]
        return scroll
    }
}
