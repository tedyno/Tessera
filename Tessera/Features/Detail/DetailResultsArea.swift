import SwiftUI
import DBKit

/// The results region below the toolbar: an error/success banner, the results
/// grid (optionally wrapped in the EXPLAIN plan view), the ⌘F find bar, and the
/// empty state.
struct DetailResultsArea: View {
    @Bindable var model: QueryConsoleModel
    /// Grid row density; shared via `tessera.gridDensity` with the status bar and
    /// the Appearance settings tab.
    @AppStorage("tessera.gridDensity") private var gridComfortable = false
    @FocusState private var searchFieldFocused: Bool

    var body: some View {
        if let tab = model.activeTab, tab.result != nil || tab.errorMessage != nil {
            // Error (red) and success (green) share the same banner at the top; a
            // row-returning result shows its grid below, keeping any prior grid on error.
            VStack(spacing: 0) {
                if let message = tab.errorMessage {
                    feedbackBanner(message, isError: true)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    Divider()
                } else if let result = tab.result, result.columns.isEmpty {
                    feedbackBanner(successText(tab, result), isError: false)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    Divider()
                }
                if let result = tab.result, !result.columns.isEmpty {
                    if tab.currentPlan != nil, let session = tab.session {
                        PlanResultView(tab: tab, engine: session.engine) {
                            resultsGrid(tab, result: result)
                        }
                        // Tie the parse cache to the tab — two tabs at the same
                        // resultVersion must not share a cached plan.
                        .id(tab.id)
                    } else {
                        resultsGrid(tab, result: result)
                    }
                } else {
                    Spacer(minLength: 0)
                }
            }
            .animation(.snappy(duration: 0.2), value: tab.errorMessage != nil)
        } else if model.activeTab?.isRunning == true {
            // A first run (opening a table, or Run with no prior result) is in
            // flight — show progress rather than the "No results" empty state,
            // which reads as "this query returned nothing".
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading…").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("No results", systemImage: "tablecells",
                                   description: Text("Press Run to execute the query."))
        }
    }

    private func resultsGrid(_ tab: QueryTab, result: QueryResult) -> some View {
        ResultsTableView(
            tab: tab,
            onSort: { column in
                Task { await model.sortByColumn(tab, column: column) }
            },
            onFollowForeignKey: { target, clause in
                Task {
                    await model.openReferencedTable(schema: target.schema,
                                                    table: target.table,
                                                    where: clause)
                }
            },
            onDiscardPending: { model.discardPending(tab) },
            rowHeight: gridComfortable ? 24 : 18)
        .overlay(alignment: .topTrailing) {
            if tab.isSearchBarVisible {
                findBar(tab, result: result)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.2), value: tab.isSearchBarVisible)
    }

    /// ⌘F find bar: filters the grid to rows containing the text, client-side, without
    /// re-running the query. Escape clears the filter and hides the bar again.
    private func findBar(_ tab: QueryTab, result: QueryResult) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in results", text: Binding(
                get: { tab.searchQuery },
                set: { tab.searchQuery = $0 }
            ))
            .textFieldStyle(.plain)
            .focused($searchFieldFocused)
            .frame(width: 160)
            if !tab.searchQuery.isEmpty {
                Text("\(tab.matchingRowIndices()?.count ?? 0) of \(result.rows.count) rows")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            Button {
                tab.clearSearch()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .onExitCommand { tab.clearSearch() }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
        .shadow(radius: 3, y: 1)
        .padding(8)
        .onAppear { searchFieldFocused = true }
    }

    private func successText(_ tab: QueryTab, _ result: QueryResult) -> String {
        var parts = [String(localized: "Query executed")]
        if let affected = result.rowsAffected {
            parts.append("\(affected) " + (affected == 1 ? String(localized: "row affected")
                                                         : String(localized: "rows affected")))
        }
        if let ms = tab.elapsedMS { parts.append("\(ms) ms") }
        return parts.joined(separator: " · ")
    }

    /// Result feedback banner: red for an error, green for a successful command.
    private func feedbackBanner(_ message: String, isError: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? .red : .green)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(message)
                    .font(isError ? .callout.monospaced() : .callout)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((isError ? Color.red : Color.green).opacity(0.12))
    }
}
