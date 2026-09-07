# Codex handoff (Phase 2)

Written for the agent adding OpenAI Codex support. Phase 1 implements Claude
only; the provider layer was built to accept a second provider without touching
Claude internals.

**Phase 1 deliberately contains no Codex credential handling, no OpenAI network
code, and no Codex discovery logic.** Nothing here should be read as a design for
those — that is your call, informed by whatever Codex actually exposes.

## Current architecture

```
Sources/
  TouchBarUsageKit/            ← pure logic, no AppKit; this is what CI tests
    Models/                    UsageSnapshot, UsageWindow, ProviderState
    Providers/
      UsageProvider.swift      the protocol you implement
      Claude/                  credential reader · HTTP client · parser · provider
      Mock/                    MockUsageProvider + stubs used by tests
    Services/                  RefreshCoordinator · CacheStore · Log
    ViewModel/                 TouchBarViewModel · DetailViewModel · ResetFormatter
  TouchBarUsage/               ← the app; AppKit + the private-API bridge
    App/                       Main · AppDelegate · MenuBarController · Diagnostics · LoginItem
    TouchBar/                  SystemModalTouchBarBridge · TouchBarController · views · mascot
    Preview/                   development-only PNG renderer
```

The split matters: `TouchBarUsageKit` cannot reach AppKit, the keychain, or the
network without going through an injected dependency, which is why the whole test
suite runs headless.

## Where to add your code

```
Sources/TouchBarUsageKit/Providers/Codex/
    CodexUsageProvider.swift
    CodexCredentialReader.swift     (if a credential is needed)
    CodexUsageClient.swift          (if a network call is needed)
    CodexUsageParser.swift
```

Read [`provider-contract.md`](provider-contract.md) first — it is the actual
specification. The short version: implement `UsageProvider`, never throw, never
leak credentials upward, never mutate stored credentials, and express
`usedPercent` as **consumed** quota clamped to 0...100.

## What must change to render two providers

Phase 1 renders exactly one provider. These are the specific places that assume
that, and what each needs:

### 1. `AppDelegate` — one coordinator per provider

```swift
private let provider = ClaudeUsageProvider()
private var coordinator: RefreshCoordinator!
```

`RefreshCoordinator` wraps a single provider by design (its backoff and
last-good-snapshot state are per-provider). Move to a collection of coordinators
keyed by provider ID and fan the observer callbacks into one combined update.
Do not make `RefreshCoordinator` multi-provider internally — per-provider backoff
is a feature, and one provider rate-limiting must not stall the other.

Stagger the two providers' fetches rather than firing both on the same tick.

### 2. `TouchBarController` — currently single-provider

It holds one `ClaudeCompactView` and one `state`. It needs to hold an ordered
collection of provider view models and lay their compact views out side by side.
Control Strip width is the real constraint: two providers at full width will not
fit, so plan for the condensed form (`TouchBarViewModel.condensedText`, which
drops the provider name and keeps both percentages) and consider dropping the
mascot for the second provider.

### 3. `ClaudeCompactView` / `ClaudeDetailView` — rename, do not fork

Despite the names, **neither contains Claude-specific logic**. Both are driven
entirely by `TouchBarViewModel` / `DetailViewModel`. Rename them to
`ProviderCompactView` / `ProviderDetailView` and reuse them. Copying them into
`CodexCompactView` would duplicate the layout and severity handling — resist it.

The only Claude-specific piece in the view layer is `MascotProvider`, which
hard-codes one image lookup. Generalise it to take a provider ID and resolve
`LocalAssets/<provider>-mascot.png`.

### 4. `MenuBarController` — section per provider

`addProviderSection()` is already a separate method and is written against
`ProviderState` + `DetailViewModel`, so making it a loop over providers is
mechanical. Keep each provider's authentication guidance distinct: "open Claude
Code to sign in" is wrong advice for a Codex credential problem.

### 5. `TouchBarViewModel.make(providerName:state:)`

