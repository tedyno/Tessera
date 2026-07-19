import AppKit

/// NSTextView with a fully custom completion popup. The popup only *shows*
/// suggestions — the text is never modified until the user presses Tab (or clicks a
/// row). Arrow keys move the selection, Escape hides, and everything else types
/// normally. Automatic capitalization is also undone at the source.
final class CompletingTextView: NSTextView {
    var placeholder: String?

    /// Supplies the range to replace and the candidate list for the current caret.
    /// Return an empty list to hide the popup.
    var completionSource: ((_ text: String, _ caret: Int) -> (range: NSRange, items: [String]))?

    private let popup = CompletionPopup()
    private var completionRange = NSRange(location: 0, length: 0)
    private var suppressNextUpdate = false

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        popup.onClickCommit = { [weak self] in self?.commitCompletion() }
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        popup.onClickCommit = { [weak self] in self?.commitCompletion() }
    }

    // MARK: Auto-capitalization guard

    /// If the character being inserted differs only in case from the key the user
    /// actually pressed (no Shift/Caps Lock), keep what they typed.
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

    // MARK: Key handling

    override func keyDown(with event: NSEvent) {
        if popup.isVisible {
            switch event.keyCode {
            case 125: popup.moveSelection(1); return            // ↓
            case 126: popup.moveSelection(-1); return           // ↑
            case 48:  commitCompletion(); return                // Tab
            case 53:  popup.hide(); return                      // Esc
            case 123, 124: popup.hide(); super.keyDown(with: event); return  // ← →
            case 36:  popup.hide(); super.keyDown(with: event); return       // Return
            default:  super.keyDown(with: event)                // typing → updateCompletion()
            }
        } else {
            super.keyDown(with: event)
        }
    }

    override func didChangeText() {
        super.didChangeText()
        updateCompletion()
    }

    override func mouseDown(with event: NSEvent) {
        popup.hide()
        super.mouseDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        popup.hide()
        return super.resignFirstResponder()
    }

    // MARK: Completion

    private func updateCompletion() {
        if suppressNextUpdate { suppressNextUpdate = false; popup.hide(); return }
        guard let completionSource, selectedRange().length == 0, let window else { popup.hide(); return }
        let caret = selectedRange().location
        let (range, items) = completionSource(string, caret)
        guard !items.isEmpty else { popup.hide(); return }
        completionRange = range
        // Anchor the popup just below the caret.
        let caretRect = firstRect(forCharacterRange: NSRange(location: caret, length: 0), actualRange: nil)
        let point = NSPoint(x: caretRect.minX, y: caretRect.minY - 3)
        popup.show(items: items, belowPoint: point, parent: window)
    }

    private func commitCompletion() {
        guard let item = popup.selectedItem else { popup.hide(); return }
        let range = completionRange.location + completionRange.length <= (string as NSString).length
            ? completionRange
            : NSRange(location: selectedRange().location, length: 0)
        popup.hide()
        suppressNextUpdate = true
        if shouldChangeText(in: range, replacementString: item) {
            replaceCharacters(in: range, with: item)
            didChangeText()
        }
        setSelectedRange(NSRange(location: range.location + (item as NSString).length, length: 0))
    }

    // MARK: Placeholder

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
