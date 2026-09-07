# Touch Bar Usage

Claude Code usage, directly on your MacBook Pro Touch Bar.

Touch Bar Usage is a lightweight native macOS utility that keeps your Claude
usage limits visible while you work, without opening `/usage` every time.

```
┌──────────────────────────────────────────────────────────────┐
│ [mark] Claude  5h 72%  W 43%                [system controls]│
└──────────────────────────────────────────────────────────────┘
```

It stays visible while you switch between Terminal, VS Code, Xcode, Safari or
anything else.

> **⚠️ Tradeoff you should know before installing.** On macOS 26 the only way to
> keep a third-party widget on the Touch Bar is a system-modal bar that claims the
> whole strip, so **the native volume, brightness and media controls are hidden
> while the widget is shown.** Coexisting with them was the intended design, but
> third-party Control Strip items are no longer rendered on this OS version —
> the measurements are in [`docs/touchbar-research.md`](docs/touchbar-research.md).
> The menu bar's **Touch Bar: On/Off** toggle restores the native bar instantly.

## Project status

**Phase 1 — early development.** Claude Code support only. Codex is not
implemented; see the roadmap.

The Touch Bar bridge, the Claude provider, the caching and refresh layer, and the
test suite are complete and working against live data. The widget has been
verified on physical hardware: it displays, persists across application
switching, expands on tap, and tears down cleanly.

Known limitations are recorded honestly in
[`docs/manual-test-results.md`](docs/manual-test-results.md) — in particular the
displaced native controls above, and the fact that the shipped mascot is an
original placeholder rather than Claude's character.

## What it displays

**Compact** (Control Strip, always visible):

```
[mark] Claude  5h 72%  W 43%
```

Percentages are **quota used**, not remaining. Under width pressure the widget
drops the "Claude" prefix before it will ever truncate a number.

**Detail** (tap the widget):

```
Claude   5h  72% used  resets in 2h 13m   Week  43% used  resets Wed 11:25 AM
         Updated just now                                            [ Done ]
```

Per-model weekly caps, when Anthropic returns them, appear here rather than
cluttering the compact bar.

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

- **A MacBook Pro with a physical Touch Bar.** Without one the app still runs, but
  only the menu-bar half is useful.
- macOS 13 or later. Developed and verified on **macOS 26.6.2** (arm64,
  `Mac14,7`).
- Xcode 26 / Swift 6.3 to build.
- **Claude Code installed and signed in.** This app reads the credential Claude
  Code already stores; it never asks you for a token.

## Build from source

```bash
git clone <this-repo>
cd touch-bar-usage

make test    # 82 unit tests — no network, keychain, or Touch Bar needed
make run     # builds dist/Touch Bar Usage.app and launches it
```

Other targets:

```bash
make build     # compile
make app       # assemble the .app bundle only
make preview   # render PNG previews of every UI state to PreviewOutput/
make audit     # scan tracked files for secrets and machine-specific paths
make clean
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

## Mascot asset

The repository ships an **original placeholder mark** drawn in code — not
Anthropic's artwork, whose redistribution terms have not been verified. To use
your own image locally:

```bash
cp your-image.png LocalAssets/claude-mascot.png
make run
```

`LocalAssets/` is gitignored, so it cannot be committed by accident. See
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
Phase 1  —  Claude Code            ← you are here
Phase 2  —  OpenAI Codex
Later    —  additional usage providers if useful
```

Codex support does **not** exist yet. The provider abstraction was built to accept
it; see [`docs/codex-handoff.md`](docs/codex-handoff.md) and
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
