# Touch Bar Usage v0.1.2

## Fixed

- Claude authentication and usage retrieval now delegate to the installed official
  Claude Code CLI. Removed direct credential access and OAuth HTTP requests.
- Added experimental structured `get_usage` retrieval with version-scoped feature
  detection and an isolated `/usage` compatibility fallback enabled by default.
- Sign in appears only when Claude Code's auth-status JSON confirms logout.
  Usage failures preserve last-good values as stale, including when the terminal
  UI presents onboarding or login while auth status remains logged in.
- Added bounded process lifetime, cancellation, and protocol/fallback tests.

Codex and Touch Bar presentation are unchanged. Distributed builds continue to
use repository-safe artwork; Clawd is available when you build from source with
`make assets`.

## Compatibility

Newer installed official editor CLIs support `get_usage` and are discovered
automatically. Claude Code 2.1.62 rejects it. The interactive fallback needs
normal Claude Code first-run setup to be complete. The structured protocol is
experimental; terminal parsing may need updates as Claude Code changes.

The existing public v0.1.0 and v0.1.1 releases and tags are preserved.
