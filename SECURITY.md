# Security policy

Tessera holds database credentials and opens SSH tunnels, so security reports are taken
seriously.

## Reporting a vulnerability

**Please do not open a public issue.** Use GitHub's private reporting instead:
go to the [Security tab](https://github.com/tedyno/Tessera/security/advisories/new) and
choose *Report a vulnerability*. That opens a private thread visible only to the maintainer.

Useful things to include: the affected version, what an attacker would need (local access, a
malicious database server, a hostile web page, …), and the steps to reproduce.

Expect a first response within a week. Tessera is a one-person open-source project, so
please be patient — there is no security team on standby.

## Supported versions

Only the latest release gets fixes. Tessera updates itself through Sparkle, so users are
normally on it already.

## Design notes worth knowing before reporting

These are deliberate choices, not oversights:

- **Builds are not notarized.** Notarization requires a paid Apple Developer account, which
  this project does not have. Releases are signed with a self-signed certificate, which is
  why macOS asks the user to allow the app once. Updates are additionally verified against an
  EdDSA signature (Sparkle) before they are installed.
- **The app is not sandboxed.** It is distributed outside the App Store and needs to reach
  arbitrary database hosts, `pg_dump`/`mysqldump` binaries and SSH keys.
- **Passwords live in the Keychain**, never in the organizer JSON or any config file.
- **The MCP server is off by default.** When enabled it binds to `127.0.0.1` only, requires a
  bearer token, and rejects any request carrying an `Origin` header so a web page cannot
  drive it. Read and write are granted per connection, writes and imports/exports need
  confirmation, and passwords are never exposed over MCP.

Reports that amount to "the app is not notarized" or "the app is not sandboxed" will be
closed with a pointer to this section. Anything that bypasses one of the guarantees above —
for example reaching the MCP server from a browser, extracting a password through it, or
getting an unsigned update installed — is very much in scope.
