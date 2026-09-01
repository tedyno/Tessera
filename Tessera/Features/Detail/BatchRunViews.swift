import DBKit
import SwiftUI

/// Confirmation before ⌘↩ runs a whole selection.
///
/// A sheet rather than a `confirmationDialog` for two reasons: the list of statements
/// has to be readable before agreeing to it, and SwiftUI's dialogs cannot carry the
/// "Don't ask again" checkbox.
struct BatchRunConfirmSheet: View {
    let pending: AppModel.PendingBatch
    let onRun: () -> Void
    let onCancel: () -> Void

    /// Mirrors the stored setting; written back only when the user actually runs, so
    /// ticking the box and then cancelling changes nothing.
    @State private var askAgain = true

    private var isDestructive: Bool { !pending.warnings.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("^[Run \(pending.steps.count) statement](inflect: true)?")
                .font(.headline)

            if isDestructive {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(pending.warnings) { warning in
                        Label(warning.risk.explanation, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.callout)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(pending.steps) { step in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(verbatim: "\(step.number)")
                                .foregroundStyle(.secondary)
                                .frame(width: 20, alignment: .trailing)
                            Text(verbatim: step.label)
                                .textSelection(.enabled)
                        }
                        .font(.system(.callout, design: .monospaced))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(height: 160)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 6))

            Text("They run in order and stop at the first error.")
                .font(.caption).foregroundStyle(.secondary)

            // Silencing a routine reminder is reasonable; silencing a destructive
            // warning is not, so the box is not offered when one is showing.
            if !isDestructive {
                Toggle("Don't ask again", isOn: Binding(get: { !askAgain },
                                                        set: { askAgain = !$0 }))
                    .toggleStyle(.checkbox)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(isDestructive ? "Run Anyway" : "Run", role: isDestructive ? .destructive : nil) {
                    if !askAgain { BatchRunSettings.confirms = false }
                    onRun()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// The list of statements a selection run produced, above the result grid. Clicking
/// a finished step puts its result back on the grid.
struct BatchStepList: View {
    let steps: [SQLBatchStep]
    let selection: Int?
    let onSelect: (Int) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(steps) { step in
                    row(step)
                }
            }
        }
        .frame(maxHeight: 120)
    }

    private func row(_ step: SQLBatchStep) -> some View {
        HStack(spacing: 8) {
            icon(step)
                .frame(width: 14)
            Text(verbatim: "\(step.number)")
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .trailing)
            Text(verbatim: step.label)
                .lineLimit(1)
            Spacer(minLength: 12)
            Text(outcome(step))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .font(.system(.callout, design: .monospaced))
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .contentShape(.rect)
        .background(step.number == selection ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear))
        // Only a step that actually ran has anything to show.
        .onTapGesture { if step.didRun { onSelect(step.number) } }
        .opacity(step.didRun ? 1 : 0.5)
    }

    @ViewBuilder
    private func icon(_ step: SQLBatchStep) -> some View {
        switch step.outcome {
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .pending: Image(systemName: "circle.dotted").foregroundStyle(.secondary)
        default: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }

    private func outcome(_ step: SQLBatchStep) -> LocalizedStringKey {
        switch step.outcome {
        case .pending: "not run"
        case .ok: "done"
        case .rows(let count): "^[\(count) row](inflect: true)"
        case .affected(let count): "^[\(count) row](inflect: true) affected"
        case .failed: "failed"
        }
    }
}

extension View {
    /// Attaches the multi-statement confirmation. A modifier rather than an inline
    /// `.sheet`: ContentView's chain is already at the limit of what the type checker
    /// will work through, and one more closure there tips it over.
    func batchRunConfirm(_ app: AppModel) -> some View {
        modifier(BatchRunConfirmModifier(app: app))
    }
}

private struct BatchRunConfirmModifier: ViewModifier {
    @Bindable var app: AppModel

    func body(content: Content) -> some View {
        content.sheet(isPresented: $app.showingBatchConfirm) {
            if let pending = app.pendingBatch {
                BatchRunConfirmSheet(pending: pending, onRun: run, onCancel: cancel)
                    .tesseraModalBackground()
            }
        }
    }

    private func run() {
        app.showingBatchConfirm = false
        app.confirmBatchRun()
    }

    private func cancel() {
        app.showingBatchConfirm = false
        app.cancelBatchRun()
    }
}
