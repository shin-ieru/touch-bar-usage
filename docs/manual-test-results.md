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

## v0.1.0 release (macOS 26.6.2)

Run against the **packaged Release artifact**, extracted from
`Touch-Bar-Usage-v0.1.0-macOS.zip` and launched from outside the build directory
— not the development build.

| # | Check | Result |
| --- | --- | --- |
| 1 | Release `.app` launches from a fresh extract | **pass** |
| 2 | Badge appears in the Control Strip | **pass** |
| 3 | Badge shows the **fallback** Claude mark | **pass** — intended; Clawd is not redistributable |
| 4 | Codex mark still renders | **pass** — resolved at runtime from the installed OpenAI app, so it survives packaging |
| 5 | Tap opens the Claude + Codex dashboard | **pass** |
| 6 | Claude detail opens, Back returns | **pass** |
| 7 | Codex detail opens, Back returns | **pass** |
| 8 | Close restores the native Touch Bar | **pass** |
| 9 | Brightness and volume work after Close | **pass** |
| 10 | Codex App Server connects, one child process | **pass** |
| 11 | Artifact contains no third-party artwork | **pass** — asserted by the packaging script and CI |
| 12 | Checksum verifies | **pass** — `shasum -a 256 -c` |

### Packaging and Gatekeeper

| Check | Result |
| --- | --- |
| `codesign --verify --strict` | **valid**, satisfies its designated requirement |
| Signature type | **ad-hoc** — `TeamIdentifier=not set` |
| Entitlements | **none** — nothing requested |
| `spctl -a` (Gatekeeper) | **rejected**, as expected for an unnotarized build |

### Verified from the published GitHub Release

Repeated after publication against the artifact **downloaded from the Release
page**, not the local `dist/` copy:

| Check | Result |
| --- | --- |
| Download from the Release page | **pass** |
| SHA-256 matches the published checksum | **pass** — `1063eb6f…5902e8d2` |
| Bundle contains only Info.plist, CodeResources and the binary | **pass** |
| No third-party artwork | **pass** |
| `CFBundleVersion` matches the release commit | **pass** — `5f45f84` |
| Launches from the downloaded copy | **pass** — tray item installed, Codex App Server connected, refresh succeeded, one child process |
| `spctl -a` | **rejected**, as expected for an unnotarized build |

**Still not reproduced: the browser-download quarantine prompt.** The download
was made with `curl`, which sets `com.apple.provenance` but not
`com.apple.quarantine`, so the first-launch dialog a browser user sees was never
triggered. The `spctl` rejection is the same assessment Gatekeeper applies, and
the documented right-click → **Open** flow is the standard remedy, but the exact
dialog has not been observed.

### Clean-clone verification

A fresh `git clone` of the repository was built from scratch:

| Check | Result |
| --- | --- |
| No branded assets in the checkout | **pass** |
| `make test` | **pass** — 171 tests |
| `make audit` | **pass** |
| `make package` | **pass** after the fix below |
| `make assets` then local build includes Clawd | **pass** |

**Defect found by this test:** `make_app.sh` used `swift build --show-bin-path` to
locate the binary but never built it, so it silently depended on a warm `.build`
directory. It worked in the development checkout and failed on a fresh clone.
Fixed by building before bundling.

### Not verified

| Check | Status |
| --- | --- |
| Quarantine / download-path Gatekeeper prompt | not reproduced — see above |
| Notarization | **not performed** — no Developer ID certificate on this machine |
| Intel Touch Bar Macs | no hardware available |
| Install into `/Applications` and Launch at Login | not exercised for the release build |

## Persistent usage mode (macOS 26.6.2)

Auto-dismiss was removed. Usage mode now stays open until the user closes it or
the Mac sleeps.

| # | Check | Result |
| --- | --- | --- |
| 1 | Dashboard stays open 60 s+ untouched (old timeout was 12 s) | **pass** |
| 2 | Claude detail stays open past the old threshold | **pass** |
| 3 | Codex detail stays open past the old threshold | **pass** |
| 4 | Survives switching Finder / Terminal / Safari / Xcode | **pass** |
| 5 | Provider refresh while open does not dismiss it | **pass** |
| 6 | Close restores the native Touch Bar immediately | **pass** |
| 7 | Badge still present after Close | **pass** |
| 8 | **Sleep while dashboard open → dismissed** | **pass** — verified by physically sleeping and waking the Mac |
| 9 | **Wake does not reopen the dashboard** | **pass** |
| 10 | Badge present after wake | **pass** |
| 11 | No stale or ghost bar after wake | **pass** |

