# Provider contract

What a usage provider must implement, and how its data is normalized. This is the
seam that lets a second provider be added without touching Claude-specific code.

## The protocol

```swift
public protocol UsageProvider: Sendable {
    var id: String { get }            // stable; used in cache filenames and logs
    var displayName: String { get }   // shown in the UI
    func fetchUsage() async -> ProviderState
    func diagnostics() async -> [DiagnosticEntry]
}
```

### Three rules

1. **Never throw.** `fetchUsage()` returns a `ProviderState` for every outcome,
   including credential failure and malformed responses. A provider that traps or
   throws will take the app down; that is a bug, not a caller concern.
2. **Never leak credentials upward.** Callers receive normalized percentages and
   states. They must never see a token, an `Authorization` header, an HTTP status
   object, or a raw response body.
3. **Delegate authentication.** Official CLIs own credential reads and refresh.
   Only authoritative CLI logout evidence may produce `needsAuthentication`.
   Usage failures and unknown auth never imply logout.

## `ProviderState`

```swift
enum ProviderState {
    case loading
    case ready(UsageSnapshot)
    case stale(UsageSnapshot, reason: String?)
    case notInstalled
    case needsAuthentication
    case rateLimited(retryAfter: TimeInterval?)
    case offline
    case unsupported(String)
    case failed(String)
}
```

A provider itself returns only: `ready`, `notInstalled`, `needsAuthentication`,
`rateLimited`, `offline`, `unsupported`, `failed`. **`stale` is produced by
`RefreshCoordinator`, not by providers** — the coordinator owns the last-good
snapshot and decides when to fall back to it.

Guidance on the distinctions that matter:

| Situation | State | Why |
| --- | --- | --- |
| Tool not installed at all | `notInstalled` | The fix is "install it" |
| CLI explicitly confirms logout | `needsAuthentication` | Sign in using the official CLI |
| Usage fails, auth logged in or unknown | `failed(...)` | Coordinator preserves stale cache |
| HTTP 429 | `rateLimited(retryAfter:)` | Coordinator applies backoff |
| No network | `offline` | Transient; last good data still shown |
| Unparseable body | `failed(...)` | Likely an upstream shape change |

`needsAuthentication` is deliberately **never** masked by cached data. Showing
plausible percentages while the user is actually signed out would hide the
problem. Every other failure keeps the last good snapshot, marked stale.

## Normalized model

```swift
struct UsageSnapshot {
    let providerID: String
    let windows: [UsageWindow]
    let fetchedAt: Date
}

struct UsageWindow {
    let id: String                 // provider's own key, e.g. "five_hour"
    let label: String              // compact, e.g. "5h"
    let longLabel: String          // detail view, e.g. "Week"
    let usedPercent: Double        // ALWAYS "used", never "remaining"; clamped 0...100
    let resetAt: Date?
    let duration: TimeInterval?
    let category: UsageWindowCategory
}

enum UsageWindowCategory { case short, weekly, modelSpecific, other }
```

### Invariants a provider must uphold

- `usedPercent` is **consumed** quota, not remaining. If an API returns
  "remaining", convert it. Getting this backwards is the single most damaging
  mistake available here.
- Percentages are clamped at construction. `UsageWindow.init` does this for you;
  do not pre-clamp or bypass it.
- Non-finite values become `0`.
- `resetAt` is optional. A missing reset time is normal, not an error.
- Exactly one window should be `.short` and one `.weekly` — these are what the
  compact bar shows. Anything else goes to `.modelSpecific` or `.other`.
- Categorize by **meaning, never by key order**. `UsageSnapshot.shortWindow` and
  `.weeklyWindow` search by category.

### Unknown buckets

Keep them. Map anything unrecognised to `.other` rather than dropping it or
failing. Anthropic's live response already contains a bucket this project does not
recognise; the compact bar ignores `.other` entirely, and the detail view shows it
only once it has non-zero usage.

## Caching

`SnapshotCaching` persists `UsageSnapshot` and nothing else. Providers do not
touch the cache — `RefreshCoordinator` does. Because `UsageSnapshot` has no field
that can hold a credential, "the cache holds no secrets" is guaranteed by the
type, not by care at the call site. **Do not add a field to `UsageSnapshot` that
could carry credential or account data.**

## Refresh

`RefreshCoordinator` wraps one provider and owns cadence. A provider is called
only when the coordinator decides; it must not schedule its own timers or
retries. The coordinator guarantees:

- no two concurrent fetches for the same provider (callers coalesce);
- a hard 60 s floor between fetches, including manual ones;
- a 5-minute automatic cadence;
- exponential backoff after 429, which manual refresh may bypass (the floor still
  applies);
- last-good snapshot retention on transient failure.

## Diagnostics

`diagnostics()` returns label/value pairs rendered in the Diagnostics window and
copyable to the clipboard. **Everything returned must be safe to paste into a
public bug report.** Report presence and status ("found", "expired",
"not installed"), never values. No tokens, no account identifiers, no raw
payloads, no email addresses.

## Two reference implementations

Both providers delegate to local official CLIs:

| | Claude | Codex |
| --- | --- | --- |
| Credentials held | None | None |
| Transport | stream-json control protocol / isolated PTY | App Server JSON-RPC |
| Failure surface | control response, terminal parsing, child exit | RPC error / child exit |

## Adding a provider

Implement `UsageProvider` with injectable CLI transport and parsers. Add synthetic
fixtures for missing windows, invalid percentages and reset dates. Test state
mapping without installed or authenticated CLIs. Keep normalized cache and safe
diagnostics guarantees. Never add direct credential ownership.
