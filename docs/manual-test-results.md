# Manual test results

Physical Touch Bar behaviour cannot be verified in CI or by an automated agent.
This file records what was actually checked, by what means, and — importantly —
what is still outstanding.

**Nothing below is marked as passing unless it was genuinely observed.**

## Environment

- macOS 26.6.2 (25G83), arm64
- MacBook Pro `Mac14,7` (M2, 13-inch) — physical Touch Bar present
- Build: `swift build -c release` + `Scripts/make_app.sh`, ad-hoc signed
- Claude Code 2.1.62, authenticated

## Verified programmatically

These were confirmed from process state, unified logs, and the on-disk cache.

| Check | Result | Evidence |
| --- | --- | --- |
| All required private symbols resolve | **pass** | Runtime probe; see `touchbar-research.md` |
| App launches as background accessory, no Dock icon | **pass** | Process running, `LSUIElement` set |
| Control Strip item installs | **pass** | Log: `control strip item installed` |
| Claude credential read from Keychain | **pass** | Keychain prompt appeared and was approved |
| Live usage fetch succeeds | **pass** | Log: `usage refresh succeeded {provider=claude windows=3}` |
| Unknown response bucket tolerated | **pass** | Live response contained an unrecognised bucket; parsed to `.other`, no crash |
| Cache contains no credential material | **pass** | Cache file inspected: only percentages, reset times, labels |
| Idle CPU | **pass** | `0.0%` CPU |
| Memory footprint | **pass** | ~10–12 MB RSS |
| Clean teardown on SIGTERM | **pass** | Log: `control strip item removed`, `terminated cleanly` |
| Unit suite | **pass** | 82 tests, 0 failures |
| Secret/hygiene audit | **pass** | `make audit` |

### Live `/usage` comparison

The app fetched, at 2026-09-07 09:27 local:

- 5-hour: **26% used**, resets 2026-09-07 13:50 local
- Week: **15% used**, resets 2026-09-10 17:00 local

These come from the same OAuth endpoint Claude Code's own session uses, parsed
structurally — no screen scraping, no OCR.

> **Outstanding:** a side-by-side comparison against Claude Code's interactive
> `/usage` output at the same moment has **not** been performed. Run `/usage` in
> Claude Code and compare against the menu-bar figures to close this out.

## Physical Touch Bar checks

Performed by direct observation on the target Mac, macOS 26.6.2.

| # | Check | Result |
| --- | --- | --- |
| 1 | Widget visible after launch | **pass** (persistent modal strategy) |
| 2 | Persists across application switching | **pass** — confirmed while switching between apps |
| 3 | Tapping the widget opens the detail bar | **pass** |
| 4 | "Done" returns to compact mode | **pass** |
| 5 | Text fits at the rendered width on the real bar | **pass** |
| 6 | Mascot mark renders on the bar | **pass** (after the template-image fix) |
| 7 | Quitting removes the presentation cleanly | **pass** — logged `control strip item removed` / `terminated cleanly` |
| 8 | Relaunch produces no duplicate presentation | **pass** — repeated across ~10 rebuild/relaunch cycles |
| 9 | No flicker loop, no runaway CPU | **pass** — 0.0% CPU idle |
| 10 | Native volume/brightness/media coexist | **FAIL** — see below |

| 11 | Clawd renders on the bar, in colour | **pass** |
| 12 | Clawd pose follows usage severity | **pass** by construction; only `calm` observed live (real usage was 26% / 15%) |

### Check 10 — native controls are displaced

**This remains a genuine failure against the requirement, not a partial pass.**

A second, more thorough round of testing was done specifically to fix it. Two
real defects were found and corrected along the way — a non-nil
`systemTrayItemIdentifier` and an Auto Layout-only item view, either of which
makes a working API look broken — and every configuration was then re-tested with
both fixes in place:

| Mechanism | Displayed? | Native controls kept? |
| --- | --- | --- |
| Control Strip tray item, `fullControlStrip` mode | no | — |
| Control Strip tray item, `app` mode | no | — |
| Present modal then `minimizeSystemModalTouchBar:` | no | — |
| Modal, `placement 0`, `fullControlStrip` mode | no | yes |
| Modal, `placement 0`, `app` mode | **yes** | **no** |
| Modal, `placement 1`, either mode | **yes** | **no** |

