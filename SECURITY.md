# Security

## Reporting a vulnerability

Open a GitHub issue for anything non-sensitive. For a credential-handling
problem, please report it privately through GitHub's "Report a vulnerability"
flow rather than in a public issue.

## Codex: no OpenAI credential is ever held

Codex usage is read through the **local Codex App Server** over stdio JSON-RPC.
This app does not read `~/.codex/auth.json`, holds no OpenAI token, and contacts
no OpenAI host. Only `initialize`, `initialized` and `account/rateLimits/read`
are sent — never anything that spends rate-limit reset credits, sends mail, or
touches authentication.

| Guarantee | Enforced by |
| --- | --- |
| No OpenAI credential is read | no code path opens `auth.json`; `make audit` fails if one appears |
| No OpenAI host is contacted | `URLSession` is confined to `AnthropicUsageClient`, asserted in tests |
| Only read-only RPC methods are sent | `CodexAppServerClient.allowedMethods`, asserted in tests and audit |
| Server error text cannot leak account details | messages are truncated to one 80-char line; stderr is drained but never logged |
| No orphan child process | explicit shutdown on termination, verified on hardware |

## Claude: two sources, one authority

1. Read-only OAuth usage fast path, when the credential is readable.
2. If it is not, ask `claude auth status` whether you are signed in — the **only**
   thing that can produce "Sign in". An unreadable keychain, an expired token or a
   401 never conclude that on their own.
3. Optionally (opt-in) read `/usage` from an isolated no-tools Claude Code session.
4. **Claude Code owns authentication and credential refresh.** This app never
   reads the refresh token, never exchanges or rotates it, and never writes to
   the keychain.

The keychain read is time-limited and pauses after a denial, so a permission
dialog can neither hang a refresh nor be raised on every one.

## Threat model in one paragraph

Touch Bar Usage reads one existing credential that another application (Claude
Code) already stores on your Mac, uses it for a single read-only HTTP GET to
Anthropic, and displays the resulting percentages. It never writes that
credential, never uses the refresh token, never persists the access token, and
contacts no host other than `api.anthropic.com`.

The full model is in [`docs/security-model.md`](docs/security-model.md).

## Credential guarantees

If you take nothing else from this document:

| Guarantee | Enforced by |
| --- | --- |
| Only `claudeAiOauth.accessToken` and `expiresAt` are read | `KeychainClaudeCredentialReader.parse`, asserted in `SecurityTests` |
| The refresh token is never read or used | same parse function; test reflects over the result |
| The token is never written to disk | `UsageSnapshot` has no field that can hold one |
| The token is never logged | `Log.redact` redacts by key **and** by value shape |
| The token never reaches the clipboard | Diagnostics copies only `DiagnosticEntry` values |
| The token goes only to Anthropic | endpoint is a hard-coded constant, asserted in tests |
| The keychain is never modified | no `SecItemAdd` / `SecItemUpdate` / `SecItemDelete` call exists |

## Private API use

The system-wide Touch Bar presentation depends on private macOS APIs, confined to
[`SystemModalTouchBarBridge.swift`](Sources/TouchBarUsage/TouchBar/SystemModalTouchBarBridge.swift).
Consequences you should be aware of:

- **This app is not suitable for the Mac App Store** and is not submitted to it.
- A macOS update may remove these APIs. The bridge resolves everything
  dynamically and disables the Touch Bar feature rather than crashing.
- The app is **not sandboxed**, because the App Sandbox is incompatible with
  these APIs.

## What we ask of contributors

- Never commit a credential, a real keychain blob, or an unredacted response
  captured from a real account.
- Never add a log statement that interpolates a credential; use the structured
  metadata API so redaction applies.
- Keep private API use inside the bridge.
- Run `make audit` before opening a pull request.

---

Touch Bar Usage is an independent open-source project and is not affiliated with,
endorsed by, or sponsored by Anthropic.
