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
- **Adding a user-facing string means adding its translations in the same change.**
  `xcodebuild` does *not* write to `Localizable.xcstrings` — only Xcode.app does — so a
  new string silently stays English-only unless the catalog is edited too. Add the key
  and a Czech value to `Tessera/Localizable.xcstrings` by hand (it is plain JSON), with
  `"extractionState": "manual"`. Czech needs three integer plural forms (1 / 2–4 / 5+),
  so a counted string uses `localizations.cs.variations.plural` with `one`/`few`/`other`
  rather than a single `stringUnit`. Purely structural keys (`%@ %@`, `%lld`, `CSV`)
  get `"shouldTranslate": false` instead of a translation.
- **Check coverage before shipping.** The authoritative list of strings in the code is
  the `.stringsdata` emitted by the build (`SWIFT_EMIT_LOC_STRINGS = YES`), under
  `~/Library/Developer/Xcode/DerivedData/Tessera-*/Build/Intermediates.noindex/Tessera.build/**/Objects-normal/*/`.
  Read them with `plutil -convert json` and compare against the catalog; every key must
  either have a `cs` localization or `shouldTranslate: false`.
- **Never prune the catalog from an incremental build.** Only recompiled files emit
  `.stringsdata`, so a key whose file wasn't rebuilt looks unused and deleting it throws
  away a real translation. Before removing anything, force a full rebuild of the app
  target (`find Tessera -name '*.swift' -exec touch {} +` then build) so the extraction
  covers every file; missing keys are safe to add either way.

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
