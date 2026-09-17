# Security model

Both providers delegate credential ownership to their installed official CLIs.

| Boundary | Claude | Codex |
| --- | --- | --- |
| Local transport | stream-json control protocol, isolated PTY fallback | App Server JSON-RPC |
| Usage request | experimental get_usage, then /usage | account/rateLimits/read |
| Auth authority | claude auth status JSON | App Server |
| Credentials read by this app | None | None |
| Provider HTTP calls by this app | None | None |

The Claude credential reader, direct OAuth client and Keychain gate are removed.
The app never reads or uses refresh tokens and never writes provider credentials.
The CLI can refresh its own auth as part of its normal behavior. The monitor does
not call login/logout and does not make token exchanges.

## Process containment

Claude probes use a dedicated Application Support directory. Tools, hooks, MCP,
Chrome and project/user settings sources are disabled through verified CLI flags.
No conversation message is sent. The PTY accepts only `/usage`; it does not attach
to Terminal or request Accessibility. Only a trust screen containing the exact
probe directory can be accepted. Other onboarding and login screens abort.

Each probe is short-lived and bounded. The coordinator prevents overlapping
provider refreshes. Cancellation and timeout terminate/reap the worker; a PTY
process group is also terminated. No persistent worker or idle polling is needed.
The CLI executable and its internals remain trusted dependencies. Its own config,
network requests and metadata behavior are outside the monitor's implementation.

## Output and cache

Control replies may contain unrelated account information; it is discarded.
Only normalized usage windows enter the cache. Error messages and diagnostics use
fixed strings. Raw control payloads and PTY transcripts are never logged or
persisted. Logger redaction provides defense in depth. Tests use synthetic data.

Only consistent explicit auth JSON can establish logout. Usage failure, parse
failure, timeout, UI login text and unsupported methods cannot. Last-good values
remain stale while live usage is unavailable.

## Remaining platform boundaries

Private Touch Bar APIs remain confined to the existing bridge. No additional
macOS permissions are requested. No credential or unlicensed artwork is bundled.
Release builds retain the repository-safe fallback mark. `make audit` enforces
credential/network restrictions and existing artwork and Touch Bar rules.

See [tested protocol and lifecycle](claude-control-protocol.md) for exact flags,
experimental schema limitations and live verification gaps.
