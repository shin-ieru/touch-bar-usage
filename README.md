# Touch Bar Usage

**Claude Code and Codex usage, one tap away on your MacBook Pro Touch Bar.**

A lightweight native macOS utility that adds a compact Claude + Codex badge to
the Control Strip. Tap it to open a live usage dashboard, then close it to return
to your normal Touch Bar.

![Claude and Codex usage dashboard on the Touch Bar](docs/images/touchbar-dashboard.png)

Tap a provider for reset times and freshness:

![Claude detail with reset times](docs/images/touchbar-claude-detail.png)

At rest, only the small badge is there — your native controls are untouched:

![The compact Claude + Codex badge beside the native Control Strip](docs/images/touchbar-resting-badge.png)

*Real Touch Bar screenshots from a MacBook Pro (M2, 13-inch) running macOS 26.6.*

## What it does

- Shows **5-hour** and **weekly** quota for Claude Code and Codex, side by side.
- Percentages are **quota used**, not remaining — for both providers.
- Severity by glyph *and* colour, never colour alone: `!` at 85%, `!!` at 95%.
- Tap a provider for reset times, or read both from the menu bar instead.
- **Your Touch Bar stays normal.** Brightness, volume, media and per-app controls
  behave exactly as they always have; the dashboard is opened on demand.
- Once open, it **stays open** until you close it or the Mac sleeps. No timeout.
- If a provider doesn't report a 5-hour window, it says `5h — not reported`
  rather than showing a fabricated `0%`.

