import XCTest
@testable import DBPersistence

final class OrganizerMutationsTests: XCTestCase {

    private func makeDoc() -> (OrganizerDocument, workspaceID: UUID, folderID: UUID) {
        let folder = Folder(name: "Production")
        let project = Project(name: "E-commerce", children: [.folder(folder)])
        let workspace = Workspace(name: "Acme", children: [.project(project)])
        return (OrganizerDocument(workspaces: [workspace]), workspace.id, folder.id)
    }

    func testAppendAndLookup() {
        var (doc, _, folderID) = makeDoc()
        let ref = ConnectionRef(profileID: UUID())
        XCTAssertTrue(doc.append(.connection(ref), toParent: folderID))
        XCTAssertNotNil(doc.node(id: ref.id))
        XCTAssertEqual(doc.profileID(forNode: ref.id), ref.profileID)
    }

    func testInsertIntoWorkspaceRoot() {
        var (doc, workspaceID, _) = makeDoc()
        let folder = Folder(name: "Staging")
        XCTAssertTrue(doc.append(.folder(folder), toParent: workspaceID))
        XCTAssertNotNil(doc.node(id: folder.id))
    }

    func testRename() {
        var (doc, _, folderID) = makeDoc()
        doc.rename(folderID, to: "Prod")
        XCTAssertEqual(doc.node(id: folderID)?.displayName, "Prod")
    }

    func testRemove() {
        var (doc, _, folderID) = makeDoc()
        let removed = doc.remove(folderID)
        XCTAssertEqual(removed?.id, folderID)
        XCTAssertNil(doc.node(id: folderID))
    }

    func testRefsToProfile() {
        var (doc, workspaceID, folderID) = makeDoc()
        let profileID = UUID()
        doc.append(.connection(ConnectionRef(profileID: profileID)), toParent: folderID)
        doc.append(.connection(ConnectionRef(profileID: profileID)), toParent: workspaceID)
        XCTAssertEqual(doc.refs(toProfile: profileID).count, 2)
    }

    func testMovePreservesNode() {
        var (doc, workspaceID, folderID) = makeDoc()
        let ref = ConnectionRef(profileID: UUID())
        doc.append(.connection(ref), toParent: folderID)
        // Move: remove then re-insert under workspace root.
        let node = doc.remove(ref.id)
        XCTAssertNotNil(node)
        XCTAssertTrue(doc.append(node!, toParent: workspaceID))
        XCTAssertNotNil(doc.node(id: ref.id))
    }
}

// MARK: Connections without a workspace

final class LooseConnectionTests: XCTestCase {

    func testDocumentWithoutLooseKeyDecodes() throws {
        // organizer.json written by older builds has no `looseConnections`.
        let json = #"{"workspaces":[{"id":"\#(UUID().uuidString)","name":"W","children":[]}]}"#
        let document = try JSONDecoder().decode(OrganizerDocument.self, from: Data(json.utf8))
        XCTAssertTrue(document.looseConnections.isEmpty)
        XCTAssertEqual(document.workspaces.count, 1)
    }

    func testConnectionCanLiveOutsideAnyWorkspace() {
        var document = OrganizerDocument(workspaces: [Workspace(name: "W")])
        let profileID = UUID()
        let ref = ConnectionRef(profileID: profileID)
        XCTAssertTrue(document.insert(.connection(ref), toParent: OrganizerDocument.looseParentID, at: nil))

        XCTAssertEqual(document.looseConnections.count, 1)
        XCTAssertNotNil(document.node(id: ref.id))
        XCTAssertEqual(document.profileID(forNode: ref.id), profileID)
        XCTAssertEqual(document.refs(toProfile: profileID).count, 1)
        XCTAssertEqual(document.location(of: ref.id)?.parent, OrganizerDocument.looseParentID)
    }

    func testFoldersAreRejectedAtTheLooseLevel() {
        var document = OrganizerDocument()
        XCTAssertFalse(document.insert(.folder(Folder(name: "F")),
                                       toParent: OrganizerDocument.looseParentID, at: nil))
        XCTAssertTrue(document.looseConnections.isEmpty)
    }

    func testLooseConnectionMovesIntoWorkspaceAndBack() {
        let workspace = Workspace(name: "W")
        var document = OrganizerDocument(workspaces: [workspace])
        let ref = ConnectionRef(profileID: UUID())
        document.insert(.connection(ref), toParent: OrganizerDocument.looseParentID, at: nil)

        guard let removed = document.remove(ref.id) else { return XCTFail("not removed") }
        XCTAssertTrue(document.looseConnections.isEmpty)
        XCTAssertTrue(document.insert(removed, toParent: workspace.id, at: nil))
        XCTAssertEqual(document.location(of: ref.id)?.parent, workspace.id)

        guard let back = document.remove(ref.id) else { return XCTFail("not removed") }
        document.insert(back, toParent: OrganizerDocument.looseParentID, at: nil)
        XCTAssertEqual(document.looseConnections.count, 1)
    }
}

// MARK: Deleting the last workspace

final class LastWorkspaceDeletionTests: XCTestCase {

    /// Keeping the contents of the only workspace is impossible — there is nowhere to
    /// move them — so the caller must not be able to drop them without cleanup.
    func testRemovingTheOnlyWorkspaceWithNoTargetKeepsNothingBehind() {
        var document = OrganizerDocument(workspaces: [Workspace(name: "Only")])
        let ref = ConnectionRef(profileID: UUID())
        document.insert(.connection(ref), toParent: document.workspaces[0].id, at: nil)
        let workspaceID = document.workspaces[0].id

        // What the model must clean up is discoverable before the removal…
        XCTAssertEqual(document.profileIDs(inSubtreeOf: workspaceID), [ref.profileID])
        document.removeWorkspace(workspaceID, movingChildrenInto: nil)

        XCTAssertTrue(document.workspaces.isEmpty)
        XCTAssertNil(document.node(id: ref.id))
    }

    func testRemovingAWorkspaceMovesChildrenIntoTheTarget() {
        let keep = Workspace(name: "Keep")
        var document = OrganizerDocument(workspaces: [Workspace(name: "Going"), keep])
        let ref = ConnectionRef(profileID: UUID())
        document.insert(.connection(ref), toParent: document.workspaces[0].id, at: nil)

        document.removeWorkspace(document.workspaces[0].id, movingChildrenInto: keep.id)
        XCTAssertEqual(document.workspaces.count, 1)
        XCTAssertEqual(document.location(of: ref.id)?.parent, keep.id)
    }
}