Sleep/wake was performed on the actual machine, not simulated.

### What was removed

`dismissTimer`, `autoDismissInterval` (12 s), `restartDismissTimer()`,
`autoDismiss()`, `stopDismissTimer()`, and the `onInteraction` callbacks that
existed only to reset the deadline. The interactions themselves — tap a provider,
Back, Close — are unchanged.

Timers deliberately kept: the 30 s countdown tick while a detail page is visible,
the 300 s provider refresh, provider backoff, and the RPC timeout. None of them
can dismiss usage mode.

`make audit` now fails if `autoDismiss`, `dismissTimer`, `idleTimer`,
`inactivityTimer` or `lastInteraction` reappears in non-comment source.

### Not verified

| Check | Status |
| --- | --- |
| Multi-hour persistence | not verified — checked to a few minutes, not left open all day |
| Tray badge re-installation after wake | not exercised — the badge survived the sleep cycle, so the reinstall path never ran |
| Sleep while a *detail* page is open (rather than the dashboard) | not verified — sleep was tested from the dashboard; covered by unit tests |

## Combined tray badge patch (macOS 26.6.2)

### The Phase 2 conclusion was wrong, and this corrects it

Phase 2 recorded that third-party Control Strip items "are not rendered on
macOS 26.6.2". **They are** — with `Touch Bar shows` set to
`appWithControlStrip`, which was the one presentation mode never tested. The
earlier `fullControlStrip` and `app` results were accurate for those modes; the
generalisation from them was not.

| Check | Result |
| --- | --- |
| Tray item renders in `appWithControlStrip` | **pass** — confirmed on hardware |
| Tray item is tappable and opens the dashboard | **pass** |
| Tray item renders in `fullControlStrip` / `app` | fail — unchanged from Phase 2 |

### Badge

| # | Check | Result |
| --- | --- | --- |
| 1 | Badge visible in the compact Control Strip | **pass** |
| 2 | Reads as Claude + Codex, both marks legible | **pass** |
| 3 | Not blurry | **pass** — pixel art drawn at whole-cell sizes, interpolation off |
| 4 | No dark-square or blob artifact | **pass** — Clawd's eyes punched out as transparency |
| 5 | Nothing clipped | **pass** — after the fix below |
| 6 | Tapping the badge opens the dashboard | **pass** |
| 7 | Close restores the native Touch Bar | **pass** |
| 8 | Auto-dismiss restores the native Touch Bar | **pass at the time** — auto-dismiss has since been removed; see the persistent usage mode section above |
| 9 | Badge still present after dismissal | **pass** |
| 10 | Quit and relaunch leaves no duplicate | **pass** |

### Defect found on hardware

The first attempt sized Clawd's face generously, producing a 71 pt button. The
Control Strip slot does not grow to fit, so **the Codex blossom was clipped off
the right edge** — visible only on the device; the off-device preview renders the
button at its requested size and showed both marks fine.

Fixed by shrinking the marks to a 56 pt button and adding a hard 44 pt cap on
artwork width, which uniformly scales the composite down rather than letting
either mark run off the edge.

### Not verified

| Check | Status |
| --- | --- |
| Fallback badge (tier 3) on hardware | not verified — the composed badge resolved, so the drawn fallback never rendered on the bar. Covered by unit tests and off-device previews |
| Local override badge (tier 1) on hardware | not verified — no `LocalAssets/combined-tray-badge.png` on this machine |
| Badge appearance on a non-OLED / older Touch Bar | not applicable to this hardware |

## Phase 2 — revised architecture (macOS 26.6.2)

The Touch Bar model changed in Phase 2: macOS keeps its own Touch Bar as the
resting state, and the usage dashboard is presented on demand. These are the
checks for that architecture, performed by direct observation on the target Mac.

