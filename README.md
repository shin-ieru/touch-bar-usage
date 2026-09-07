# Touch Bar Usage

Claude Code and Codex usage, one tap away on your MacBook Pro Touch Bar.

Touch Bar Usage is a lightweight native macOS utility that keeps your AI coding
quota a click away. **Your Touch Bar stays normal** — brightness, volume, media
and per-app controls all behave exactly as they always have. Open the usage
dashboard when you want it, and it gets out of the way again.

```
Normal (resting)   ── macOS owns the Touch Bar, nothing displaced ──

Usage mode         ┌──────────────────────────────────────────────────────┐
(on demand)        │ [Clawd] Claude 5h72 W43   [◍] Codex 5h84 W51  [Close]│
                   └──────────────────────────────────────────────────────┘
```

Tap a provider for its detail page; close it, or leave it ~12 seconds, and macOS
gets its Touch Bar straight back.

> **Why on demand?** On macOS 26 a third-party Touch Bar surface is inherently
> full-width, and third-party Control Strip items are not rendered at all. Keeping
> a dashboard permanently visible therefore means permanently displacing Apple's
> controls — a real cost paid all day for information glanced at occasionally.
> So the dashboard is deliberately temporary. The measurements behind that
> decision are in [`docs/touchbar-research.md`](docs/touchbar-research.md).

## Project status

**Phase 2 — early development.** Claude Code and OpenAI Codex are both supported.

Verified on physical Touch Bar hardware: the native bar is preserved, the
dashboard opens and closes cleanly, both providers render with their own icons,
detail pages work, and auto-dismiss restores the native bar.

Known limitations are recorded honestly in
[`docs/manual-test-results.md`](docs/manual-test-results.md) — in particular that
the Touch Bar entry point had to move to the menu bar.

## How you use it

1. The app lives in the **menu bar** (a small gauge icon, next to the clock). Its
   icon shows the worst severity across both providers, so a provider hitting its
   limit is visible without opening anything.
2. Choose **Show Usage on Touch Bar** (or press ⌘U with the menu open).
3. The dashboard appears on the Touch Bar. Tap **Claude** or **Codex** for detail.
4. **Close**, or wait ~12 seconds — macOS gets its Touch Bar back.

The menu itself also lists both providers' figures, so you never *have* to use the
Touch Bar at all.

## What it displays

**Dashboard** (usage mode):

```
[Clawd] Claude  5h 72%  W 43%     [◍] Codex  5h 84%  W 51%     [Close]
```

Percentages are **quota used**, not remaining — for both providers. Under width
pressure a chip drops its provider name before it will ever truncate a number.

**Detail** (tap a provider):

```
‹ Back   [Clawd] Claude   5h  72% used  resets in 2h 13m
                          Week 43% used  resets Wed 11:25 AM
         Updated just now                                   [ Close ]
```

Per-model weekly caps, when Anthropic returns them, appear here rather than
cluttering the dashboard.

If a provider doesn't report a 5-hour window, it says so — `5h — not reported` —
rather than showing a fabricated `0%`.

**Severity** is shown by glyph *and* colour, never colour alone:

| Used | State | Indicator |
| --- | --- | --- |
| 0–59% | normal | — |
| 60–84% | elevated | — |
| 85–94% | warning | `!` + orange |
| 95–100% | critical | `!!` + red |

**Other states:** `loading…`, `sign in`, `refresh later` (rate limited),
`offline`, and a trailing `~` when data is cached and could not be refreshed.

## Requirements

- **A MacBook Pro with a physical Touch Bar** for the dashboard. Without one the
  app still runs and the menu bar shows everything.
- macOS 13 or later. Developed and verified on **macOS 26.6.2** (arm64,
  `Mac14,7`).
- Xcode 26 / Swift 6.3 to build.
- **Claude Code installed and signed in**, for Claude usage. This app reads the
  credential Claude Code already stores; it never asks you for a token.
- **Codex installed and signed in**, for Codex usage. This app never sees an
  OpenAI token at all — see below.

Either provider works without the other. If Codex isn't installed, Claude carries
on and Codex simply reports "not found".