No analytics, no telemetry, no developer backend. See [Privacy & security](#privacy--security).

## Requirements

| | |
| --- | --- |
| Hardware | MacBook Pro with a **physical Touch Bar** |
| Architecture | **Apple Silicon tested**; Intel Touch Bar Macs not yet verified |
| macOS | 13 or later; **tested on macOS 26.6.2** |
| Touch Bar setting | **App Controls + Show Control Strip** (see below) |
| For Claude usage | Claude Code installed and signed in |
| For Codex usage | Codex installed and signed in |

Either provider works without the other. If Codex isn't installed, Claude carries
on and Codex reports `Not installed`.

Without a Touch Bar the app still runs and the menu bar shows everything.

## Install

### From a release build

1. Download `Touch-Bar-Usage-v0.1.0-macOS.zip` from the Releases page.
2. Verify the checksum against the published `.sha256`:
   ```bash
   shasum -a 256 Touch-Bar-Usage-v0.1.0-macOS.zip
   ```
3. Unzip and move **Touch Bar Usage.app** to `/Applications`.
4. **First launch:** the build is *not* notarized (see below), so macOS will
   refuse to open it by double-click. Right-click the app → **Open** → **Open**.
   You only need to do this once.

> **⚠️ Not signed with a Developer ID and not notarized.** v0.1.0 is ad-hoc
> signed only. Gatekeeper will warn you on first launch. If you would rather not
> accept that, **build from source** instead — it takes about a minute. Do not
> disable Gatekeeper system-wide to work around this.

Release builds ship with the project's own fallback mascot mark. The Clawd
artwork is not redistributable, so it is only available when you
[build from source](#build-from-source) and run `make assets`.

### From source

```bash
git clone <this-repo>
cd touch-bar-usage
make assets   # optional: fetches Clawd artwork onto your machine
make run
```

## macOS Touch Bar setup

The badge needs one specific setting:

```
System Settings → Keyboard → Touch Bar Settings
    Touch Bar shows:    App Controls
    Show Control Strip: On
```

> The combined Claude + Codex badge relies on the **App Controls + Show Control
> Strip** configuration. In other Touch Bar display modes macOS does not render
> the custom tray item at all. The menu-bar command remains available as a
> fallback in every mode.

## Usage

1. The badge sits in the Control Strip. It gains `!` at 85% and `!!` at 95%, so a
   provider nearing its limit is visible without opening anything.
2. Tap it — the dashboard opens and stays open.
3. Tap **Claude** or **Codex** for reset times; **‹ Back** returns.
4. **Close** — your native Touch Bar returns instantly.

Sleeping the Mac also closes the dashboard, so it can never come back as a stale
bar. Waking restores the normal Touch Bar and the badge, and does **not** reopen
the dashboard.

The menu bar (a gauge icon near the clock) mirrors both providers' figures and
offers **Show Usage on Touch Bar**, which works in every Touch Bar mode.

## Claude integration

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

## Codex integration

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

### Finding Codex

The app looks for the Codex CLI in the usual places — `PATH`, both Homebrew
prefixes, common user-local install directories, and the binary bundled inside
the OpenAI editor extensions. No single location is assumed, and newer versions
are preferred. Set `TBU_CODEX_PATH` to point at a specific build.

If none is found, Codex reports `Not installed` and Claude carries on unaffected.

## Privacy & security

Touch Bar Usage has no analytics, telemetry, ads, crash reporting, or developer
backend. There is no server component; there is nowhere for your data to go.

**Claude** — reads only `accessToken` and `expiresAt` from the Claude Code
keychain item, for one read-only usage request. The refresh token is never read
or used, the access token is never persisted or logged, and the keychain is never
modified.

**Codex** — talks to the local Codex App Server over stdio. It does **not** read
`~/.codex/auth.json`, never receives an OpenAI bearer token, and contacts no
OpenAI host.

Neither provider path reads your conversations, prompts, source files, browser
cookies, or terminal history. The on-disk cache holds only percentages, reset
times and labels.

Deeper detail: [`SECURITY.md`](SECURITY.md), [`PRIVACY.md`](PRIVACY.md),
[`docs/security-model.md`](docs/security-model.md).

## Private macOS APIs

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

## Development

```bash
make build         # compile (CONFIGURATION=debug for faster iteration)
make test          # 171 unit tests — no network, keychain, Codex or Touch Bar
make run           # build the .app bundle and launch it
make assets        # fetch Clawd artwork onto this machine (gitignored output)
make preview       # render PNG previews of every UI state to PreviewOutput/
make audit         # scan tracked files for secrets, artwork and machine paths
make build-release # Release-optimised build plus bundle
make package       # Release artifact + SHA-256 into dist/
make release-check # tests + audit + release build
make clean
```

`make assets` is optional. Without it the app uses its own fallback mark and
everything else works; the generated Clawd data is deliberately excluded from Git
*and* from release artifacts, because it is not ours to redistribute. See
[`docs/branding.md`](docs/branding.md).

Contributor guide: [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Troubleshooting

**Badge doesn't appear.** Check
`System Settings → Keyboard → Touch Bar Settings`: **Touch Bar shows** must be
**App Controls** and **Show Control Strip** must be **On**. Then quit and relaunch
Touch Bar Usage. In other modes macOS does not draw third-party Control Strip
items; use **Show Usage on Touch Bar** from the menu bar instead.

**Nothing on the Touch Bar at all.** Open Diagnostics from the menu bar. If
`Usage bar API: unsupported`, the private APIs are unavailable on your macOS
version. If `Touch Bar hardware: not detected`, your Mac has no physical Touch Bar.

**Touch Bar stopped working after a macOS update.** Likely a private-API change.
Use the menu-bar fallback and please open an issue with your macOS version and
the Diagnostics output.

**Branded mascot missing.** Release builds ship the fallback mark by design. Build
from source and run `make assets` for Clawd. The Codex mark resolves from an
OpenAI app already installed on your machine.

**Codex says `Not installed`.** Confirm Codex is installed and signed in
(`codex login`), then check Diagnostics. Set `TBU_CODEX_PATH` if it lives
somewhere unusual.

**Claude shows `sign in`.** Your Claude Code token is expired or missing. Run `claude` and
sign in; the widget picks it up on the next refresh (or use **Refresh Now**).

**Shows `keychain access denied` in Diagnostics.** You declined the keychain
prompt. Grant access to the `Claude Code-credentials` item in Keychain Access, or
delete the app's stored decision and relaunch.

**Shows `offline` or `refresh later`.** No network, or Anthropic rate-limited the
request. The app backs off automatically and keeps showing the last known values
with a `~`.

**Numbers look stale.** A trailing `~` means exactly that. Use **Refresh Now**;
there is a 60-second floor between fetches.

**Duplicate badge after a rebuild.** Quit from the menu bar rather than killing
the process, so cleanup runs. If one is stranded, log out and back in.

## Known limitations

- A **physical Touch Bar is required** for the badge and dashboard.
- The badge needs **App Controls + Show Control Strip**; other Touch Bar modes
  hide it. The menu-bar command works in all modes.
- Built on **undocumented private macOS APIs** — a macOS update may break the
  Touch Bar integration. It degrades to menu-bar-only rather than crashing.
- **Not notarized** in v0.1.0; Gatekeeper warns on first launch.
- **Intel Touch Bar Macs are unverified.** Apple Silicon only so far.
- Codex does not always report both windows; a missing 5-hour window is shown as
  `not reported`.
- The Claude usage endpoint is **undocumented** and may change upstream.
- Not distributed through the Mac App Store, and cannot be.

## Roadmap

```
Phase 1  —  Claude Code            ✓ done
Phase 2  —  OpenAI Codex           ✓ done
v0.1.0   —  first public release   ← you are here
Later    —  Developer ID signing + notarization
            Homebrew Cask
            additional usage providers if useful
```

Distribution is via GitHub releases and (later) a Homebrew Cask. **Not the Mac App
Store** — the Touch Bar presentation depends on private APIs, which disqualifies
it.

Adding a third provider should not require touching either existing one; see
[`docs/provider-contract.md`](docs/provider-contract.md).

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). In short: run `make test && make audit`
before opening a pull request, and never commit a credential, a real captured
response, or third-party artwork.

## License

MIT — see [`LICENSE`](LICENSE) and
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md). There are no third-party
dependencies.

---

**Touch Bar Usage is an independent open-source project and is not affiliated
with, endorsed by, or sponsored by Anthropic.** Claude and Anthropic are
trademarks of Anthropic PBC; Touch Bar and macOS are trademarks of Apple Inc.
