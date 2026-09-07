# Codex integration

How Touch Bar Usage reads OpenAI Codex usage, and why it never holds an OpenAI
credential.

## Trust boundary

```
Touch Bar Usage  ──local stdio JSON-RPC──▶  Codex App Server  ──authenticated──▶  OpenAI
```

**This app never sees an OpenAI token.** It does not read `~/.codex/auth.json`,
holds no OpenAI credential, and makes no request to any OpenAI host. The Codex
App Server — which the user already installed and logged into — owns
authentication and performs the network call on its own behalf. All that crosses
our boundary is a local pipe carrying usage percentages.

This is a deliberately narrower boundary than the Claude provider's, which must
read an access token from the keychain because Anthropic exposes no equivalent
local server. Where a local broker exists, using it is strictly safer.

`make audit` enforces this: it fails if `auth.json`, `OPENAI_API_KEY`,
`sk-proj-`, or `api.openai.com` appears anywhere in tracked source outside a
comment.

## Protocol

The message shapes are taken from the app server's **own generated schema**, not
guessed:

```bash
codex app-server generate-json-schema --out /tmp/codex-schema
```

### Handshake

```
→ {"jsonrpc":"2.0","id":1,"method":"initialize",
   "params":{"clientInfo":{"name":"touch-bar-usage","version":"0.2.0"}}}
← {"jsonrpc":"2.0","id":1,"result":{...}}
→ {"jsonrpc":"2.0","method":"initialized"}
```

### Reading usage

```
→ {"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read"}
← {"jsonrpc":"2.0","id":2,"result":{ ...GetAccountRateLimitsResponse... }}
```

Newline-delimited JSON over the child process's stdin/stdout.

### Methods this app may send

| Method | Why |
| --- | --- |
| `initialize` | required handshake |
| `initialized` | required handshake |
| `account/rateLimits/read` | the usage read |

**Nothing else.** The server also exposes `account/rateLimitResetCredit/consume`
and `account/sendAddCreditsNudgeEmail`; those spend the user's rate-limit reset
credits or send them mail, and a monitor must never call them. It also exposes
thread, exec and config methods — none are used. `CodexAppServerClient.allowedMethods`
is asserted in tests, and `make audit` fails if a forbidden method is referenced.

The server pushes `account/rateLimits/updated` notifications, which the transport
routes to a handler rather than treating as a response.

## Response shape

```
GetAccountRateLimitsResponse
  rateLimits           : RateLimitSnapshot         (required; legacy single bucket)
  rateLimitsByLimitId  : { limitId: RateLimitSnapshot }?   (multi-bucket, e.g. "codex")

RateLimitSnapshot
  limitId, planType, primary?, secondary?, credits?, ...

RateLimitWindow
  usedPercent (required)      // already "used", matching Claude's semantics
  windowDurationMins?         // 300 = 5 hours, 10080 = 7 days
  resetsAt?                   // unix SECONDS
```

### Normalization rules

- **Prefer `rateLimitsByLimitId["codex"]`**; fall back to `rateLimits` for older
  servers. When the multi-bucket view contains unrelated products (Sora, say),
  the `codex` bucket is selected by name, never by position.
- **Classify by `windowDurationMins`, never by field name.** `primary` is *not*
  guaranteed to be the 5-hour window; a response with them reversed must still
  produce the right figures. There is a test for exactly this.
- **300 → short, 10080 → weekly, anything else → `.other`**, kept and labelled
  honestly (`1d`, `3h`, `45m`) rather than forced into a bucket it does not
  belong to.
- **`usedPercent` is consumed quota**, matching Claude. A provider showing
  "remaining" while the other shows "used" would be actively misleading.
- Percentages are clamped to 0…100 by `UsageWindow`.

### A missing 5-hour window

Some accounts report only the weekly bucket. Nothing is invented:

- the compact chip shows `Codex  W 31%` — no 5h segment at all;
- the detail page shows a `5h — not reported` row;
- the menu shows `5-hour limit: not reported`;
- Diagnostics shows `Codex 5h window: not reported`.

Rendering `0%` would read as "plenty left", which is the opposite of the truth.

## Process lifecycle

One long-lived child process, not one per refresh: startup costs hundreds of
milliseconds, and only a persistent connection receives the server's push
notifications.

- `CodexJSONRPCTransport` owns `Process` + `Pipe`s and does the framing.
- Requests are matched by id, so an interleaved notification or an out-of-order
  response is never mistaken for a given call's answer.
- Each request races a timeout; whichever lands first wins and the pending entry
  is always cleared, so ids cannot leak.
- A timeout or child exit drops the connection so the next read starts a fresh
  child rather than staying wedged.
- stderr is drained but **never logged** — it may echo account details.
- Termination shuts the child down explicitly; verified to leave no orphan
  (`codex app-server` process count goes 1 → 0 → 1 across a quit and relaunch).

### Framing

Newline-delimited JSON is deceptively fiddly, so `JSONRPCFramer` is a separate,
directly tested type covering: a message split across reads, several messages in
one chunk, a trailing partial message, blank lines, malformed lines (skipped, not
fatal), and a runaway oversized line — which is discarded *including its trailing
fragment*, rather than delivering the fragment as though it were a message.

## Executable discovery

No single machine-specific path is assumed. In order:

1. `TBU_CODEX_PATH` (development override)
2. every entry on `PATH`
3. `/opt/homebrew/bin/codex` (Apple silicon), `/usr/local/bin/codex` (Intel)
4. `~/.local/bin`, `~/.codex/bin`, `~/.bun/bin`, global npm roots
5. the `codex` binary bundled in the OpenAI editor extensions
   (`~/.vscode/extensions/openai.chatgpt-*/bin/<arch>/codex`, plus Insiders,
   Cursor, VSCodium and Windsurf), newest version first, architecture matched
   rather than assumed

If none is found, Codex reports `notInstalled` and **Claude continues working**.

## Refresh

Codex has its own `RefreshCoordinator`, so its backoff and last-good snapshot are
independent of Claude's. Providers refresh concurrently in a task group; one being
slow, rate limited or offline cannot delay or block the other.

Cadence is inherited from Phase 1: 5-minute timer, 60-second hard floor between
fetches, request coalescing, refresh on launch, wake and manual request.

## Failure mapping

| Situation | State | What the user sees |
| --- | --- | --- |
| Codex CLI absent | `notInstalled` | "Codex CLI not found" |
| Signed out | `needsAuthentication` | "sign in" · "Run `codex login`" |
| App server will not start | `failed` | "unavailable" |
| Request timed out | `offline` | last good numbers, marked stale |
| Unparseable body | `failed` | "unavailable" |
| Reachable but no windows | `failed("no rate limits reported")` | "unavailable" |

A timeout maps to `offline` deliberately: it is transient, so the coordinator
keeps the last good snapshot and marks it stale rather than blanking Codex out.

## Verified

Against Codex CLI **0.153.0** on macOS 26.6.2, live:

- handshake and `account/rateLimits/read` succeed;
- the real response carried `rateLimitsByLimitId.codex` with `primary`
  300 minutes and `secondary` 10080 minutes;
- both windows parsed and rendered;
- one child process, cleanly shut down on quit.
