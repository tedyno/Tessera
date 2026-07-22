import SwiftUI
import AppKit

/// The window-wide colour backdrop the Liquid Glass chrome floats on: a
/// behind-window frosted layer (whatever windows/wallpaper sit behind the
/// app, blurred) tinted by a rich mesh gradient — deep blues and purples in
/// dark mode, airy blue-pink in light. The gradient keeps the design's hue;
/// the blur underneath lets the surroundings glow through it.
struct TesseraBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            BehindWindowBlur()
            Self.gradient(for: colorScheme)
                .opacity(0.8)
        }
        .ignoresSafeArea()
    }

    /// The bare gradient, reusable where the environment can't supply the
    /// scheme (offscreen export rendering).
    static func gradient(for scheme: ColorScheme) -> some View {
        MeshGradient(
            width: 3, height: 3,
            points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.55, 0.45], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1],
            ],
            colors: scheme == .dark ? dark : light)
    }

    // Deliberately narrow palettes — the backdrop should read as one deep
    // colour with a faint drift of hue, not a rainbow.
    private static let dark: [Color] = [
        Color(red: 0.08, green: 0.11, blue: 0.26),  // hint of royal blue
        Color(red: 0.06, green: 0.07, blue: 0.19),
        Color(red: 0.12, green: 0.08, blue: 0.24),  // hint of purple
        Color(red: 0.05, green: 0.07, blue: 0.19),
        Color(red: 0.05, green: 0.06, blue: 0.15),  // navy centre
        Color(red: 0.09, green: 0.07, blue: 0.20),
        Color(red: 0.05, green: 0.08, blue: 0.20),
        Color(red: 0.05, green: 0.08, blue: 0.21),
        Color(red: 0.07, green: 0.10, blue: 0.26),  // soft blue glow
    ]

    private static let light: [Color] = [
        Color(red: 0.86, green: 0.90, blue: 0.99),  // pale blue
        Color(red: 0.91, green: 0.93, blue: 0.99),
        Color(red: 0.96, green: 0.89, blue: 0.95),  // pale rose
        Color(red: 0.89, green: 0.93, blue: 0.99),
        Color(red: 0.94, green: 0.96, blue: 1.00),  // airy centre
        Color(red: 0.95, green: 0.92, blue: 0.97),
        Color(red: 0.87, green: 0.93, blue: 0.98),
        Color(red: 0.91, green: 0.95, blue: 0.99),
        Color(red: 0.89, green: 0.94, blue: 0.99),  // pale cyan
    ]
}

/// Frosts whatever sits behind the window — other windows and the wallpaper.
private struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// A floating rounded card over the backdrop — the sidebar panels (and later
/// sheets) share this chrome: frosted fill, hairline edge, soft drop shadow.
struct FloatingPanel: ViewModifier {
    var cornerRadius: CGFloat = 16
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .scrollContentBackground(.hidden)
            .clipShape(shape)
            // Real Liquid Glass, not a material: frosted, but the backdrop's
            // hue keeps glowing through. A whisper of tint keeps text legible
            // over the vivid gradient.
            .glassEffect(.regular.tint(colorScheme == .dark ? Color.black.opacity(0.25)
                                                            : Color.white.opacity(0.30)),
                         in: shape)
            .shadow(color: .black.opacity(0.22), radius: 16, y: 6)
    }
}

extension View {
    func floatingPanel(cornerRadius: CGFloat = 16) -> some View {
        modifier(FloatingPanel(cornerRadius: cornerRadius))
    }
}

/// Capsule chrome for toolbar buttons over the gradient backdrop — the
/// mockups' pill look. `prominent` fills with the accent colour (the primary
/// action of a toolbar); the rest stay translucent.
struct GlassPillButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(prominent ? AnyShapeStyle(Color.accentColor)
                                  : AnyShapeStyle(.primary.opacity(0.06)),
                        in: Capsule())
            .overlay(Capsule().strokeBorder(.primary.opacity(prominent ? 0 : 0.12)))
            .opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == GlassPillButtonStyle {
    static var glassPill: GlassPillButtonStyle { GlassPillButtonStyle() }
    static var glassPillProminent: GlassPillButtonStyle { GlassPillButtonStyle(prominent: true) }
}

/// The same capsule chrome for `Menu` labels, which take no `ButtonStyle`.
struct PillChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.primary.opacity(0.06), in: Capsule())
            .overlay(Capsule().strokeBorder(.primary.opacity(0.12)))
    }
}

extension View {
    func pillChrome() -> some View { modifier(PillChrome()) }
}

/// Renders an ERD canvas onto the app's gradient backdrop, so an exported PNG
/// looks exactly like the diagram on screen.
@MainActor
enum DiagramExportRenderer {
    static func png(canvas: DiagramCanvasView, colorScheme: ColorScheme) -> Data? {
        let rect = canvas.contentRect
        guard rect.width > 0, rect.height > 0,
              let content = canvas.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        canvas.cacheDisplay(in: rect, to: content)

        let scale = canvas.window?.backingScaleFactor ?? 2
        // Screenshot-true backdrop: the mesh is rendered at the window's size,
        // then aspect-filled (cropped, never squeezed) behind the content —
        // rendering it at the export's own size would compress the colour
        // flow, making the hues shift much faster than they do on screen.
        let reference = canvas.window?.contentView?.bounds.size
            ?? NSSize(width: 1240, height: 760)
        let fill = max(rect.width / max(reference.width, 1),
                       rect.height / max(reference.height, 1), 1)
        let backdropSize = NSSize(width: reference.width * fill,
                                  height: reference.height * fill)
        let renderer = ImageRenderer(content: TesseraBackdrop.gradient(for: colorScheme)
            .frame(width: backdropSize.width, height: backdropSize.height))
        renderer.scale = scale
        guard let backdrop = renderer.nsImage else { return nil }

        guard let composed = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: content.pixelsWide, pixelsHigh: content.pixelsHigh,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        composed.size = rect.size

        let contentImage = NSImage(size: rect.size)
        contentImage.addRepresentation(content)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: composed)
        backdrop.draw(in: NSRect(x: (rect.width - backdropSize.width) / 2,
                                 y: (rect.height - backdropSize.height) / 2,
                                 width: backdropSize.width,
                                 height: backdropSize.height))
        contentImage.draw(in: NSRect(origin: .zero, size: rect.size))
        NSGraphicsContext.restoreGraphicsState()

        return composed.representation(using: .png, properties: [:])
    }
}
