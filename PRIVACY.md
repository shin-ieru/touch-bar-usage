# Privacy

Touch Bar Usage has no analytics, advertising, crash-reporting service or backend.

## Local CLI boundary

Claude usage is requested from the installed official Claude Code CLI through
local stdio, with an isolated `/usage` PTY as a compatibility fallback. Codex
continues to use its local App Server. The CLIs own authentication and network
access. This app never receives their bearer or refresh tokens, reads credential
files, accesses the Keychain, or contacts provider HTTP endpoints directly.
Provider handling of CLI requests is governed by the providers' privacy policies.

No model prompt is sent. Tools, hooks, project settings and MCP are disabled for
Claude usage probes. The working directory is a dedicated `ClaudeProbe` directory
under Application Support, outside user projects. The app does not read source
files, conversations, terminal history or browser data. CLI internals can use
their own configuration and session metadata; the app does not retain it.

## Stored data

Normalized cache files live under
`~/Library/Application Support/com.gabrielanyog.touchbarusage/` and contain only
usage percentages, labels, reset times and fetch timestamps. Delete them at any
time; the app can fetch again. No account metadata or raw terminal transcripts
are persisted. The CLI may maintain its own configuration and operational data
according to its own behavior; the monitor does not rewrite that data.

## Logging

Unified logs contain fixed, normalized status messages. They do not include raw
CLI output, credentials, account identifiers or request headers. Diagnostics
include the last known source and availability, not private account details.
The logger also redacts sensitive keys and token-shaped values.
