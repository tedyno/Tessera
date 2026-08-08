# Contributing to Tessera

Issues and pull requests are welcome. Tessera is a native macOS app in Swift 6 and SwiftUI —
no Electron, no webview, no JavaScript — and a few conventions keep it that way.

## Getting set up

```sh
git clone https://github.com/tedyno/Tessera.git
cd Tessera
open Tessera.xcodeproj   # then ⌘R
```

You need macOS 26 and Xcode 26. The portable core builds and tests on its own:

```sh
cd TesseraCore && swift build && swift test
```

Local builds are ad-hoc signed by default, which makes the Keychain treat every build as a
new app and re-ask for each stored password. `Scripts/make-signing-cert.sh` creates a
self-signed certificate once and stops that.

## Language

**All repository content is in English** — code, comments, identifiers, commit messages,
documentation. The app UI is a separate matter: it is localized, currently into English and
Czech.

Every user-facing string must be localizable. Use SwiftUI `Text("…")` (`LocalizedStringKey`)
or `String(localized:)`; never hand a bare `String` to the UI. Strings live in
`Tessera/Localizable.xcstrings`.

**Adding a user-facing string means adding its translations in the same change.**
`xcodebuild` does not write to the string catalog — only Xcode.app does — so a new string
silently stays English-only unless you edit the catalog too. It is plain JSON, so adding the
key by hand works; mark it `"extractionState": "manual"`. Czech needs three plural forms
(1 / 2–4 / 5+), so a counted string uses `localizations.cs.variations.plural` with
`one` / `few` / `other` rather than a single `stringUnit`. Purely structural keys (`%@ %@`,
`%lld`, `CSV`) get `"shouldTranslate": false` instead of a translation.

## Architecture

Two layers, strictly separated:

- **`TesseraCore/`** — a local Swift package, the portable core. **Must not import SwiftUI.**
  `DBKit` holds value models and protocols with no networking dependencies; the drivers
  (`DBDriverPostgres`, `DBDriverMySQL`, `DBDriverSQLite`), `DBTunnel`, `DBPersistence`,
  `DBSecurity` and `DBMCPServer` depend on `DBKit`, never the reverse.
- **`Tessera/`** — the SwiftUI app target, a thin shell over the core. It uses Xcode
  file-system synchronized groups, so new files under `Tessera/` are picked up
  automatically; there is no need to edit `project.pbxproj`.

The app target **has no test suite** — logic that lives there can only be checked by running
the GUI. So put non-trivial logic in `TesseraCore` as pure functions and value types, not in
views, `@Observable` models or AppKit coordinators. Anything that maps inputs to outputs
deterministically — SQL generation, parsing, filtering, ranking, layout maths, text
transforms — belongs in the core with tests. `SQLCompletionEngine`, `RowEditSQL`,
`GridDisplay`, `ERDLayout` and `PlanParser` are the pattern to follow.

**Every new core type ships with tests in the same change.** Anything that builds SQL which
will run against a user's database must be covered before it is merged.

## Conventions

- Swift 6 language mode, strict concurrency. Core models are `Sendable` value types.
- **Secrets never touch disk.** `ConnectionProfile` and the organizer JSON hold no passwords;
  secrets go to the Keychain, and `Secrets` is intentionally non-`Codable`.
- Keep the two trees apart: the user's connection organizer is persisted, the live schema is
  runtime-only.
- Minimum target is macOS 26 — prefer the newest SwiftUI and Observation APIs.

## Pull requests

Keep commit message bodies short and say *why*, not what the diff already shows. CI builds
the app and runs the core test suite on every pull request; both must be green.