| # | Check | Result |
| --- | --- | --- |
| 1 | Native Touch Bar behaviour preserved at rest | **pass** |
| 2 | Brightness and volume work normally | **pass** |
| 3 | Native bar survives switching Finder/Safari/Terminal/Xcode | **pass** |
| 4 | Small Control Strip tray entry point | **FAIL at the time** in `fullControlStrip` / `app` — later **passed** in `appWithControlStrip`; see the badge section above |
| 5 | Usage mode opens from the menu bar | **pass** |
| 6 | Both providers visible and fit, nothing clipped | **pass** |
| 7 | Clawd renders on the Claude chip | **pass** |
| 8 | Codex mark renders on the Codex chip | **pass** (after the template fix below) |
| 9 | Tapping a provider opens its detail page | **pass** |
| 10 | Detail page shows that provider's own numbers | **pass** — Codex detail verified |
| 11 | Back returns to the dashboard | **pass** |
| 12 | Close restores the native Touch Bar immediately | **pass** |
| 13 | Auto-dismiss (~12s) restores the native bar | **pass at the time** — behaviour later removed deliberately |
| 14 | Quit tears down cleanly | **pass** — `touch bar presentation torn down` / `terminated cleanly` |
| 15 | No orphaned Codex child process | **pass** — `codex app-server` count 1 → 0 → 1 across quit/relaunch |
| 16 | Relaunch leaves no duplicate | **pass** |
| 17 | Idle CPU | **pass** — 0.0% |

### Check 4 — the Control Strip entry point does not render

The intended design was a small persistent "AI" item on the Touch Bar itself.
`addSystemTrayItem:` and `DFRElementSetControlStripPresenceForIdentifier` both
succeed and the app logs a successful install, but **nothing is drawn**.

Across Phase 1 and Phase 2 this was tested with an Auto Layout-only view (a
genuine bug, fixed), a concrete-frame view at 200 pt, a concrete-frame view at
**64 pt** sized for the narrow slot, in both `fullControlStrip` and `app`
presentation modes, and via present-then-minimise. None renders.

**Consequence:** the menu bar is the entry point — always specified as the
fallback, now the primary route. To compensate, the menu bar icon reflects the
worst severity across providers and appends `!` / `!!`, so a provider hitting its
limit is visible without opening anything.

### Defects found only on hardware

- The Codex mark first rendered as a **solid black square**: the bundled
  `blossom.dark.png` is an opaque tile, and templating it paints the whole
  rectangle. Fixed by preferring the transparent SVG glyphs and only templating
  vector sources.
- The menu item did nothing when clicked: `rebuild()` ran from `menuWillOpen` and
  called `removeAllItems()`, destroying the items macOS was displaying, so clicks
  landed on items that no longer existed. Fixed by mutating titles in place on
  open and rebuilding only after close. This also explains the identical Phase 1
  symptom with the pose-preview item.

### Not verified in Phase 2

| Check | Status |
| --- | --- |
| Codex signed-out / not-installed states on hardware | not verified live — Codex stayed signed in throughout. Covered by tests and by `TBU_FORCE_CODEX` renders |
| App server crash-and-recover on hardware | not verified live; covered by transport tests |
| Wake-from-sleep refresh | not verified |
| Launch at Login from `/Applications` | not verified |
| Live comparison against Codex's own usage UI | not performed |

## Phase 1 — physical Touch Bar checks

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
| 12 | Clawd `calm` pose at normal usage | **pass** — observed live at 26% / 15% |
| 13 | Clawd `alert` pose at elevated usage | **pass** — observed live when 5h reached 75% |
| 14 | Clawd `worried` pose at warning usage | **pass** — via `TBU_FORCE_SEVERITY=warning`; wide eyes, visibly distinct |
| 15 | Clawd `panic` pose at critical usage | **pass** — via `TBU_FORCE_SEVERITY=critical`; shock lines visible |
| 16 | Severity colours and glyphs on the bar | **pass** — `5h 97%!!` red, `W 90%!` orange |

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
| `worried` / `panic` poses reached by *real* quota | not observed — real usage never exceeded 75%. Verified on the bar via `TBU_FORCE_SEVERITY` instead, which pins percentages and pose together |

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
- Clawd's `worried` and `panic` poses were verified on the bar through a pinned
  state rather than by real quota reaching 85% / 95%. The rendering path is
  identical either way, but the thresholds themselves have not fired naturally.

**Resolved since the first pass:** the mascot is now Clawd rather than the
generic placeholder, fetched locally by `make assets` and rendered in his own
colours. The placeholder remains as the offline/no-Node fallback.
