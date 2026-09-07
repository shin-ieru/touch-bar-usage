# Third-party notices

## Dependencies

**None.** Touch Bar Usage has no third-party runtime or build dependencies. It
uses only Apple frameworks shipped with macOS: AppKit, Foundation, Security,
ServiceManagement, and os.log.

`Package.resolved` is gitignored because there is nothing to resolve.

## Code

All source code in this repository is original to this project and MIT licensed.

No code was copied from another project. The technique for presenting a
persistent Touch Bar item is established by prior open-source work, and the
following projects were consulted **as references for which private APIs exist**,
not as sources of code:

- [MTMR](https://github.com/Toxblh/MTMR) — MIT
- [EnergyBar](https://github.com/billziss-gh/EnergyBar) — GPL-3.0
- [claude-usage-touchbar](https://github.com/tpklo/claude-usage-touchbar)

The implementation in
[`SystemModalTouchBarBridge.swift`](Sources/TouchBarUsage/TouchBar/SystemModalTouchBarBridge.swift)
was written independently against the runtime, and its symbol availability was
verified directly on macOS 26 rather than assumed from any of these projects. In
particular, this project uses the `…SystemModalTouchBar…` selector spelling, which
differs from the `…FunctionBar…` spelling several older implementations use.

EnergyBar is GPL-3.0. **No EnergyBar code is included**, which is what allows this
project to remain MIT licensed. If you contribute, do not copy GPL code into it.

## Artwork

The marks shipped with this project are original, drawn procedurally in
[`MascotProvider.swift`](Sources/TouchBarUsage/TouchBar/MascotProvider.swift) and
[`CombinedTrayBadgeResolver.swift`](Sources/TouchBarUsage/TouchBar/CombinedTrayBadgeResolver.swift).
There is no bundled artwork file.

**No Anthropic or OpenAI artwork is redistributed.** Clawd's pose data is fetched
onto the developer's own machine by `make assets` and is excluded from both Git
and release artifacts. The Codex mark is read at runtime from an OpenAI
application already installed on the user's machine. Neither ever travels with
this project. See [`docs/branding.md`](docs/branding.md).

### Documentation screenshots

`docs/images/` contains real Touch Bar screenshots used to show what the app looks
like. Because they are photographs of the running interface, the Clawd and OpenAI
marks are visible in them.

This is descriptive use — showing the product in operation — and is distinct from
redistributing the assets themselves: nothing in these images lets anyone
reconstruct the underlying artwork. **No claim is made that either mark is
licensed to this project.** If a rights holder objects, the screenshots will be
replaced with fallback-mark captures, which show the same functionality using
this project's own artwork.

## Trademarks

Claude and Anthropic are trademarks of Anthropic PBC. Touch Bar and macOS are
trademarks of Apple Inc. This project is independent and is not affiliated with,
endorsed by, or sponsored by either company. Trademarks are used only to describe
what the software interoperates with.
