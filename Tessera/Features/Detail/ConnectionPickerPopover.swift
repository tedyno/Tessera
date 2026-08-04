import SwiftUI

/// A searchable connection picker (the tab toolbar's combobox). Type to filter;
/// results are ranked by proximity to the tab's current connection in the organizer
/// — same folder first, then same project, then same workspace, then the rest —
/// with the breadcrumb shown so same-named connections are distinguishable.
struct ConnectionPickerPopover: View {
    let options: [ConnectionOption]
    let currentID: UUID?
    @Binding var isPresented: Bool
    let onSelect: (UUID) -> Void

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    /// The organizer path of the tab's current connection, to rank the rest against.
    private var currentPath: [String] {
        options.first { $0.id == currentID }?.path ?? []
    }

    private var results: [ConnectionOption] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = needle.isEmpty ? options : options.filter {
            $0.name.lowercased().contains(needle)
                || $0.path.joined(separator: "/").lowercased().contains(needle)
        }
        return filtered.sorted { a, b in
            // Deeper shared organizer ancestry ranks first; ties by name.
            let sa = Self.commonPrefix(a.path, currentPath)
            let sb = Self.commonPrefix(b.path, currentPath)
            if sa != sb { return sa > sb }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search connections…", text: $query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { selectCurrent() }
                    .onChange(of: query) { _, _ in selection = 0 }
            }
            .padding(10)
            Divider()
            list
        }
        .frame(width: 320, height: 320)
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.escape) { isPresented = false; return .handled }
        .onAppear { focused = true }
        .tesseraModalBackground()   // the app's themed backdrop, not the flat popover material
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if results.isEmpty {
                        Text("No connections")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                    }
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, option in
                        row(option, selected: index == selection)
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture { choose(option) }
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollContentBackground(.hidden)
            // SwiftUI's ScrollView draws an opaque NSScrollView background (and a
            // solid scroller track) over the themed backdrop — clear it at the AppKit
            // layer so the gradient shows through.
            .background(TransparentScrollBackground())
            .onChange(of: selection) { _, new in
                withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }

    private func row(_ option: ConnectionOption, selected: Bool) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "cylinder.split.1x2")
                .frame(width: 16)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(option.name)
                if !option.path.isEmpty {
                    Text(option.path.joined(separator: " › "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if option.id == currentID {
                Image(systemName: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(selected ? Color.accentColor.opacity(0.18) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 6)
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = min(max(selection + delta, 0), results.count - 1)
    }

    private func selectCurrent() {
        guard results.indices.contains(selection) else { return }
        choose(results[selection])
    }

    private func choose(_ option: ConnectionOption) {
        isPresented = false
        onSelect(option.id)
    }

    /// Number of leading path components two connections share (deeper = closer).
    private static func commonPrefix(_ a: [String], _ b: [String]) -> Int {
        zip(a, b).prefix { $0 == $1 }.count
    }
}

/// Clears the background of every `NSScrollView` in the popover's window and hides
/// the scroller's opaque track, so the themed backdrop shows through instead of a
/// flat black strip behind the scrollbar. Retries a few times because the scroll
/// view may not be in the window hierarchy yet when the popover first appears.
private struct TransparentScrollBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        Self.clear(from: view, attemptsLeft: 8)
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private static func clear(from view: NSView, attemptsLeft: Int) {
        DispatchQueue.main.async { [weak view] in
            guard let view else { return }
            if let root = view.window?.contentView, apply(in: root) { return }
            if attemptsLeft > 0 { clear(from: view, attemptsLeft: attemptsLeft - 1) }
        }
    }

    /// Transparent-izes any scroll views under `root`; returns true once it finds one.
    @discardableResult
    private static func apply(in root: NSView) -> Bool {
        var found = false
        if let scroll = root as? NSScrollView {
            scroll.drawsBackground = false
            scroll.backgroundColor = .clear
            scroll.contentView.drawsBackground = false
            // Overlay scrollers float over the content — no reserved, opaque track.
            scroll.scrollerStyle = .overlay
            found = true
        }
        for subview in root.subviews where apply(in: subview) { found = true }
        return found
    }
}
