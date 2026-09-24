import SwiftUI
import AppKit

/// macOS 27 chrome, with a pre-27 fallback beside it.
///
/// The app deploys back to macOS 26 (an unsigned open-source build can't assume
/// everyone has upgraded), so anything from the 27 SDK is reached through
/// `#available`. Keeping those branches here — rather than scattered through the
/// views — means one place to sweep when the deployment target eventually moves
/// up and the fallbacks can be deleted.
enum PlatformChrome {}

// MARK: - Pickers that switch what's on screen

/// A picker whose segments choose *what is shown* rather than a stored value:
/// macOS 27 renders it as a tab strip, older systems as the segmented control.
private struct ViewSwitcherPicker: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 27, *) {
            content.pickerStyle(.tabs)
        } else {
            content.pickerStyle(.segmented)
        }
    }
}

extension View {
    /// Use on a `Picker` that swaps the visible content (a mode toggle, a form
    /// branch) — not on one that picks a value to be saved.
    func viewSwitcherPickerStyle() -> some View { modifier(ViewSwitcherPicker()) }
}

// MARK: - Concentric corners for AppKit-hosted views

/// An `NSScrollView` that rounds itself concentrically with the container it
/// sits in, so a grid inside a card curves with the card rather than holding a
/// radius of its own.
///
/// `cornerConfiguration` is an override point, not a setting: the view declares
/// how it wants its corners resolved, the system works out the actual radii
/// from the container's shape, and hands them back through
/// `viewDidChangeEffectiveCornerRadii` — where drawing them is the view's job.
/// Before macOS 27 neither exists and this is a plain scroll view, clipped by
/// whatever SwiftUI wraps around it.
final class ConcentricScrollView: NSScrollView {
    /// Floor for the resolved radius, for the common case of a container that
    /// has no rounding to be concentric with.
    var minimumCornerRadius: CGFloat = 10 {
        didSet {
            guard #available(macOS 27, *), minimumCornerRadius != oldValue else { return }
            invalidateCornerConfiguration()
        }
    }

    @available(macOS 27, *)
    override var cornerConfiguration: NSViewCornerConfiguration? {
        .uniformCorners(radius: .containerConcentric(minimumCornerRadius))
    }

    @available(macOS 27, *)
    override func viewDidChangeEffectiveCornerRadii() {
        super.viewDidChangeEffectiveCornerRadii()
        guard let radii = effectiveCornerRadii else { return }
        wantsLayer = true
        layer?.cornerCurve = .continuous
        // `uniformCorners` resolves all four to the same value, so any corner
        // stands for the set.
        layer?.cornerRadius = radii.topLeft
        layer?.masksToBounds = true
    }
}

// MARK: - Pull to refresh

/// Hangs an `NSRefreshController` off a scroll view, so dragging the content
/// past its top edge re-runs whatever the pane last did. macOS 27 only; before
/// that the toolbar's Refresh button is the only way in, which is exactly how
/// the app behaved until now.
@MainActor
final class PullToRefresh: NSObject {
    private let action: () -> Void
    private var controller: AnyObject?

    init(action: @escaping () -> Void) {
        self.action = action
        super.init()
    }

    /// Attaches to `scrollView`, replacing any controller set earlier.
    func attach(to scrollView: NSScrollView, title: String) {
        guard #available(macOS 27, *) else { return }
        let controller = NSRefreshController()
        controller.target = self
        controller.action = #selector(refreshTriggered)
        controller.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.preferredFont(forTextStyle: .caption1),
                         .foregroundColor: NSColor.secondaryLabelColor])
        scrollView.refreshController = controller
        self.controller = controller
    }

    @objc private func refreshTriggered() {
        action()
        // Acknowledge the pull and stop, rather than holding the spinner until
        // the query finishes. A run can be refused outright, or park on a
        // parameter prompt or a destructive-SQL confirmation — and a spinner
        // tied to that would sit there until the sheet was answered, or for
        // good. Query progress already has the toolbar spinner and the results
        // area's "Loading…"; this control only has to say the pull registered.
        guard #available(macOS 27, *),
              let controller = controller as? NSRefreshController else { return }
        controller.endRefreshing()
    }
}

// MARK: - Menu item images

extension NSMenuItem {
    /// Pins this item's image on screen.
    ///
    /// From macOS 27 AppKit decides for itself whether a menu item's image is
    /// drawn, and typically hides it. That's right for decoration, but wrong
    /// where the image *is* the information — a colour swatch next to a colour
    /// name, a warning badge on a notice — because hiding it doesn't tidy the
    /// menu, it removes the point of the item.
    func keepImageVisible() {
        guard #available(macOS 27, *) else { return }
        preferredImageVisibility = .visible
    }
}
