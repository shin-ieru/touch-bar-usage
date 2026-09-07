# System-wide Touch Bar research

How this project puts a widget on the Touch Bar that survives application
switching, what was measured on real hardware, and where it falls short.

Everything below was verified on **macOS 26.6.2 (25G83), arm64, MacBook Pro
`Mac14,7`** with a physical Touch Bar. Where an earlier revision of this document
drew a conclusion that later testing disproved, the correction is recorded rather
than quietly edited away.

## The problem

`NSTouchBar` is documented as belonging to the responder chain of the
**front-most application**. A background utility using only public API gets no
Touch Bar presence at all. Since staying visible while you work in Terminal, VS
Code or Xcode is the entire point of this app, the public API cannot express the
requirement.

macOS implements the Control Strip and system-modal bars through private
selectors on `NSTouchBar` / `NSTouchBarItem` plus `DFRFoundation`. Projects such
as [MTMR](https://github.com/Toxblh/MTMR),
[EnergyBar](https://github.com/billziss-gh/EnergyBar) and
[claude-usage-touchbar](https://github.com/tpklo/claude-usage-touchbar) establish
this pattern. No code was copied from them; the approach was re-implemented
narrowly in
[`SystemModalTouchBarBridge.swift`](../Sources/TouchBarUsage/TouchBar/SystemModalTouchBarBridge.swift),
which is the only file in the project aware of any of this.

## Symbol availability

Probed at runtime before implementation.

### `DFRFoundation` — loaded successfully

| Symbol | Result |
| --- | --- |
| `DFRElementSetControlStripPresenceForIdentifier` | **found** |
| `DFRSystemModalShowsCloseBoxWhenFrontMost` | **found** |
| `DFRSetStatus` | found (not used) |
| `DFRFoundationPostEventWithMouseActivity` | found (not used) |
| `DFRGetKeyboardIsPresent` | **missing** — do not rely on it |

Touch Bar hardware presence is therefore detected by the presence of
`/usr/libexec/TouchBarServer`, not by `DFRGetKeyboardIsPresent`.

### Private `NSTouchBar` / `NSTouchBarItem` class methods

| Selector | Result |
| --- | --- |
| `presentSystemModalTouchBar:placement:systemTrayItemIdentifier:` | **responds** |
| `dismissSystemModalTouchBar:` | **responds** |
| `minimizeSystemModalTouchBar:` | **responds** |
| `addSystemTrayItem:` | **responds** |
| `removeSystemTrayItem:` | **responds** |
| `presentSystemModalFunctionBar:placement:systemTrayItemIdentifier:` | no |
| `dismissSystemModalFunctionBar:` | no |

**Note for future maintainers:** older references and several existing projects
use the `…FunctionBar…` spelling, which was the name on macOS 10.12–10.13. On
macOS 26 only the `…TouchBar…` spelling exists. Code that probes only the
`FunctionBar` names will silently conclude the feature is unavailable.

## Two defects that made working configurations look broken

Both produced the same symptom — a widget that registers successfully, logs
success, and is never drawn — so they are worth knowing before concluding that an
API "does not work".

### 1. A non-nil `systemTrayItemIdentifier` with `placement: 0`

The first implementation always passed the app's own identifier:

```swift
fn(NSTouchBar.self, sel, bar, placement, identifier.rawValue as NSString)   // wrong
```

Supplying an identifier binds the modal bar to a **Control Strip tray item**, and
third-party tray items are not rendered on macOS 26 (see below) — so the widget
vanished. The typed function pointer must declare the parameter as optional so
nil can actually be passed:

```swift
typealias PresentSystemModal =
    @convention(c) (AnyObject, Selector, NSTouchBar, Int, NSString?) -> Void
fn(NSTouchBar.self, sel, bar, placement.rawValue, nil)                      // right
```

Fixing this changed observed behaviour: the native controls stopped being
displaced at `placement: 0`.

### 2. An Auto Layout-only item view collapses to zero width

A view installed in a Touch Bar item must carry a **concrete frame**. A view that
only has Auto Layout constraints and an `intrinsicContentSize` collapses and is
never drawn — again with no error anywhere. The reference implementation sets an
explicit `NSMakeRect(0, 0, 600, 30)` for this reason; this project wraps the
widget in `CompactSurfaceView`, a fixed-size surface with the content pinned to
its leading edge.

This defect invalidated the first round of Control Strip tray-item testing, which
is why those tests were re-run with a properly framed view before any conclusion
was drawn.

## Measured behaviour

### Control Strip tray item — does not render

```
NSTouchBarItem.addSystemTrayItem(item)
DFRElementSetControlStripPresenceForIdentifier(identifier, true)
```

Both calls succeed. Tested with a **concrete-frame** view in both Touch Bar
presentation modes:

| `PresentationModeGlobal` | Result |
| --- | --- |
| `fullControlStrip` | not drawn |
| `app` | not drawn |

Presenting the modal bar and then calling `minimizeSystemModalTouchBar:` — the
route that should collapse a modal bar into its tray item — makes the widget
disappear entirely rather than appearing beside the native controls, which is
consistent with the tray item not being rendered at all.

**Conclusion: third-party Control Strip items are not honoured on macOS 26.6.2.**
The code path remains, behind `TBU_TOUCHBAR_STRATEGY=controlStripItem`, so it can
be re-measured on a future release.

### System-modal bar — renders, but always full width

```
NSTouchBar.presentSystemModalTouchBar(bar, placement: N, systemTrayItemIdentifier: nil)
```

With a nil identifier and a concrete-frame view:

| `PresentationModeGlobal` | `placement: 0` | `placement: 1` |
| --- | --- | --- |
| `fullControlStrip` | **not drawn** (native controls kept) | drawn, **covers the bar** |
| `app` | drawn, **covers the native controls** | drawn, **covers the bar** |

There is no combination that draws the widget *and* keeps Apple's controls. A
system-modal touch bar is inherently a full-strip presentation on this OS
version; `placement` affects whether it is drawn in a given mode, not how much
width it claims.

`placement: 1` is the shipped default because it is the only value that draws in
every presentation mode.

### Divergence from the reference implementation

[claude-usage-touchbar](https://github.com/tpklo/claude-usage-touchbar) documents
`placement 0 shares the bar with the Control Strip; placement 1 covers it`, and
uses `placement: 0` with a nil identifier and a 600×30 view — the exact
configuration tested above. **That coexistence did not reproduce on macOS
26.6.2.** The likely explanation is an OS behaviour change since that project was
written; it is recorded here so the next person does not assume our
implementation is simply wrong.

## The architecture this forced (Phase 2)

The measurements above have a direct product consequence, and it is worth stating
plainly because it changed the design:

> Touch Bar Usage does not attempt to permanently combine a wide custom AI
> dashboard with all native Touch Bar controls. Instead it keeps macOS's normal
> Touch Bar as the resting state and presents the full usage dashboard only on
> demand.

Phase 1 kept a widget presented over the whole strip all day. Since a system-modal
bar is inherently full-width, that permanently displaced Apple's brightness,
volume, mute and media controls — a real cost paid every minute for information
glanced at occasionally.

Phase 2 inverts it:

| State | What owns the Touch Bar | Cost |
| --- | --- | --- |
| **Normal** (resting) | macOS — native controls, per-app bars | none |
| **Usage mode** (on demand) | our dashboard, full width | temporary |

Usage mode is entered from the menu bar, shows both providers, allows a detail
page per provider, and stays open until the user closes it. This is an
intentional reliability choice grounded in the target-hardware testing above, not
a limitation we stumbled into.

**There is no inactivity timeout.** An earlier version dismissed after 12
seconds, which meant the bar vanished while the user was still reading a reset
time. The only non-user event that closes usage mode is **system sleep**: a
system-modal bar left presented across a sleep/wake cycle risks returning as a
stale bar that cannot be dismissed, so it is torn down while the machine is still
awake. Waking restores the native bar and the tray badge, and never reopens the
dashboard.

Native controls are **not reimplemented**. Drawing fake brightness and volume
buttons was explicitly rejected: they would be a worse imitation of controls the
OS already owns, and they would be wrong the moment Apple changed anything.

## The Control Strip entry point — it works, in one specific mode

**Correction.** An earlier revision of this document concluded that third-party
Control Strip items "are not rendered on macOS 26.6.2". That was wrong, and the
error is worth recording because it was a sampling failure, not a measurement
failure: the conclusion was drawn from two presentation modes without testing the
third.

The tray item **does** render, with `Touch Bar shows` set to
**`appWithControlStrip`** (App Controls *with* the Control Strip shown):

| `PresentationModeGlobal` | Tray item rendered? |
| --- | --- |
| `fullControlStrip` | no |
| `app` | no |
| **`appWithControlStrip`** | **yes** |

Verified on hardware: the item appears in the compact Control Strip, is
tappable, opens the expanded dashboard, and survives quit and relaunch without
duplicating.

This is the shipped interaction model:

1. **Normal** — macOS owns the Touch Bar; we contribute one small badge.
2. **Usage mode** — tap the badge for the full Claude + Codex dashboard.
3. Close — or system sleep — returns the bar to macOS.

### Requirement

The tray badge needs **System Settings → Keyboard → Touch Bar shows → App
Controls**, with **Show Control Strip** enabled. In other modes the item is not
drawn, and the menu bar's "Show Usage on Touch Bar" is the way in. The menu bar
route works in every mode and is kept for exactly that reason.

The two earlier failures were real for their modes, so
`TBU_TOUCHBAR_STRATEGY=controlStripItem` and the placement override remain for
re-measuring on future releases.

### What still holds from the earlier testing

The two defects found along the way were genuine and their fixes stand: an Auto
Layout-only item view collapses to zero width and is never drawn, and a non-nil
`systemTrayItemIdentifier` binds a modal bar to a tray item. Both produce exactly
the same symptom as an unsupported API — a successful call and nothing on screen
— which is what made the wrong conclusion so easy to reach.

**Lesson for this codebase:** a private Touch Bar API returning success proves
nothing. Only the physical bar does, and it must be checked across presentation
modes before concluding anything is unsupported.

## The compact tray badge

The badge is a combined Claude + Codex mark rather than generic text, so the
entry point says *which* providers it covers.

- **Left:** Clawd's face. The full sprite is unreadable at tray size, so
  `ClawdPoseSet.headBoundingBox` crops to the face — top of the creature down to
  just below the eyes, with width taken from the **top row only** (measuring
  across lower rows includes the arms and yields a stepped anvil shape).
- **Right:** the Codex blossom.
- Both are drawn as alpha silhouettes and composed into a single **template**
  image, so the badge tints with the bar. Clawd's eyes are punched out as
  transparency rather than filled with their own near-black colour — filling them
  would flatten into the silhouette and produce a featureless blob.

### Sizing

The Control Strip slot has a fixed width that does not grow. A first attempt
sized Clawd generously and **pushed the blossom off the right edge on hardware**;
the badge is now capped at 44 pt of artwork (56 pt button) and the composite is
uniformly scaled down if it ever exceeds that.

### Fallback order

1. `LocalAssets/combined-tray-badge.png` — a developer's own badge;
2. composed Clawd + blossom, both resolved from installed software;
3. the repository's own drawn badge — a simple face beside a six-petal rosette,
   original artwork, what a clean checkout ships;
4. text, only if even that fails — which in practice it cannot, since it is drawn
   in code.

Tier 3 exists so the graphic path is *always* available; text is never the
default. `TrayBadgeResolution` holds the ordering and is unit tested.

## Touch input

A custom `NSView` inside a Touch Bar item is **visible but dead**: it receives
neither `NSClickGestureRecognizer` callbacks nor `mouseDown(with:)`. Both were
tried on the physical bar and neither fired.

The compact widget is therefore an `NSButton` with a target/action, which the
Touch Bar routes touches to natively. This is why
[`ClaudeCompactView`](../Sources/TouchBarUsage/TouchBar/ClaudeCompactView.swift)
subclasses `NSButton` rather than `NSView`.

## Image rendering

An `NSImage` built with `lockFocus()` and a `.clear` compositing punch-out
rendered correctly off-device but did **not** display as a template image on the
physical bar. Rebuilding it with `NSImage(size:flipped:drawingHandler:)` fixed
it. Off-device PNG previews are not sufficient to validate Touch Bar image
rendering.

Clawd is drawn cell-by-cell as whole-number rectangles with anti-aliasing and
interpolation disabled, so the pixel art stays sharp. Colours come from the
generated pose file; without them the image falls back to a tinted template.

## Escape key

The target Mac has a physical Escape key, so **no synthetic Escape item is
injected** and no Accessibility permission is requested. `make audit` enforces
both: it fails if `escapeKeyReplacementItemIdentifier` or any Accessibility /
Screen Recording / Input Monitoring API appears in tracked sources.

## Measured usable width

With the modal bar claiming the full strip, the custom surface is set to 420 pt
(`CompactSurfaceView.surfaceWidth`), with the widget itself capped at 300 pt and
degrading by dropping the "Claude" prefix before it will truncate a percentage.
At the shipped 13 pt monospaced-digit font, `Clawd  Claude  5h 72%  W 43%`
measures comfortably inside that budget, so the full form is what renders; the
condensed form exists for narrower future layouts (two providers, for example).

## Cleanup

`dismiss()` runs from `applicationWillTerminate` and from `SIGINT`/`SIGTERM`
handlers, and dismisses the detail bar, dismisses the compact bar, clears Control
Strip presence, and removes the tray item if one was registered. It is
idempotent, so overlapping termination paths cannot double-remove. This is what
prevents a stale or duplicated widget after a rebuild-and-relaunch cycle —
verified across roughly twenty cycles during this work.

## Limitations

- **Native controls are displaced while the widget is shown.** No configuration
  on macOS 26.6.2 avoids this.
- **Mac App Store distribution is not possible.** Private API use disqualifies
  the app, and the App Sandbox is incompatible with these APIs.
- **Any macOS update may break this.** Every symbol is resolved dynamically, so a
  removed API degrades to `isSupported == false` and a menu-bar-only app rather
  than a crash. Diagnostics reports which specific piece was unavailable.
- **No extra permissions are required.** No Accessibility, Screen Recording,
  Input Monitoring, Full Disk Access, or Automation. The only user-facing prompt
  is the standard keychain prompt for the single Claude Code credential item.
