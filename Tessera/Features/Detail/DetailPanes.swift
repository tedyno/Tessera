import SwiftUI
import DBKit

/// The shared inputs a pane needs, bundled so the recursive tree doesn't thread a
/// dozen parameters through every split.
struct PaneEnv {
    var isReadOnly: Bool
    var connectionOptions: [ConnectionOption]
    var onSelectConnection: (UUID) -> Void
    var onRun: () -> Void
    var onExplain: (Bool) -> Void
    var onExportResult: (ResultExport.Format) -> Void
    var focusTrigger: Int
    var onNewConnection: () -> Void
    var showingHistory: Binding<Bool>
    var showingSaveQuery: Binding<Bool>
    var saveQueryTitle: Binding<String>
}

/// Renders one pane node: a leaf becomes a `PaneView`, a split becomes two child
/// trees with a draggable divider between them.
struct PaneTreeView: View {
    @Bindable var model: QueryConsoleModel
    var node: PaneNode
    var env: PaneEnv

    var body: some View {
        if let group = node.group {
            PaneView(model: model,
                     group: group,
                     isReadOnly: env.isReadOnly,
                     connectionOptions: env.connectionOptions,
                     onSelectConnection: env.onSelectConnection,
                     onRun: env.onRun,
                     onExplain: env.onExplain,
                     onExportResult: env.onExportResult,
                     focusTrigger: env.focusTrigger,
                     showingHistory: env.showingHistory,
                     showingSaveQuery: env.showingSaveQuery,
                     saveQueryTitle: env.saveQueryTitle,
                     canClosePane: model.workspace.groups.count > 1,
                     onNewConnection: env.onNewConnection)
        } else {
            SplitView(model: model, node: node, env: env)
        }
    }
}

/// A binary split (every split holds exactly two children) with one draggable
/// divider that rewrites the node's fractions.
private struct SplitView: View {
    @Bindable var model: QueryConsoleModel
    var node: PaneNode
    var env: PaneEnv

    private let thickness: CGFloat = 8
    private let minFraction: Double = 0.12

    private var space: String { "split-\(node.id.uuidString)" }

    var body: some View {
        GeometryReader { geo in
            let axis = node.axis ?? .horizontal
            let available = max((axis == .horizontal ? geo.size.width : geo.size.height) - thickness, 1)
            let f = min(max(node.fractions.first ?? 0.5, minFraction), 1 - minFraction)
            Group {
                if axis == .horizontal {
                    HStack(spacing: 0) {
                        child(0).frame(width: available * f).clipped()
                        divider(axis: axis, available: available)
                        child(1).frame(width: available * (1 - f)).clipped()
                    }
                } else {
                    VStack(spacing: 0) {
                        child(0).frame(height: available * f).clipped()
                        divider(axis: axis, available: available)
                        child(1).frame(height: available * (1 - f)).clipped()
                    }
                }
            }
            .coordinateSpace(name: space)
        }
    }

    @ViewBuilder private func child(_ index: Int) -> some View {
        if node.children.indices.contains(index) {
            PaneTreeView(model: model, node: node.children[index], env: env)
                .id(node.children[index].id)
        }
    }

    private func divider(axis: SplitAxis, available: CGFloat) -> some View {
        Rectangle()
            .fill(Color.primary.opacity(0.05))
            .frame(width: axis == .horizontal ? thickness : nil,
                   height: axis == .vertical ? thickness : nil)
            .overlay {
                Rectangle().fill(.separator)
                    .frame(width: axis == .horizontal ? 1 : nil,
                           height: axis == .vertical ? 1 : nil)
            }
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() }
                else { NSCursor.pop() }
            }
            .gesture(
                // Absolute pointer position in the split's own space — the divider
                // tracks the cursor directly, so a mid-drag relayout can't make the
                // fraction jump the way a cumulative-translation baseline did.
                DragGesture(minimumDistance: 1, coordinateSpace: .named(space))
                    .onChanged { value in
                        // Centre the divider under the cursor: `location` spans the
                        // full split (incl. the divider), `available` excludes the
                        // divider thickness — so offset by half to avoid a grab jump.
                        let position = (axis == .horizontal ? value.location.x : value.location.y) - thickness / 2
                        let next = min(max(position / available, minFraction), 1 - minFraction)
                        node.fractions = [next, 1 - next]
                    }
            )
    }
}
