import SwiftUI
import AppKit

/// Transparent overlay that reports middle-mouse clicks (SwiftUI has no gesture for
/// them). It only claims middle-click events; left/right clicks fall through to the
/// view below, so it can sit over an interactive control without blocking it.
struct MiddleClickCatcher: NSViewRepresentable {
    var onMiddleClick: () -> Void

    func makeNSView(context: Context) -> NSView { CatcherView(onMiddleClick: onMiddleClick) }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CatcherView)?.onMiddleClick = onMiddleClick
    }

    final class CatcherView: NSView {
        var onMiddleClick: () -> Void

        init(onMiddleClick: @escaping () -> Void) {
            self.onMiddleClick = onMiddleClick
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func otherMouseUp(with event: NSEvent) {
            if event.buttonNumber == 2 { onMiddleClick() } else { super.otherMouseUp(with: event) }
        }

        // Only intercept the middle button; everything else passes through untouched.
        override func hitTest(_ point: NSPoint) -> NSView? {
            NSApp.currentEvent?.type == .otherMouseUp || NSApp.currentEvent?.type == .otherMouseDown
                ? super.hitTest(point) : nil
        }
    }
}
