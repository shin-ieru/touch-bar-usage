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

## Approach chosen: Control Strip item, not a full-bar takeover

Two presentations are possible:

1. **System-modal bar** — present an `NSTouchBar` over the whole strip.
2. **Control Strip item** — register a persistent item that lives *beside* the
   native controls.

This project uses (2) as its resting state, and (1) only transiently for the
expanded detail view. That keeps volume, brightness, media and Siri controls
working, which a full-bar takeover would displace. Section 7 of the Phase 1 brief
asks for the least invasive viable presentation; this is it.

Concretely:

```
NSTouchBarItem.addSystemTrayItem(item)                               // register
DFRElementSetControlStripPresenceForIdentifier(identifier, true)     // show it
```

and, when the user taps it:

```
NSTouchBar.presentSystemModalTouchBar(bar, placement: 1, systemTrayItemIdentifier: id)
```

Placement `1` puts the modal bar alongside the Control Strip rather than
replacing the entire bar.

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

## Verified behaviour

Verified programmatically on macOS 26.6.2 (`Mac14,7`):

- all required symbols resolve;
- `addSystemTrayItem:` and Control Strip presence both succeed
  (`control strip item installed` is logged);
- the app registers its item as a background `.accessory` application with no
  Dock icon;
- idle cost after the item is installed: **0.0% CPU, ~10 MB RSS**.

Visual and interaction checks that require a human looking at the physical bar
are recorded separately in [`manual-test-results.md`](manual-test-results.md) —
including which are still outstanding.

## Tradeoffs and limitations

- **Mac App Store distribution is not possible.** Private API use disqualifies
  the app, which is why the roadmap targets direct distribution only.
- **Any macOS update may break this.** The bridge degrades rather than crashes,
  but a future release could remove the Control Strip mechanism outright.
- **Control Strip width is finite.** The widget caps itself at 280 pt and drops
  the "Claude" prefix before it would ever truncate a percentage.
- **No extra permissions are required.** The app requests no Accessibility, Screen
  Recording, Input Monitoring, Full Disk Access, or Automation permission. The
  only user-facing prompt is the standard keychain access prompt for the single
  Claude Code credential item.
- The target Mac has a physical Escape key, so no synthetic Escape item is added;
  the detail view provides an explicit "Done" button to return to compact mode.
