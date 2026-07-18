# Tessera — project guide for Claude

Native macOS database client (PostgreSQL + MySQL), open source, Swift 6 + SwiftUI.
No Electron/webview/JavaScript. Mac-first, distributed as an unsigned/un-notarized
open-source build (no App Store → no App Sandbox).

## Language policy

- **All project content is in English** — code, comments, identifiers, commit messages,
  README, docs. Do not add Czech to the repository.
- **The app UI is localized (multilingual).** Every user-facing string must be
  localizable: use SwiftUI `Text("…")` (`LocalizedStringKey`) or `String(localized:)`,
  never a bare `String` shown to the user. Strings are collected in
  `Tessera/Localizable.xcstrings` (String Catalog). English is the source language;
  additional languages (incl. Czech) are added in the catalog.

## Architecture

Two layers, strictly separated:

- **`TesseraCore/`** — local Swift Package, the portable core. **Must not import SwiftUI.**
  - `DBKit` — value models + protocols, no networking/NIO dependencies
    (`ConnectionProfile`, `DatabaseDriver`, `DatabaseTree`, `QueryResult`, …).
  - `DBPersistence` — organizer + profile persistence as JSON (depends only on `DBKit`).
  - Drivers (`DBDriverPostgres`, `DBDriverMySQL`) and `DBTunnel` depend on `DBKit`, never
    the reverse. The UI works purely through `DBKit` protocols via dependency injection.
- **`Tessera/`** — SwiftUI app target. Three-column `NavigationSplitView`
  (organizer · schema · detail). Uses Xcode file-system synchronized groups, so new files
  under `Tessera/` are picked up automatically — no need to edit `project.pbxproj`.

## Conventions

- Swift 6 language mode (strict concurrency). Core models are `Sendable` value types.
- **Secrets never touch disk.** `ConnectionProfile` (and the organizer JSON) hold no
  passwords; secrets go to the Keychain. `Secrets` is intentionally non-`Codable`.
- Two distinct trees: the user's connection organizer (persisted) and the live schema
  (runtime, not persisted). Keep them separate.
- Minimum target: macOS 26. Prefer the newest SwiftUI/Observation APIs.

## Build / test / run

```sh
# Core package
cd TesseraCore && swift build && swift test

# App
xcodebuild -project Tessera.xcodeproj -scheme Tessera -destination 'platform=macOS' build
# or open Tessera.xcodeproj and ⌘R
```

Verification loop: Claude writes and builds; the user runs the app in Xcode (⌘R) and
confirms behavior. A SwiftUI GUI cannot be launched/screenshotted automatically here.

## Git

- Author is the user only. **Never** add a `Co-Authored-By: Claude` trailer or any
  Claude/AI attribution to commits.
- Keep commit message bodies short (≤ 2 sentences): state the why, not a diff recap.

## Roadmap

Phased MVP: 0 skeleton → 1 Postgres → 2 Keychain + organizer UI → 3 schema → 4 MySQL →
5 SSH tunnel → 6 tabs + history → 7 editor polish → 8 grid performance. Phase 0 is done.