Already takes the provider name as a parameter and defaults it to `"Claude"`.
Remove the default so both call sites must be explicit.

## What must NOT become coupled to Claude

- `UsageProvider`, `UsageSnapshot`, `UsageWindow`, `ProviderState` — no
  provider-specific field may be added to these.
- `RefreshCoordinator` — no provider-specific branching.
- `CacheStore` — already keys files by provider ID.
- `SystemModalTouchBarBridge` — knows nothing about providers and must stay that
  way.
- `TouchBarViewModel` / `DetailViewModel` — driven by state, not by identity.

If you find yourself writing `if provider.id == "claude"` outside the Claude
directory, the seam is in the wrong place.

## Refresh behaviour you inherit

- 5-minute automatic cadence; fetch on launch, on wake, and on manual request.
- Hard 60 s floor between any two fetches of one provider, manual included.
- Concurrent callers coalesce onto one in-flight request per provider.
- Exponential backoff after 429 (120 s doubling to a 3600 s ceiling), reset on
  success. Manual refresh bypasses backoff but not the floor.
- Transient failure keeps the last good snapshot, marked stale. Authentication
  failure never does.

## Normalized window expectations

Compact bar shows one `.short` and one `.weekly` window, selected by category
rather than key order. `.modelSpecific` appears only in the detail view.
`.other` is retained for forward compatibility, hidden from the compact bar, and
shown in detail only when its usage is above zero — Anthropic's live response
already contains one unrecognised bucket.

If Codex's quota model does not decompose into a short and a weekly window, do
not force it. Add a category and decide explicitly what the compact bar shows;
`UsageWindowCategory` is the right place for that change.

## Tests a Codex provider should mirror

Look at `ClaudeUsageParserTests`, `ClaudeUsageProviderTests`, and `SecurityTests`
and produce the equivalents:

- **Parser:** valid response, missing window, null reset timestamp, percentage
  above 100, percentage below 0, unknown extra fields, malformed body, empty body.
- **Provider states:** success, unauthorized → `needsAuthentication`, expired
  credential short-circuits before any request, missing credential with/without
  the tool installed, 429 → `rateLimited`, offline, HTTP error, unparseable body.
- **Security:** the credential type's `description` is redacted; the parse
  function lifts out nothing beyond what it needs; diagnostics contain no
  credential material; the cache round-trip contains no credential-shaped strings.

Use `StubHTTPClient` and the stub credential reader in
`Providers/Mock/MockUsageProvider.swift`. Tests must not require a real
credential, network access, a physical Touch Bar, or either CLI installed.

## Known private Touch Bar limitations

Read [`touchbar-research.md`](touchbar-research.md) in full. The parts that will
bite you:

- Only the `…SystemModalTouchBar…` selector spelling exists on macOS 26; the
  older `…FunctionBar…` spelling does not. Probing the wrong one silently reports
  "unsupported".
- `DFRGetKeyboardIsPresent` does not resolve; hardware detection uses
  `TouchBarServer` presence instead.
- Control Strip width is finite and is the binding constraint on two providers.
- Cleanup must stay idempotent, or a rebuild-and-relaunch cycle leaves duplicate
  tray items.
- Private API use rules out the Mac App Store and rules out sandboxing.

## Asset strategy

Only an original, code-drawn placeholder is committed. Branded artwork is loaded
from gitignored `LocalAssets/` at runtime if a developer supplies it. Apply the
same rule to any Codex/OpenAI artwork: do not commit it without verifying
redistribution terms. See [`branding.md`](branding.md).

## Security expectations

[`security-model.md`](security-model.md) is binding, not advisory. In particular:

- read only the credential field you actually need;
- do not use or refresh a refresh token — the parent tool owns auth lifecycle;
- never log, cache, or clipboard a token; the logger redacts by key and by value
  shape, so use its structured metadata API rather than string interpolation;
- add no field to `UsageSnapshot` capable of holding credential or account data;
- contact only the provider's own host;
- keep `diagnostics()` output safe to paste into a public issue.

Run `make audit` before committing.
