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

The character mark shipped with this project is original, drawn procedurally in
[`MascotProvider.swift`](Sources/TouchBarUsage/TouchBar/MascotProvider.swift).
There is no bundled image file.

No Anthropic artwork is included. See [`docs/branding.md`](docs/branding.md) for
how to supply your own asset locally and what must be verified before any
third-party artwork is added to a public release.

## Trademarks

Claude and Anthropic are trademarks of Anthropic PBC. Touch Bar and macOS are
trademarks of Apple Inc. This project is independent and is not affiliated with,
endorsed by, or sponsored by either company. Trademarks are used only to describe
what the software interoperates with.
