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
3. **Never mutate stored credentials.** Providers read whatever the parent tool
   (Claude Code, and later Codex) already stores. Token refresh belongs to that
   tool. If a token is expired, report `needsAuthentication`.

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
| Installed but no/expired credential | `needsAuthentication` | The fix is "sign in over there" |
| Credential exists, we cannot read it | `failed("keychain access denied")` | The fix is a permission prompt |
| HTTP 401/403 | `needsAuthentication` | Same fix as above |
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

Two providers now exist, and they take deliberately different approaches — worth
reading both before adding a third:

| | Claude | Codex |
| --- | --- | --- |
| Credential | access token read from Keychain | **none held** |
| Transport | `URLSession` GET | stdio JSON-RPC to a local broker |
| Failure surface | HTTP status | RPC error / child exit |

**Prefer the Codex shape when the vendor ships a local broker.** Asking an
already-authenticated local process for numbers is strictly safer than handling a
credential yourself. Read a token only when there is no alternative, as with
Claude.

## Adding a provider — checklist

1. Create `Sources/TouchBarUsageKit/Providers/<Name>/`.
2. Implement `UsageProvider`, splitting credential reading, HTTP, and parsing into
   separate types as the Claude provider does — it keeps each unit testable.
3. Categorize windows by meaning; tolerate unknown keys.
4. Add fixtures under `Tests/TouchBarUsageKitTests/Fixtures/`, mirroring the
   Claude parser test cases (valid, missing window, null reset, out-of-range
   percentage, unknown fields, malformed).
5. Add provider state-mapping tests using `StubHTTPClient`.
6. Extend `SecurityTests` to cover the new credential path.
7. Do not modify Claude internals. If you need to, the seam is in the wrong place
   — fix the seam.
