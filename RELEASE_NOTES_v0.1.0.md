# Touch Bar Usage v0.1.0

First public release.

Claude Code and Codex usage, one tap away on your MacBook Pro Touch Bar.

## Highlights

- **Claude Code + Codex usage on the physical Touch Bar** — 5-hour and weekly
  quota for both providers, side by side.
- **Compact Claude + Codex badge** in the Control Strip. Your native brightness,
  volume, media and per-app controls stay exactly as they are.
- **Persistent on-demand dashboard** — tap the badge to open it; it stays open
  until you close it. No timeout.
- **Provider detail pages** with reset times and data freshness.
- **Native Touch Bar restored** on Close, and on sleep. Waking does not reopen
  the dashboard.
- **Menu bar mirror** — both providers' figures, a manual refresh, and
  Diagnostics, working in every Touch Bar mode.
- **No analytics, no telemetry, no developer backend.**

## Requirements

| | |
| --- | --- |
| Hardware | MacBook Pro with a **physical Touch Bar** |
| Architecture | **Apple Silicon tested**; Intel Touch Bar Macs not yet verified |
| macOS | 13 or later; tested on **macOS 26.6.2** |
| For Claude usage | Claude Code installed and signed in |
| For Codex usage | Codex installed and signed in |

Either provider works without the other.

## Important Touch Bar setting

The badge requires one specific configuration:

```
System Settings → Keyboard → Touch Bar Settings
    Touch Bar shows:    App Controls
    Show Control Strip: On
```

In other Touch Bar display modes macOS does not render third-party Control Strip
items at all, and the badge will not appear. **Show Usage on Touch Bar** in the
menu bar opens the same dashboard and works in every mode.

## Install

1. Download `Touch-Bar-Usage-v0.1.0-macOS.zip`.
2. Verify the checksum against the published `.sha256` file:
   ```bash
   shasum -a 256 Touch-Bar-Usage-v0.1.0-macOS.zip
   ```
3. Unzip and move **Touch Bar Usage.app** to `/Applications`.
4. Right-click the app → **Open** → **Open** on first launch (see below).

On first run macOS asks permission to read the Claude Code keychain item. That
prompt is the app reading your existing credential; approving it is what lets it
fetch Claude usage. No other permission is requested.

## Not signed or notarized

**This build is ad-hoc signed only.** There is no Apple Developer ID signature and
it has not been notarized, so Gatekeeper will block the first double-click. Use
right-click → **Open** once, or build from source instead:

```bash
make assets   # optional
make run
```

Please do not disable Gatekeeper system-wide to work around this. Developer ID
signing and notarization are on the roadmap.

## Security and privacy

- **Claude** — reads only `accessToken` and `expiresAt` from the Claude Code
  keychain item, for one read-only usage request. The refresh token is never read
  or used; the access token is never persisted or logged; the keychain is never
  modified.
- **Codex** — talks to the local Codex App Server over stdio. It does not read
  `~/.codex/auth.json`, never receives an OpenAI bearer token, and contacts no
  OpenAI host.
- Neither path reads conversations, prompts, source files, browser cookies, or
  terminal history.
- The on-disk cache holds only percentages, reset times and labels.

Details: `SECURITY.md`, `PRIVACY.md`, `docs/security-model.md`.

## Known limitations

- A **physical Touch Bar is required** for the badge and dashboard.
- The badge needs **App Controls + Show Control Strip**; other modes hide it.
- Built on **undocumented private macOS APIs**, because Apple provides no public
  API for a system-wide Touch Bar item. A macOS update may break the Touch Bar
  integration; it degrades to menu-bar-only rather than crashing.
- **Not notarized** — Gatekeeper warns on first launch.
- **Intel Touch Bar Macs are unverified.**
- Codex does not always report both windows. A missing 5-hour window is shown as
  `5h — not reported`, never as a fabricated `0%`.
- The Claude usage endpoint is **undocumented** and may change upstream.
- Release builds ship the project's own fallback mascot mark. Clawd artwork is not
  redistributable, so it is available only when building from source with
  `make assets`. The Codex mark resolves from an OpenAI app already installed on
  your machine.
- **Not on the Mac App Store**, and cannot be — private API use disqualifies it.

## Verified

Built and tested on a MacBook Pro (M2, 13-inch) running macOS 26.6.2, with
171 unit tests passing and a physical Touch Bar smoke test of the release build.
What was and was not verified on hardware is recorded in
`docs/manual-test-results.md`.

---

Touch Bar Usage is an independent open-source project and is not affiliated with,
endorsed by, or sponsored by Anthropic or OpenAI.

Claude and Anthropic are trademarks of Anthropic PBC; ChatGPT, Codex and OpenAI
are trademarks of OpenAI; Touch Bar and macOS are trademarks of Apple Inc. No
ownership or licence of any mark is claimed.
