# Security model

## Two providers, two very different boundaries

| | Claude | Codex |
| --- | --- | --- |
| Credential read by this app | access token from Keychain | **none** |
| Network calls made by this app | one GET to `api.anthropic.com` | **none** |
| Who talks to the vendor | this app | the local Codex App Server |

Codex has the stronger boundary, and the reason is simply that a local broker
exists: the Codex App Server already owns authentication, so this app asks it for
numbers over a pipe and never handles an OpenAI credential at all. Anthropic
exposes no equivalent, so the Claude provider must read a token — which is why
the rest of this document is mostly about containing that.

Where a local broker exists, using it is strictly safer, and this project uses it.

## What the app accesses

- **Physical Touch Bar APIs** — private `NSTouchBar` / `DFRFoundation` entry points
  (see [`touchbar-research.md`](touchbar-research.md)).
- **Claude Code installation status** — file-existence checks at known install
  paths. The CLI is never executed.
- **One existing macOS Keychain item** — the generic-password item with service
  name `Claude Code-credentials`, created by Claude Code itself. Read-only.
- **One Anthropic endpoint** — `https://api.anthropic.com/api/oauth/usage`.
- **A local normalized cache** — `~/Library/Application Support/com.gabrielanyog.touchbarusage/`.
- **The local Codex App Server** — launched as a child process, spoken to over
  stdio JSON-RPC. Only `initialize`, `initialized` and `account/rateLimits/read`
  are ever sent.
- **An already-installed OpenAI application's icon file**, read from disk to draw
  the Codex mark. Nothing is downloaded and nothing is committed.

### What the app does not access, for Codex specifically

- `~/.codex/auth.json` or any OpenAI token
- `api.openai.com` or any OpenAI host
- `account/rateLimitResetCredit/consume` — spends the user's reset credits
- `account/sendAddCreditsNudgeEmail` — sends the user mail
- `account/login` / `account/logout` — this app never touches authentication
- threads, prompts, conversations, exec, or config methods

`make audit` fails the build if a credential path, OpenAI endpoint, or
non-read-only RPC method appears in tracked source.

## What the app does not access

- Claude conversation contents
- prompts or model responses
- terminal history
- source code or project files
- browser cookies
- any other Keychain entry
- Codex / OpenAI credentials

The app never sends a prompt, never approves a tool call, and never performs
inference. It makes exactly one kind of request: a read-only usage GET.

## The usage endpoint is undocumented

`GET https://api.anthropic.com/api/oauth/usage` is **not** part of Anthropic's
published public API. It is the endpoint Claude Code's own OAuth session uses,
identified by observing existing open-source usage tools. Treat it as
**experimental**:

- it may change shape or disappear without notice;
- it is not covered by any API stability guarantee;
- the parser is deliberately defensive as a result — unknown buckets are kept,
  missing fields are tolerated, and a malformed body degrades to a stale or
  failed state rather than crashing.

The live response observed during development already contained a bucket this
project does not recognise, which is why that tolerance is not hypothetical.

If Anthropic later publishes a supported local or non-interactive usage
mechanism, the provider should move to it.

## Credential handling

### Which field is read

Only two values are lifted out of the keychain blob:

```
claudeAiOauth.accessToken
claudeAiOauth.expiresAt
```

`refreshToken`, `refreshTokenExpiresAt`, `scopes`, `subscriptionType`,
`rateLimitTier` and `organizationUuid` are present in the stored JSON and are
**never copied out of the parse function**. `SecurityTests` asserts this by
reflecting over the parsed value and failing if any other field survived.

### The refresh token is never used

This app does not refresh, rotate, write, or delete the credential. Claude Code
owns the authentication lifecycle. When the access token is expired or the
endpoint returns 401/403, the app reports `needsAuthentication` and tells the
user to re-authenticate in Claude Code. It never mutates the keychain item.

This is the single biggest reduction in the app's security surface: a read-only
consumer of someone else's credential cannot corrupt that credential.

### Guarantees about the access token

- Held only for the duration of one HTTP request; never stored in a property that
  outlives the fetch.
- Sent only in an `Authorization` header, only to `api.anthropic.com`.
- Never placed in a URL, query parameter, or process argument (so it cannot
  appear in `ps`).
- Never written to disk, the cache, the clipboard, or shell history.
- Never logged: the logger redacts by key *and* by value shape, so even an
  accidental `metadata: ["note": token]` is replaced with `<redacted>`.
- `ClaudeCredential`'s `description` and `debugDescription` are redacted, so
  accidental string interpolation cannot leak it.
- `ClaudeCredential` is deliberately **not** `Codable`.

### Why the cache cannot contain a secret

The cache stores `UsageSnapshot`, whose fields are a provider ID, a fetch date,
and normalized windows (label, percent, reset date, category). There is no field
capable of holding a credential. This is a structural property, not a discipline
one. `SecurityTests` encodes a snapshot, reads the bytes back off disk, and fails
if any credential-shaped substring appears.

### Keychain access prompt

The app uses `Security.framework` (`SecItemCopyMatching`). Because the keychain
item was created by Claude Code, macOS shows a standard access prompt the first
time. Granting it allows this app to read that one item. Denying it leaves the
app in a `failed("keychain access denied")` state, reported in Diagnostics — the
app does not fall back to shelling out to `/usr/bin/security`, and does not retry
in a loop.

## Network

- Native `URLSession` with an **ephemeral** configuration: no on-disk cache, no
  cookie storage.
- 15 s request timeout, 30 s resource timeout.
- Exactly one destination, hard-coded and not user-configurable.
- Refresh at most once per 5 minutes, with a hard 60 s floor between any two
  fetches, request coalescing, and exponential backoff on HTTP 429 — so the app
  cannot itself become a source of rate-limit traffic against an undocumented
  endpoint.
- Request headers are never logged.

## Permissions

The app requests **no** special permissions: no Accessibility, no Screen
Recording, no Input Monitoring, no Full Disk Access, no Automation. It declares no
entitlements and is not sandboxed (the private Touch Bar APIs are incompatible
with the App Sandbox). The only user-facing prompt is the keychain one described
above.

## Telemetry

There is none. No analytics, no crash-reporting SDK, no ads, no developer
backend, no update pings. `api.anthropic.com` is the only host contacted, and the
project has no server component.

## Diagnostics safety

The Diagnostics window and its "Copy Diagnostics" button emit only
`DiagnosticEntry` label/value pairs: presence, status, and version strings. No
token, no credential JSON, no account identifier, no raw payload. A test asserts
the diagnostics text contains no credential material even when the provider is
handed a token-shaped value.

---

Touch Bar Usage is an independent open-source project and is not affiliated with,
endorsed by, or sponsored by Anthropic.
