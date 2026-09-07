# System-wide Touch Bar research

How this project puts a widget on the Touch Bar that survives application
switching, what was actually verified, and what the tradeoffs are.

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
narrowly in [`SystemModalTouchBarBridge.swift`](../Sources/TouchBarUsage/TouchBar/SystemModalTouchBarBridge.swift),
which is the only file in the project aware of any of this.

## Approach: what was tried, and what actually works

Three presentations were implemented and tested **on the physical bar**, because
the API return values turned out to be a poor guide to what is displayed.

| Strategy | Registration | Actually displayed? |
| --- | --- | --- |
| `controlStripItem` — tray item beside native controls | succeeds | **no** |
| `minimizedModal` — present modal, then minimise to tray | succeeds | **no** |
| `persistentModal` — present modal, leave presented | succeeds | **yes** |

### The Control Strip item does not render on macOS 26.6.2

The preferred design — section 7 of the brief asks for coexistence with the
native controls — is:

```
NSTouchBarItem.addSystemTrayItem(item)
DFRElementSetControlStripPresenceForIdentifier(identifier, true)
```

Both calls succeed. The selectors resolve, no error is raised, and the app logs a
successful install. **The item is never drawn.** This was checked with the
Touch Bar set to:

- `PresentationModeGlobal = fullControlStrip` (expanded Control Strip owns the
  whole bar) — not displayed;
- `PresentationModeGlobal = app` (app controls plus Control Strip) — not
  displayed, and no expand chevron was available to reveal it.

Presenting the modal and then calling `minimizeSystemModalTouchBar:` — the route
that should collapse a modal bar back into its tray item — makes the widget
disappear entirely rather than appearing beside the native controls, which is
consistent with the tray item not being rendered at all.

The conclusion is that third-party Control Strip items are no longer honoured on
this macOS version. Both strategies are retained in the code behind
`TBU_TOUCHBAR_STRATEGY` so they can be re-measured on a future release.

### What ships: persistent system modal

```
NSTouchBar.presentSystemModalTouchBar(bar, placement: 1, systemTrayItemIdentifier: id)
```

The `placement` argument is undocumented. Measured behaviour:

| Placement | Result |
| --- | --- |
| `0` | Native controls remain, **widget not displayed at all** |
| `1` | Widget displayed, **claims the full strip** |

There is no placement that shows the widget *and* keeps the native controls. The
choice is binary: visible or invisible. `1` is therefore the default, since an
invisible widget is not a product. Override with `TBU_TOUCHBAR_PLACEMENT`.

### The tradeoff, stated plainly

**While the widget is presented, the native volume, brightness and media controls
are not visible.** This is not the outcome section 7 asks for, and it is not
hidden behind optimistic wording: it is the least invasive presentation that
actually works on macOS 26.6.2.

The escape hatch is the menu bar's **Touch Bar: On/Off** toggle, which tears the
modal down and returns the bar to normal immediately, with no relaunch.

## Symbol availability — macOS 26.6.2, arm64

Probed at runtime before any implementation work. Results:

### `DFRFoundation` — loaded successfully

| Symbol | Result |
| --- | --- |
| `DFRElementSetControlStripPresenceForIdentifier` | **found** |
| `DFRSystemModalShowsCloseBoxWhenFrontMost` | **found** |
| `DFRSetStatus` | found (not used) |
| `DFRFoundationPostEventWithMouseActivity` | found (not used) |
| `DFRGetKeyboardIsPresent` | **missing** — do not rely on it |

Touch Bar hardware presence is therefore detected by other means (the presence of
`/usr/libexec/TouchBarServer`), not by `DFRGetKeyboardIsPresent`.

### Private `NSTouchBar` class methods

| Selector | Result |
| --- | --- |
| `presentSystemModalTouchBar:placement:systemTrayItemIdentifier:` | **responds** |
| `dismissSystemModalTouchBar:` | **responds** |
| `minimizeSystemModalTouchBar:` | **responds** |
| `presentSystemModalFunctionBar:placement:systemTrayItemIdentifier:` | no |
| `dismissSystemModalFunctionBar:` | no |

