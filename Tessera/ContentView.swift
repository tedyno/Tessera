import SwiftUI

struct ContentView: View {
    @State private var connections = ConnectionsModel()
    @State private var console = QueryConsoleModel()
    @State private var selection: UUID?
    @State private var showingNewConnection = false
    private let sample = SampleData.demo

    var body: some View {
        NavigationSplitView {
            OrganizerSidebar(connections: connections, selection: $selection) {
                showingNewConnection = true
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 320)
        } content: {
            SchemaSidebar(tree: sample.schema)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            DetailView(model: console)
                .navigationSplitViewColumnWidth(min: 480, ideal: 760)
        }
        .task {
            if selection == nil, let first = connections.profiles.first {
                selection = first.id
                await console.open(profile: first, secrets: connections.secrets(for: first))
            }
        }
        .onChange(of: selection) { _, newValue in
            guard let id = newValue, let profile = connections.profile(id: id) else { return }
            Task { await console.open(profile: profile, secrets: connections.secrets(for: profile)) }
        }
        .sheet(isPresented: $showingNewConnection) {
            NewConnectionView { profile, secrets in
                connections.add(profile, secrets: secrets)
                selection = profile.id
            }
        }
    }
}
