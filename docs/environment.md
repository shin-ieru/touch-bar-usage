# Development environment

Non-sensitive facts about the environment Phase 1 was developed and verified on,
recorded so a contributor can judge whether their setup should behave the same.

## Verified configuration

| Item | Value |
| --- | --- |
| macOS | 26.6.2 (build 25G83) |
| Architecture | arm64 (Apple silicon) |
| Hardware | MacBook Pro, `Mac14,7` (M2, 13-inch) — has a physical Touch Bar |
| Xcode | 26.6 (17F113) |
| Swift | 6.3.3 |
| Build system | Swift Package Manager (no `.xcodeproj` required) |
| Deployment target | macOS 13.0 |
| Claude Code | 2.1.62, native installer at `~/.local/bin/claude` |

## Touch Bar hardware

`Mac14,7` is one of the last Mac models shipped with a physical Touch Bar. The
presence of the bar can be confirmed by `/usr/libexec/TouchBarServer` and
`ControlStrip.app` running, both of which exist only on Touch Bar hardware.

The app runs on machines without a Touch Bar, but only the menu-bar half is
useful there; Diagnostics reports `Touch Bar hardware: not detected`.

## Private framework availability

On this configuration, `DFRFoundation.framework` is present at
`/System/Library/PrivateFrameworks/` and the symbols the app needs resolve. See
[`touchbar-research.md`](touchbar-research.md) for exactly which ones, and for
the ones that did **not** resolve.

## Why SwiftPM rather than an Xcode project

The suggested layout in the Phase 1 brief used `TouchBarUsage.xcodeproj`. A
Swift package was chosen instead because:

- `swift build` / `swift test` work identically from a terminal, an agent, and CI,
  with no GUI-only project settings to keep in sync;
- the pure-logic core is a separate target, so tests genuinely cannot reach
  AppKit, the keychain, or the network;
- there is no project file to generate merge conflicts.

The app bundle that macOS needs (for `LSUIElement`, bundle identity, and
`SMAppService`) is assembled by [`Scripts/make_app.sh`](../Scripts/make_app.sh).

## Reproducing

```bash
make test    # no network, keychain, Touch Bar or Claude Code required
make app     # assembles dist/Touch Bar Usage.app
make run     # assembles and launches it
```
