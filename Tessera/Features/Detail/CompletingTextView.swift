import AppKit
import DBKit

// `SQLCompletionItem` now lives in TesseraCore (DBKit) alongside the pure
// `SQLCompletionEngine`, so the completion logic is unit-testable without AppKit.

/// NSTextView with a fully custom completion popup. The popup only *shows*
/// suggestions — the text is never modified until the user presses Tab/Return (or
/// clicks a row). Arrow keys move the selection, Escape hides it when open and
/// asks for suggestions when closed (⌃Space also asks, but macOS usually grabs it
/// for the input-source switch), and everything else types normally. Automatic
/// capitalization is also undone at the source.
final class CompletingTextView: NSTextView {
    var placeholder: String?

    /// Supplies the range to replace and the candidate list for the current caret.
    /// `forced` marks an explicit ⌃Space request (suggest even with no prefix).
    /// Return an empty list to hide the popup.
    var completionSource: ((_ text: String, _ caret: Int, _ forced: Bool) -> (range: NSRange, items: [SQLCompletionItem]))?

    /// Called when the editor is clicked/focused, so its pane can take focus in a
    /// tiled layout (menus and ⌘-shortcuts otherwise target the wrong pane).
    var onFocus: (() -> Void)?

    /// Called after a JOIN completion aliases a table, so existing `tableName.`
    /// references in the same statement can be rewritten to `alias.`.
    var onCommitRename: ((_ from: String, _ to: String, _ insertedRange: NSRange) -> Void)?

    private var completionRange = NSRange(location: 0, length: 0)
    private var suppressNextUpdate = false

    /// Lazy so the class needs no custom initializer — that lets `init(frame:)` build
    /// the full text system (a nil text container leaves the view unclickable).
    private lazy var popup: CompletionPopup = {
        let popup = CompletionPopup()
        popup.onClickCommit = { [weak self] in self?.commitCompletion() }
        return popup
    }()

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
            case 48, 36: commitCompletion(); return             // Tab / Return
            case 53:  popup.hide(); return                      // Esc
            case 123, 124: popup.hide(); super.keyDown(with: event); return  // ← →
            default:  super.keyDown(with: event)                // typing → updateCompletion()
            }
        } else if event.keyCode == 53
                    || (event.keyCode == 49 && event.modifierFlags.contains(.control)) {
            // Force suggestions. Esc (with or without ⌥, Xcode-style) always works;
            // ⌃Space also does, but macOS binds it to the input-source switcher by
            // default, so it's often intercepted before the app sees it.
            updateCompletion(forced: true)
        } else {
            super.keyDown(with: event)
        }
    }

    // NSTextView re-registers drag types whenever it's reconfigured (editable state,
    // moving to a window, …), which would let a tab dropped on the editor paste its id
    // as text instead of splitting the pane. Keep them cleared at every such point.
    override func updateDragTypeRegistration() {
        unregisterDraggedTypes()
    }

    override func didChangeText() {
        super.didChangeText()
        updateCompletion()
    }

    override func mouseDown(with event: NSEvent) {
        onFocus?()
        popup.hide()
        super.mouseDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        popup.hide()
        return super.resignFirstResponder()
    }

    // MARK: Completion

    private func updateCompletion(forced: Bool = false) {
        if suppressNextUpdate { suppressNextUpdate = false; popup.hide(); return }
        guard let completionSource, selectedRange().length == 0, let window else { popup.hide(); return }
        let caret = selectedRange().location
        let (range, items) = completionSource(string, caret, forced)
        guard !items.isEmpty else { popup.hide(); return }
        completionRange = range
        // Anchor the popup just below the caret.
        let caretRect = firstRect(forCharacterRange: NSRange(location: caret, length: 0), actualRange: nil)
        let point = NSPoint(x: caretRect.minX, y: caretRect.minY - 3)
        popup.show(items: items, belowPoint: point, parent: window)
    }

    private func commitCompletion() {
        guard let item = popup.selectedItem else { popup.hide(); return }
        let insert = item.insert
        let range = completionRange.location + completionRange.length <= (string as NSString).length
            ? completionRange
            : NSRange(location: selectedRange().location, length: 0)
        popup.hide()
        suppressNextUpdate = true
        if shouldChangeText(in: range, replacementString: insert) {
            replaceCharacters(in: range, with: insert)
            didChangeText()
        }
        let insertedLength = (insert as NSString).length
        let end = range.location + insertedLength
        setSelectedRange(NSRange(location: max(range.location, end - item.caretOffset), length: 0))
        if let rename = item.renameQualifier {
            onCommitRename?(rename.from, rename.to, NSRange(location: range.location, length: insertedLength))
        }
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