## Build from source

```bash
git clone <this-repo>
cd touch-bar-usage

make assets  # fetch Clawd pose data onto your machine (optional but recommended)
make test    # 149 unit tests — no network, keychain, Codex or Touch Bar needed
make run     # builds dist/Touch Bar Usage.app and launches it
```

`make assets` is what gets you Clawd. Skip it and the app still builds and runs,
using its own placeholder mark instead — see [Mascot](#mascot).

Other targets:

```bash
make build     # compile
make app       # assemble the .app bundle only
make assets    # fetch Clawd pose data locally (gitignored output)
make preview   # render PNG previews of every UI state to PreviewOutput/
make audit     # scan tracked files for secrets, artwork and machine-specific paths
make clean     # build products only; generated Clawd assets are kept
```

On first launch macOS asks permission to read the Claude Code keychain item.
That prompt is the app reading your existing credential; approving it is what
lets it fetch usage. The app requests no other permission.

To keep it running, use **Launch at Login** in the menu. macOS registers login
items only for apps in a standard location, so move
`dist/Touch Bar Usage.app` to `/Applications` first.

## How Claude usage is obtained

The app reads the access token Claude Code already stores in your macOS Keychain
and makes one read-only request:

```
GET https://api.anthropic.com/api/oauth/usage
```

> **⚠️ This endpoint is undocumented.** It is what Claude Code's own OAuth
> session uses, not a published public API. It may change shape or disappear
> without notice. The parser is written defensively as a result — the live
> response already contains a bucket this project does not recognise, which it
> keeps rather than choking on. If Anthropic publishes a supported mechanism, this
> should move to it.

No prompt is ever sent. No inference is performed. No conversation is read.

### Security and Keychain

The app reads exactly two values from the `Claude Code-credentials` keychain
item — `claudeAiOauth.accessToken` and `claudeAiOauth.expiresAt` — and nothing
else. In particular:

- the **refresh token is never read or used**; Claude Code owns your
  authentication lifecycle, and this app never modifies your keychain;
- the access token exists only for the duration of one request — never written to
  disk, the cache, the clipboard, or any log;
- the cache stores only percentages, reset times and labels; the type written to
  it has no field capable of holding a credential;
- the only host ever contacted is `api.anthropic.com`.

If your token expires, the widget shows `sign in` and the menu tells you to
re-authenticate in Claude Code. It will not do that for you, by design.

Full detail: [`SECURITY.md`](SECURITY.md) and
[`docs/security-model.md`](docs/security-model.md).

## How Codex usage is obtained

Through the **local Codex App Server** — no OpenAI credential ever reaches this
app:

```
Touch Bar Usage  ──local stdio JSON-RPC──▶  Codex App Server  ──▶  OpenAI
```

The app launches `codex app-server`, completes the standard handshake, and calls
`account/rateLimits/read`. That's it. Specifically it does **not**:

- read `~/.codex/auth.json` or any OpenAI token;
- contact `api.openai.com` or any OpenAI host;
- call anything that spends your rate-limit reset credits or emails you;
- start threads, send prompts, or read conversations.

The App Server — which you already installed and logged into — owns
authentication and makes the network call itself. `make audit` fails the build if
a credential path or OpenAI endpoint ever appears in the source.

Message shapes come from the app server's own generated schema
(`codex app-server generate-json-schema`), not guesswork. Details:
[`docs/codex-integration.md`](docs/codex-integration.md).

## Privacy

No telemetry, no analytics, no crash reporting, no ads, and **no developer
backend of any kind**. See [`PRIVACY.md`](PRIVACY.md).

## System-wide Touch Bar and private APIs

A normal `NSTouchBar` belongs to the front-most app, which cannot express "stay
visible while I work elsewhere". This app therefore uses private macOS APIs
(`DFRFoundation` plus private `NSTouchBar` selectors), confined entirely to
[`SystemModalTouchBarBridge.swift`](Sources/TouchBarUsage/TouchBar/SystemModalTouchBarBridge.swift).

Consequences you should know about:

- **This app is not, and cannot be, on the Mac App Store.**
- It is not sandboxed — the App Sandbox is incompatible with these APIs.
- A macOS update could break the Touch Bar feature. Every private symbol is
  resolved dynamically, so the app degrades to menu-bar-only rather than crashing,
  and Diagnostics reports exactly which piece went missing.

Findings, including which symbols exist on macOS 26 and which do not, are in
[`docs/touchbar-research.md`](docs/touchbar-research.md).

## Mascot

Clawd rides along beside the numbers, and his pose follows your actual usage:

```
< 60% used     calm          85–94%      worried
60–84%         alert         >= 95%      panic
```

The pose only ever reflects real usage — there is no demo mode, because a pose
that did not match your quota would be misinformation. To see all four, run
`make preview` and open `PreviewOutput/compact-*.png`.

### Getting Clawd

```bash
make assets
```

**Clawd is Anthropic's character, and the upstream pose library publishes no
licence — so this repository contains none of that artwork.** `make assets`
fetches the pose data onto *your* machine and writes it to a gitignored
directory; the project's own code stays MIT. The app never fetches at runtime.

If you skip `make assets` (or it fails, or you are offline), the app falls back
to an original placeholder mark drawn in code, so a clean checkout always builds
and runs. Diagnostics shows which is active.

### Using your own image instead

```bash
cp your-image.png LocalAssets/claude-mascot.png
make run
```

`LocalAssets/` is gitignored too, so it cannot be committed by accident. Full
rationale and the licensing rules for contributors are in
[`docs/branding.md`](docs/branding.md).

## Troubleshooting

**Widget doesn't appear.** Open Diagnostics from the menu bar. If
`System modal bridge: unsupported`, the private APIs this depends on are not
available on your macOS version. If `Touch Bar hardware: not detected`, your Mac
has no physical Touch Bar.

**I want my native controls back.** Use **Touch Bar: Off** in the menu. It tears
the presentation down immediately; switch it back on when you want the widget.

**Can I have both at once?** Not on macOS 26 — see the warning at the top. If a
future macOS restores third-party Control Strip items, set
`TBU_TOUCHBAR_STRATEGY=controlStripItem` to re-test the coexistence path, which
is still in the code.

**Shows `sign in`.** Your Claude Code token is expired or missing. Run `claude` and
sign in; the widget picks it up on the next refresh (or use **Refresh Now**).

**Shows `keychain access denied` in Diagnostics.** You declined the keychain
prompt. Grant access to the `Claude Code-credentials` item in Keychain Access, or
delete the app's stored decision and relaunch.

**Shows `offline` or `refresh later`.** No network, or Anthropic rate-limited the
request. The app backs off automatically and keeps showing the last known values
with a `~`.

**Numbers look stale.** A trailing `~` means exactly that. Use **Refresh Now**;
there is a 60-second floor between fetches.

**Duplicate widget after a rebuild.** Quit from the menu bar rather than killing
the process, so cleanup runs. If one is stranded, log out and back in.

## Roadmap

```
Phase 1  —  Claude Code            ✓ done
Phase 2  —  OpenAI Codex           ← you are here
Later    —  release hardening (signing, notarization, Homebrew Cask)
            additional usage providers if useful
```

Distribution is via GitHub releases and (later) a Homebrew Cask. **Not the Mac App
Store** — the Touch Bar presentation depends on private APIs, which disqualifies
it.

Adding a third provider should not require touching either existing one; see
[`docs/provider-contract.md`](docs/provider-contract.md).

## Contributing

Read [`docs/provider-contract.md`](docs/provider-contract.md) before adding a
provider, and run `make test && make audit` before opening a pull request. Never
commit a credential, a real captured response, or third-party artwork.

## License

MIT — see [`LICENSE`](LICENSE) and
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md). There are no third-party
dependencies.

---

**Touch Bar Usage is an independent open-source project and is not affiliated
with, endorsed by, or sponsored by Anthropic.** Claude and Anthropic are
trademarks of Anthropic PBC; Touch Bar and macOS are trademarks of Apple Inc.
