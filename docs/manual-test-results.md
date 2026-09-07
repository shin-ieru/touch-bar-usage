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
| Memory footprint | **pass** | ~10 MB RSS |
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

## Outstanding — requires a human at the machine

These are the checks in section 25 of the Phase 1 brief that need someone looking
at the physical bar. **None of them has been confirmed.** The app is running and
its Control Strip item is installed, so they can be walked through directly.

| # | Check | Status |
| --- | --- | --- |
| 1 | Widget visible in Control Strip after launch | not verified |
| 2 | Persists while Finder is foreground | not verified |
| 3 | Persists while Safari is foreground | not verified |
| 4 | Persists while Terminal is foreground | not verified |
| 5 | Persists while VS Code is foreground | not verified |
| 6 | Persists while Xcode is foreground | not verified |
| 7 | Survives rapid app switching without flicker | not verified |
| 8 | Native Control Strip expands correctly alongside it | not verified |
| 9 | Control Strip collapses correctly | not verified |
| 10 | Tapping the widget opens the detail bar | not verified |
| 11 | "Done" returns to compact mode | not verified |
| 12 | Manual refresh from the menu updates values | not verified |
| 13 | Quitting removes the widget cleanly | not verified |
| 14 | Relaunch produces no duplicate tray item | not verified |
| 15 | Text fits at the rendered width on the real bar | not verified |
| 16 | System volume/brightness/media controls still work | not verified |

### How to run these

```bash
make run                      # launches dist/Touch Bar Usage.app
```

Then work through the table above. To finish:

```bash
# Quit from the menu bar item, then confirm the widget is gone and relaunch:
make run
```

Record results here, replacing "not verified" with what actually happened.

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
seeing the widget on the physical bar.
