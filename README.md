# Tessera

A fast, native database client for macOS. No Electron, no webview, no JavaScript —
pure SwiftUI. Built for PostgreSQL and MySQL, with secure credential storage and SSH
tunneling.

> ⚠️ **Early stage.** Currently the UI skeleton and domain core (Phase 0). Database
> connectivity is still being implemented.

## Goals

- **Native and fast** — SwiftUI, no webview. Looks and behaves like a macOS app.
- **PostgreSQL and MySQL** — a unified core, easy to extend to more engines.
- **Secure** — passwords and SSH keys live in the system Keychain, never in plain text on disk.
- **SSH tunneling** — reach databases behind a bastion (local port forwarding).
- **Connection organization** — a Workspace → Project → Folder → Connection tree.
- **Localized** — English base language, structured for additional languages via a String Catalog.

## MVP status

- [x] Domain core (models, protocols, organizer/profile persistence)
- [x] Three-column window (organizer · schema · editor + results)
- [x] PostgreSQL connections and query execution
- [x] Secure credential storage in the Keychain
- [x] Schema browser (Database → Schema → Table → Column), double-click a table to `SELECT *`
- [x] MySQL connections
- [x] SSH tunnel — password auth (private-key auth is not implemented yet)
- [x] Connection organizer tree (Workspace → Project → Folder → Connection) with drag & drop
- [x] Query tabs and searchable history
- [x] SQL syntax highlighting and query cancellation
- [x] Virtualized results grid for large result sets

## Tech stack

- **Language / UI:** Swift 6, SwiftUI (macOS 26+)
- **Postgres / MySQL:** PostgresNIO / MySQLNIO
- **SSH:** Citadel (swift-nio-ssh)
- **Credentials:** macOS Keychain (Security.framework)

## Layout

```
Tessera.xcodeproj      # macOS app target (SwiftUI)
Tessera/               # app sources (UI layer)
TesseraCore/           # local Swift Package — portable core (no SwiftUI)
  Sources/DBKit/         # models + protocols (no networking dependencies)
  Sources/DBPersistence/ # organizer and profile persistence (JSON)
```

The core (`TesseraCore`) deliberately knows nothing about SwiftUI or specific database
drivers — it communicates through protocols. The UI layer builds on top of it.

## Build and run

Requires **Xcode 26+** and **macOS 26+**.

```sh
# App
open Tessera.xcodeproj      # then ⌘R in Xcode

# Core only (tests)
cd TesseraCore && swift test
```

### Running a downloaded build

The app is not signed or notarized (open source, outside the App Store). On first launch
of a downloaded build, macOS Gatekeeper will block it — open it via **right-click → Open**,
or strip the quarantine attribute:

```sh
xattr -dr com.apple.quarantine Tessera.app
```

The cleanest path is to build from source (see above) — then Gatekeeper is a non-issue.

## License

To be added.
