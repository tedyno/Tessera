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
