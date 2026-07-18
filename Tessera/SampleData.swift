import Foundation
import DBKit
import DBPersistence

/// Static sample data for the UI skeleton (Phase 0). Replaced by live data from
/// `OrganizerStore`/`ProfileStore` and real connections in Phase 2+.
enum SampleData {
    struct Demo {
        let organizer: OrganizerDocument
        let profiles: [UUID: ConnectionProfile]
        let schema: DatabaseTree
    }

    static let demo: Demo = {
        let pg = ConnectionProfile(
            name: "production-pg", kind: .postgres,
            host: "db.internal.example.com", database: "shop_production",
            username: "app_readonly", tlsMode: .verifyFull
        )
        let mysql = ConnectionProfile(
            name: "analytics-mysql", kind: .mysql,
            host: "analytics.example.com", database: "analytics", username: "reader"
        )
        let replica = ConnectionProfile(
            name: "replica-pg", kind: .postgres,
            host: "replica.example.com", database: "shop_production", username: "app_readonly"
        )
        let profiles: [UUID: ConnectionProfile] = [
            pg.id: pg, mysql.id: mysql, replica.id: replica,
        ]

        let production = Folder(name: "Production", children: [
            .connection(ConnectionRef(profileID: pg.id)),
            .connection(ConnectionRef(profileID: mysql.id)),
            .connection(ConnectionRef(profileID: replica.id)),
        ])
        let staging = Folder(name: "Staging")
        let shop = Project(name: "E-commerce", children: [.folder(production), .folder(staging)])
        let internalTools = Project(name: "Internal Tools")
        let workspace = Workspace(name: "Acme", children: [.project(shop), .project(internalTools)])

        let schema = DatabaseTree(databaseName: "shop_production", schemas: [
            SchemaNamespace(name: "public", tables: [
                SchemaTable(name: "orders", kind: .table, columns: [
                    SchemaColumn(name: "id", dataType: "int8", isPrimaryKey: true, isNullable: false),
                    SchemaColumn(name: "customer_id", dataType: "int8", isNullable: false),
                    SchemaColumn(name: "total", dataType: "numeric"),
                    SchemaColumn(name: "status", dataType: "text"),
                    SchemaColumn(name: "created_at", dataType: "timestamptz"),
                ]),
                SchemaTable(name: "customers", kind: .table),
                SchemaTable(name: "order_items", kind: .table),
                SchemaTable(name: "products", kind: .table),
                SchemaTable(name: "v_monthly_sales", kind: .view),
            ]),
            SchemaNamespace(name: "audit"),
        ])

        return Demo(
            organizer: OrganizerDocument(workspaces: [workspace]),
            profiles: profiles,
            schema: schema
        )
    }()
}
