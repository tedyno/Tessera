<!-- Say why the change is needed; the diff already shows what it does. -->

## Checklist

- [ ] Repository content is in English (code, comments, commit messages)
- [ ] New user-facing strings are localizable **and** have Czech translations in
      `Tessera/Localizable.xcstrings` (`xcodebuild` does not write to the catalog — add them by hand)
- [ ] New non-trivial logic lives in `TesseraCore`, not in a view or model
- [ ] New core types come with tests in `TesseraCore/Tests/`
- [ ] `cd TesseraCore && swift test` passes
- [ ] The app builds and I ran it (⌘R) to check the change in the GUI
