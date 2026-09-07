# Branding and assets

## The legal boundary

Clawd is **Anthropic's character**. The upstream pose library this project reads
publishes no licence, which means all rights reserved. So:

> **Nothing in this repository is Clawd artwork, and nothing you could rebuild
> Clawd from is committed here.**

What *is* tracked is the code that fetches the pose data onto your own machine.
Generated output goes to a gitignored directory and is never redistributed. This
mirrors the approach taken by
[claude-usage-touchbar](https://github.com/tpklo/claude-usage-touchbar), which
established this boundary for the same character.

The project's own code remains MIT licensed; Anthropic's creative assets are
fetched at build time rather than embedded.

## Getting Clawd

```bash
make assets    # fetches pose data and generates local grids
make run       # build and launch with Clawd
```

`make assets` runs [`Scripts/fetch-clawd-assets.sh`](../Scripts/fetch-clawd-assets.sh),
which:

1. fetches the pose engine and selected pose pages from the upstream source;
2. evaluates them to resolve the 20×20 grids (the poses are built
   programmatically from `patch`/`shift` helpers, so they cannot simply be
   pattern-matched out of the text);
3. extracts the body and eye colours from the same source, so no Clawd colour
   value is written into this repository either;
4. writes `GeneratedAssets/Clawd/clawd-poses.json` — **gitignored**;
5. verifies the result (pose count, grid dimensions, cell values) before
   declaring success;
6. **fails gracefully**: if Node is missing, the network is down, or the upstream
   layout changes, it prints why, leaves any previously generated file alone, and
   exits 0 so the build is never blocked. The app then uses its own fallback mark.

### Build-time only

The app **never fetches at runtime**. It reads the generated file from disk once,
lazily, on first use. `make audit` enforces this: it fails if any networking API
appears in the mascot source files.

### Sandboxing the fetched code

The pose pages are JavaScript, and generating grids means executing them. The
generator runs them inside a Node `vm` context whose only global is a bare
`window` object — no `require`, no `process`, no filesystem access — so
build-time evaluation of third-party code cannot reach the rest of your machine.

## Mascot resolution order

1. `LocalAssets/claude-mascot.png` — your own image, if present (gitignored);
2. generated Clawd poses, if `make assets` has been run (gitignored);
3. the repository's own placeholder mark, drawn procedurally in
   [`MascotProvider.swift`](../Sources/TouchBarUsage/TouchBar/MascotProvider.swift).

Diagnostics reports which one is active, as `Mascot: …`.

The fallback is an original, deliberately generic rounded-square face. It exists
so a clean checkout builds and runs with no network and no licensing questions,
and it does not imitate any trademarked character.

## Poses follow real usage

Four poses map to the severity bands:

```
< 60% used     calm
60–84%         alert
85–94%         worried
>= 95%         panic
```

The pose **only ever reflects actual usage**. There is no demo or cycle mode: the
mascot is a second channel for the same information the percentages carry, and a
pose that did not match real usage would be misinformation. To see the other
poses without waiting for your quota to climb, run `make preview` and look at
`PreviewOutput/compact-*.png`.

Rendering is static. The mascot is redrawn only when the severity band changes —
there is no animation loop, and idle CPU stays at zero. If reactive animation is
added later it should stay event-driven and brief.

## Before adding any artwork to a public release

Do not commit third-party artwork — including Anthropic's — unless **all** of the
following are true:

1. the redistribution terms have actually been read, not assumed;
2. they permit redistribution in an MIT-licensed open-source project;
3. the attribution they require is recorded in `THIRD_PARTY_NOTICES.md`;
4. the use is not one that implies endorsement or affiliation.

"It was publicly accessible" satisfies none of these.

Studying how another project handles an interaction is fine. Copying its
animation frames, sprites, or artwork is not.

## Gitignore coverage

```
GeneratedAssets/
*clawd-poses.json
clawd_presets.h
LocalAssets/
.asset-cache/
*.clawd-src
```

`make audit` fails if any Clawd pose data or local asset becomes tracked.

---

Touch Bar Usage is an independent open-source project and is not affiliated with,
endorsed by, or sponsored by Anthropic. Clawd and Claude are Anthropic's; the
name and the character are theirs. The placeholder mark shipped in this
repository is original to this project and is not an Anthropic asset.
