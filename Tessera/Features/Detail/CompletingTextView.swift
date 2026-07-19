import AppKit

/// NSTextView whose autocompletion only commits on an explicit Tab / Return / click.
/// The default behaviour inserts a "tentative" match and commits it on any movement
/// (e.g. arrow keys), which surprises users; here nothing changes the text unless
/// the completion is actively confirmed.
final class CompletingTextView: NSTextView {
    var placeholder: String?

    /// Undo automatic capitalization: if the character being inserted differs only in
    /// case from the key the user actually pressed (and they didn't hold Shift/Caps
    /// Lock), keep what they typed. This runs even when the substitution bypasses the
    /// shouldChangeText delegates.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        let inserted = (string as? String) ?? (string as? NSAttributedString)?.string
        if let inserted, inserted.count == 1,
           let event = NSApp.currentEvent, event.type == .keyDown,
           let typed = event.charactersIgnoringModifiers, typed.count == 1,
           inserted != typed, inserted.lowercased() == typed.lowercased(),
           !event.modifierFlags.contains(.shift), !event.modifierFlags.contains(.capsLock) {
            super.insertText(typed, replacementRange: replacementRange)
            return
        }
        super.insertText(string, replacementRange: replacementRange)
    }

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
