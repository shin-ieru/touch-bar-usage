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
| No OpenAI host is contacted | no provider HTTP client remains; enforced by audit |
| Only read-only RPC methods are sent | `CodexAppServerClient.allowedMethods`, asserted in tests and audit |
| Server error text cannot leak account details | messages are truncated to one 80-char line; stderr is drained but never logged |
| No orphan child process | explicit shutdown on termination, verified on hardware |

## Claude: CLI-owned authentication

Touch Bar Usage delegates Claude authentication and usage retrieval to the
installed Claude Code CLI. It does not refresh, rewrite, or own Claude Code
credentials. Direct Keychain and OAuth HTTP code has been deleted.

The experimental control protocol is preferred; isolated `/usage` is the default
compatibility fallback. Only a consistent logged-out JSON response from
`claude auth status` may trigger Sign in. Unknown auth and usage failures preserve
last-good data as stale.

| Guarantee | Enforcement |
| --- | --- |
| No direct Claude credential access or HTTP calls | source removal and audit |
| No model prompt or tool execution requested | control-only requests, tools/hooks/MCP disabled |
| No project context | dedicated empty working directory, no project settings |
| No credential or account logging | fixed diagnostics, discarded raw output |
| Bounded child lifetime | timeouts, cancellation, terminate/kill and reap |
| Normalized cache only | serialization tests |

CLI behavior is a trust boundary: it owns its own auth refresh, network traffic,
configuration and internal metadata access. The monitor never initiates login,
logout or token exchange. Unknown interactive prompts abort safely. See
[the security model](docs/security-model.md) and
[protocol evidence](docs/claude-control-protocol.md).

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