There is no configuration on macOS 26.6.2 that shows the widget *and* keeps the
native controls: a system-modal bar is inherently full-width on this OS version,
and third-party Control Strip items are not rendered at all. Notably the exact
configuration the reference implementation documents as coexisting
(`placement: 0`, nil identifier, fixed-size view) **did not reproduce here** —
see [`touchbar-research.md`](touchbar-research.md) for the full analysis.

Shipped behaviour is `placement 1`, the only value that draws in every mode. The
menu bar's **Touch Bar: On/Off** toggle restores the native bar instantly. Fake
brightness/volume buttons were explicitly rejected rather than drawn.

### The user's Touch Bar setting

`PresentationModeGlobal` was temporarily switched to `app` during testing, with
permission, and **restored to the original `fullControlStrip`** afterwards. The
app works in either mode and reports the current one in Diagnostics.

### Not yet exercised

Stated plainly rather than assumed to pass:

| Check | Status |
| --- | --- |
| Behaviour while Xcode specifically is foreground | not separately verified |
| Manual refresh from the menu updating on-bar values | not verified |
| Wake-from-sleep refresh | not verified |
| Launch at Login registration from `/Applications` | not verified |
| Expanding / collapsing Apple's Control Strip alongside the widget | **not applicable** — the modal bar claims the full strip, so there is no native Control Strip on screen to expand while the widget is shown |
| Adjusting brightness / volume / mute with the widget shown | **not possible** — see check 10 |
| Clawd `alert` / `worried` / `panic` poses on the physical bar | not observed live; real usage stayed in the `calm` band. Verified via `make preview` renders instead |

### How to run these

```bash
make run     # launches dist/Touch Bar Usage.app
```

Quit from the menu bar item (not `kill`) so cleanup runs.

## Off-device UI verification

Compact and detail layouts were rendered to PNG via `make preview` and inspected
directly. Confirmed visually:

- compact normal: `[mark] Claude  5h 72%  W 43%` — full text fits, no clipping
- compact critical: `5h 97%!!` in red, `W 90%!` in orange — severity carries a
  glyph as well as colour
- compact stale: trailing `~` indicator present
- compact auth-required: `[mark] Claude  sign in`
- detail: `Claude · 5h 72% used resets in 2h 13m · Week 43% used resets Wed 11:25 AM ·
  Updated just now · [Done]`

A text-clipping defect was found this way (the weekly percentage was truncated to
`W`) and fixed before any device testing — which is the point of the preview path.

These renders confirm layout and content only. They are **not** a substitute for
seeing the widget on the physical bar — two defects found during device testing
were invisible to the preview path:

- a custom `NSView` in a Touch Bar item receives no touch events at all, so the
  widget rendered correctly but was inert until it became an `NSButton`;
- an `NSImage` built with `lockFocus` and `.clear` compositing rendered fine
  off-device but did not display as a template image on the bar;
- an Auto Layout-only item view previews correctly but collapses to zero width on
  the bar, which for a while made a *working* API look broken.

The four Clawd poses were verified through this path (`compact-normal`,
`-elevated`, `-warning`, `-critical`), since live usage never left the `calm`
band.

## Known open items

- **Native Touch Bar controls are displaced while the widget is shown** (check
  10). This is the significant open item. It is an OS-level constraint on macOS
  26.6.2, not a configuration mistake — but it is a real cost to the user, and
  the menu toggle is a workaround rather than a fix.
- A side-by-side comparison with Claude Code's interactive `/usage` has not been
  performed. Values come from the same OAuth endpoint Claude Code's own session
  uses and are parsed structurally, but the comparison itself remains unrun.
- Clawd's non-`calm` poses have not been seen on the physical bar, only in
  rendered previews, because live usage stayed below 60%.

**Resolved since the first pass:** the mascot is now Clawd rather than the
generic placeholder, fetched locally by `make assets` and rendered in his own
colours. The placeholder remains as the offline/no-Node fallback.