**Note for future maintainers:** older references and several existing projects
use the `…FunctionBar…` spelling, which was the name on macOS 10.12–10.13. On
macOS 26 only the `…TouchBar…` spelling exists. Code that probes only the
`FunctionBar` names will silently conclude the feature is unavailable.

### Private `NSTouchBarItem` class methods

| Selector | Result |
| --- | --- |
| `addSystemTrayItem:` | **responds** |
| `removeSystemTrayItem:` | **responds** |

## How the bridge fails safely

Every symbol is resolved dynamically — `dlsym` for the C functions,
`class_getClassMethod` for the selectors — and cached in `static let`s. If any
required piece is missing, `SystemModalTouchBarBridge.isSupported` is `false`,
the app skips Touch Bar installation entirely, runs as a menu-bar utility, and
Diagnostics reports which specific piece was unavailable. Nothing force-unwraps a
private symbol, so a future macOS release that removes one degrades the app
rather than crashing it.

Multi-argument private calls go through typed `@convention(c)` function pointers
obtained from `method_getImplementation`, because Swift's `perform(_:with:)` only
handles up to two object arguments and cannot pass the `NSInteger` placement.

## Cleanup

`teardown()` runs from `applicationWillTerminate` and from `SIGINT`/`SIGTERM`
handlers, and:

1. dismisses the modal bar if presented;
2. clears Control Strip presence for the identifier;
3. calls `removeSystemTrayItem:`.

It is idempotent, so termination paths that overlap cannot double-remove. This is
what prevents a stale or duplicated widget after a development rebuild-and-relaunch
cycle.

## Touch input

A custom `NSView` inside a Touch Bar item is **visible but dead**: it receives
neither `NSClickGestureRecognizer` callbacks nor `mouseDown(with:)`. Both were
tried on the physical bar and neither fired.

The compact widget is therefore an `NSButton` with a target/action, which the
Touch Bar routes touches to natively. This is why
[`ClaudeCompactView`](../Sources/TouchBarUsage/TouchBar/ClaudeCompactView.swift)
subclasses `NSButton` rather than `NSView`.

## Template images

An `NSImage` built with `lockFocus()` and a `.clear` compositing punch-out
rendered correctly off-device but did **not** display as a template image on the
physical bar. Rebuilding it with `NSImage(size:flipped:drawingHandler:)` and an
even-odd fill — so the face features are punched out of a single path rather than
composited away — fixed it. Off-device PNG previews are not sufficient to
validate Touch Bar image rendering.

## Verified behaviour

Verified on macOS 26.6.2 (`Mac14,7`), programmatically and by direct observation
of the physical bar:

- all required symbols resolve;
- the widget is displayed via the persistent modal strategy;
- **it persists across application switching** — the core requirement;
- tapping it opens the detail view, and "Done" returns to the compact widget;
- termination removes the presentation cleanly
  (`control strip item removed` / `terminated cleanly` are logged on SIGTERM);
- relaunch produces no duplicate presentation;
- the app runs as a background `.accessory` application with no Dock icon;
- idle cost: **0.0% CPU, ~10–12 MB RSS**.

Full results, including what remains unverified, are in
[`manual-test-results.md`](manual-test-results.md).

## Tradeoffs and limitations

- **Mac App Store distribution is not possible.** Private API use disqualifies
  the app, which is why the roadmap targets direct distribution only.
- **Any macOS update may break this.** The bridge degrades rather than crashes,
  but a future release could remove the Control Strip mechanism outright.
- **Native controls are displaced while the widget is shown.** See the tradeoff
  section above. The menu bar toggle turns the presentation off on demand.
- **Third-party Control Strip items are not rendered on macOS 26.6.2**, so the
  coexistence design is currently unreachable. The code for it remains.
- **Width is finite.** The widget caps itself at 300 pt and drops the "Claude"
  prefix before it would ever truncate a percentage.
- **No extra permissions are required.** The app requests no Accessibility, Screen
  Recording, Input Monitoring, Full Disk Access, or Automation permission. The
  only user-facing prompt is the standard keychain access prompt for the single
  Claude Code credential item.
- The target Mac has a physical Escape key, so no synthetic Escape item is added;
  the detail view provides an explicit "Done" button to return to compact mode.
