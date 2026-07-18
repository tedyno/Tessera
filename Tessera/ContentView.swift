import SwiftUI

struct ContentView: View {
    @State private var connections = ConnectionsModel()
    @State private var console = QueryConsoleModel()
    @State private var selection: UUID?
    @State private var showingNewConnection = false
    @State private var newConnectionParent: UUID?
    private let sample = SampleData.demo

    var body: some View {
        NavigationSplitView {
            OrganizerSidebar(model: connections, selection: $selection) { parent in
                newConnectionParent = parent
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
            if selection == nil { selection = connections.firstConnectionNodeID }
        }
        .onChange(of: selection) { _, newValue in
            connect(nodeID: newValue)
        }
        .sheet(isPresented: $showingNewConnection) {
            NewConnectionView { profile, secrets in
                let nodeID = connections.addConnection(profile, secrets: secrets, into: newConnectionParent)
                selection = nodeID
            }
        }
    }

    private func connect(nodeID: UUID?) {
        guard let nodeID,
              let profileID = connections.profileID(forNode: nodeID),
              let profile = connections.profile(id: profileID) else { return }
        Task { await console.open(profile: profile, secrets: connections.secrets(for: profile)) }
    }
}
