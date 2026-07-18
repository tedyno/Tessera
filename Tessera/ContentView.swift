import SwiftUI

struct ContentView: View {
    @State private var selection: UUID?
    @State private var console = QueryConsoleModel()
    private let sample = SampleData.demo

    var body: some View {
        NavigationSplitView {
            OrganizerSidebar(
                document: sample.organizer,
                profiles: sample.profiles,
                selection: $selection
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 320)
        } content: {
            SchemaSidebar(tree: sample.schema)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            DetailView(model: console)
                .navigationSplitViewColumnWidth(min: 480, ideal: 760)
        }
        .task { await console.connectIfNeeded() }
    }
}

#Preview {
    ContentView()
}
