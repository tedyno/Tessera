import AppKit

/// NSTextView whose autocompletion only commits on an explicit Tab / Return / click.
/// The default behaviour inserts a "tentative" match and commits it on any movement
/// (e.g. arrow keys), which surprises users; here nothing changes the text unless
/// the completion is actively confirmed.
final class CompletingTextView: NSTextView {
    var placeholder: String?

    override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange,
                                   movement: Int, isFinal flag: Bool) {
        // Only an explicit Tab (or a click on the list) commits. Previews, arrow-key
        // navigation, and Return never change the text.
        let confirmed = flag && (movement == NSTextMovement.tab.rawValue
                                 || movement == NSTextMovement.other.rawValue)
        guard confirmed else { return }
        super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: flag)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, let placeholder, !placeholder.isEmpty, let font else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.placeholderTextColor,
        ]
        let padding = textContainer?.lineFragmentPadding ?? 0
        let origin = NSPoint(x: textContainerInset.width + padding, y: textContainerInset.height)
        placeholder.draw(at: origin, withAttributes: attributes)
    }
}
