# Tessera

[![CI](https://github.com/tedyno/Tessera/actions/workflows/ci.yml/badge.svg)](https://github.com/tedyno/Tessera/actions/workflows/ci.yml)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
![Platform: macOS 26+](https://img.shields.io/badge/platform-macOS%2026%2B-lightgrey)

A fast, native database client for macOS. No Electron, no webview, no JavaScript —
pure Swift and SwiftUI. Built for PostgreSQL, MySQL, MariaDB and SQLite, with secure
credential storage and SSH tunnelling.

The name is the Latin word for a single tile of a mosaic: one cell of a data grid, from
which the whole picture is assembled.

> **Status:** under active development and usable day to day, but expect rough edges.

## Features

- **PostgreSQL, MySQL, MariaDB and SQLite** through one interface, with several connections
  live at once — staging and production side by side. Each tab is bound to its own session,
  labelled with its connection and a live status dot, and a per-tab picker points it at any
  connection. SQLite needs no server at all: point a connection at a file (or a new path —
  the file is created on first connect).
- **Split-pane tiling** — drag a tab onto a pane's edge to split the workspace four ways,
  drop it on another pane's tab bar to move it there, drag the dividers to resize, and close
  a whole pane with its tabs. Tabs reorder within a pane by drag. The whole layout persists
  across launches.
- **Window themes** — choose a backdrop from a grid of live gradient swatches (the Monokai
  Pro filters plus Catppuccin, Tokyo Night, Dracula, Nord, Gruvbox, Rosé Pine, One Dark) and
  a light / dark / system appearance. The whole app follows the theme — sheets, sidebar,
  results header — and the Dock icon changes with it.
- **Connection organizer** — nest connections in folders, colour-code them, mark the
  dangerous ones read-only, and connect / disconnect / reconnect / re-introspect from the
  sidebar (with a live green status dot).
- **Schema browser** and a **global search** (double-Shift) across every connection's
  schemas, tables and columns.
- **SQL console** with syntax highlighting, Tab-to-complete autocompletion (schema-aware),
  run-statement-at-cursor, server-side cancellation (`pg_cancel_backend` / `KILL QUERY`),
  and running a `.sql` file statement by statement.
- **Editable results grid** — edit, insert, duplicate and delete rows; changes are staged,
  listed with per-row discard, reviewable as SQL, and committed together. Multi-cell
  selection, copy/paste, and column auto-fit.
- **Table view** separate from the console, with a completing WHERE filter, sortable
  headers, an adjustable row limit, paging ("Load more") and total row counts.
- **Schema editing** — add, rename, retype and drop columns, indexes and tables, with the
  generated DDL shown before it runs.
- **Export** a table, a schema or the whole database through `pg_dump` / `mysqldump` /
  `mariadb-dump` — with
  structure/data, DROP/CREATE options, INSERT-statement or custom format, and **gzip** so
  you can send it straight on. The binary is matched to the server's major version. A
  configurable default export folder (Downloads) with timestamped filenames, and
  **reveal-in-Finder after export**.
- **Import / restore** dumps through `psql` / `pg_restore` / `mysql` / `mariadb`. (SQLite has
  no dump pipeline — the database *is* a file; Tessera offers Reveal in Finder instead.)
- **Export query results** to CSV or JSON.
- **SSH tunnelling** with password or key authentication (OpenSSH ed25519 and RSA keys).
- **Secrets stay in the Keychain** — never in a config file, never in the organizer JSON.
- **Built-in MCP server** — optionally let an AI assistant inspect your schema and run
  queries, gated by per-connection read/write permissions. See below.
- **Localized** — English and Czech.

## Requirements

macOS 26 or later, on Apple silicon or Intel. Building requires Xcode 26 or later.

## Download

Through [Homebrew](https://brew.sh):

```sh
brew tap tedyno/tessera
brew install --cask tessera
```

Or grab the latest **[`Tessera.dmg` from Releases](https://github.com/tedyno/Tessera/releases/latest)**,
open it, and drag Tessera to your Applications folder. The DMG is a universal build (Apple
silicon and Intel).

From 0.20.0 on, Tessera **keeps itself up to date** — it checks for new versions and offers
to install them, and you can trigger a check anytime from **Tessera ▸ Check for Updates…**.
Every update is verified against a signature (Sparkle / EdDSA) before it is installed, so it
is safe even though the app isn't notarized.

## Installing

The build is **not notarized**, because notarization requires a paid Apple Developer account
and this is an open-source project without one. macOS will therefore refuse to open it on the
first try, reporting that it cannot be checked for malicious software.

To open it anyway, launch it once, dismiss the warning, then go to **System Settings ▸
Privacy & Security**, scroll to the security section, and click **Open Anyway**. (The old
right-click → *Open* shortcut no longer works; Apple removed that bypass in macOS 15.)

Alternatively, strip the quarantine flag from the terminal:

```sh
xattr -dr com.apple.quarantine /Applications/Tessera.app
```

If overriding Gatekeeper makes you uncomfortable — reasonably so — build it from source
instead, and the question never comes up.

## Building from source

```sh
git clone https://github.com/tedyno/Tessera.git
cd Tessera
open Tessera.xcodeproj   # then ⌘R
```

Or from the command line:

```sh
xcodebuild -project Tessera.xcodeproj -scheme Tessera -destination 'platform=macOS' build
```

The portable core is a local Swift package and builds and tests on its own:

```sh
cd TesseraCore && swift build && swift test
```

### Stop the Keychain re-asking on every build

By default local builds are **ad-hoc** signed, which gives the app a different identity each
time, so the Keychain treats every build as a new application and re-asks permission for each
stored connection password. To give the app a stable identity, create a self-signed code
signing certificate once:

```sh
Scripts/make-signing-cert.sh
```

It writes an untracked `Config/Local.xcconfig` pointing the build at the certificate. Rebuild,
then click **Always Allow** on the Keychain prompt once per connection — because the signature
is now stable, it won't ask again. (This does not get you past Gatekeeper; that still needs a
paid Developer ID and notarization.)

## MCP server

Tessera can act as a [Model Context Protocol](https://modelcontextprotocol.io) server, so an
assistant (Claude Code, Codex, or any MCP client) can inspect your schema and run queries for you.

It is **off by default**, and access is layered so that nothing happens by accident:

1. A master switch in **Settings ▸ MCP**, off until you turn it on.
2. Per connection, separate **read** and **write** permissions — a connection is invisible to
   MCP until you grant read.
3. Every write, export and import asks for confirmation, showing the exact SQL or file.
4. A connection marked read-only can never be granted write access.

The server binds to `127.0.0.1` only, requires a bearer token, and refuses any request
carrying an `Origin` header, so a web page cannot drive it. Passwords are never exposed over
MCP, and MCP cannot choose where an export is written. **Query ▸ MCP Activity** shows a live
log of everything a client has done.

Settings ▸ MCP generates the client configuration snippet for you.

## Architecture

Two layers, strictly separated:

```
Tessera.xcodeproj      # macOS app target (SwiftUI)
Tessera/               # app sources (UI layer)
TesseraCore/           # local Swift Package — portable core, no SwiftUI
  Sources/DBKit/           # models + protocols (no networking dependencies)
  Sources/DBPersistence/   # organizer and profile persistence (JSON)
  Sources/DBDriverPostgres/
  Sources/DBDriverMySQL/   # also serves MariaDB (same wire protocol)
  Sources/DBDriverSQLite/  # system libsqlite3, no dependencies
  Sources/DBTunnel/        # SSH local port forwarding
  Sources/DBSecurity/      # Keychain wrapper
  Sources/DBMCPServer/     # MCP HTTP transport
```

`TesseraCore` deliberately knows nothing about SwiftUI; the drivers depend on `DBKit`, never
the other way round. The UI talks to the core purely through `DBKit` protocols, injected as
dependencies.

**Tech stack:** Swift 6 (strict concurrency), SwiftUI, PostgresNIO, MySQLNIO, the system
SQLite3 C library, Citadel (swift-nio-ssh), Security.framework.

## Contributing

Issues and pull requests are welcome. Two things to know before you open one:

- All repository content is in **English** — code, comments, commit messages, docs. The app
  UI is localized separately through `Tessera/Localizable.xcstrings`.
- Every user-facing string must be localizable; never hand a bare `String` to the UI.

[`CONTRIBUTING.md`](CONTRIBUTING.md) has the rest: how the two layers are separated, why
non-trivial logic belongs in `TesseraCore` with tests, and how to add a translation. Security
issues go through [`SECURITY.md`](SECURITY.md), privately rather than in a public issue.

## License

Copyright (C) 2026 David Vaníček

Tessera is free software: you can redistribute it and modify it under the terms of the
**GNU General Public License, version 3**, as published by the Free Software Foundation.
See [`LICENSE`](LICENSE) for the full text.

It is distributed in the hope that it will be useful, but **without any warranty** — without
even the implied warranty of merchantability or fitness for a particular purpose.

Third-party components and their notices are listed in
[`THIRD-PARTY-LICENSES.md`](THIRD-PARTY-LICENSES.md).

## Releasing

Maintainers only:

```sh
Scripts/make-release.sh 0.1.0            # build, sign, package into dist/
Scripts/make-release.sh 0.1.0 --publish  # ...and create the GitHub release
```

The release is signed locally rather than in CI: the certificate is what every user's
Keychain trusts, so it never leaves the maintainer's machine. The script refuses to package
an ad-hoc signed build, because releasing one would reset every user's stored passwords.
