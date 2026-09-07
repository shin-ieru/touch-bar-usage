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

## The compact tray badge

The Touch Bar entry point uses a **combined Claude + Codex mark** — Clawd's face
beside the Codex blossom — so it reads as "these two providers" rather than a
generic label.

It has its own pipeline (`CombinedTrayBadgeResolver`) rather than reusing the
dashboard artwork, because the slot is roughly 56 pt wide and the full-size marks
do not survive being shrunk into it.

### Resolution order

| Tier | Source | Committed? |
| --- | --- | --- |
| 1 | `LocalAssets/combined-tray-badge.png` | no — gitignored |
| 2 | composed: Clawd's face + Codex blossom, resolved locally | no — nothing committed |
| 3 | the repository's own drawn badge | **yes** — original artwork |
| 4 | text (`AI`) | n/a — last resort only |

Tier 3 is a simple two-eyed face beside a six-petal rosette, drawn in code. It
gestures at "a character and a flower" without imitating either company's mark,
so it is safe to ship publicly — and because it is drawn rather than loaded, the
graphic path can never fail. **A clean checkout ships tier 3 and nothing else.**

### Reproducing tiers 1 and 2

Tier 2 needs no extra step beyond what the mascots already require:

```bash
make assets    # Clawd poses (gitignored)
make run
```

The Codex blossom is read from an OpenAI editor extension already installed on
the machine; nothing is downloaded. If either source is missing, the badge falls
back to tier 3 automatically.

For tier 1, drop your own composed badge at
`LocalAssets/combined-tray-badge.png`. It is used as authored — not templated —
so a full-colour badge keeps its colours. Aim for roughly 44×22 pt (88×44 px at
2×); wider images are scaled down to fit the slot.

Diagnostics reports which tier is active as `Tray badge: …`.

### Rendering notes

Both composed marks are alpha silhouettes combined into one **template** image,
which tints to the bar. Two failure modes to avoid, both hit during development:

- **Opaque sources become solid blocks.** Clawd's eyes are punched out as
  transparency rather than filled with their own near-black colour; filling them
  flattens into the silhouette. The same trap once made the Codex mark render as a
  black square when the opaque PNG tile was templated.
- **The slot does not grow.** Artwork is capped at 44 pt wide and scaled down if
  it exceeds that, after an earlier version pushed the blossom off the edge.

## Release artifacts ship no branded artwork

`make package` builds with `BUNDLE_BRANDED_ASSETS=0`, so the distributed
`.app` contains **only** this project's own fallback marks. Bundling Clawd's pose
data into an artifact handed to other people would be redistribution, which the
whole local-resolution design exists to avoid. The packaging script fails if any
branded file is found in the bundle, and CI asserts the same on the built ZIP.

Practical consequence, documented in the README and release notes: a downloaded
build shows the fallback mark for Claude. Clawd requires building from source and
running `make assets`. The Codex mark is unaffected — it resolves at runtime from
an OpenAI app already on the user's own machine, so nothing is redistributed
either way.

## Documentation screenshots

`docs/images/` holds real Touch Bar captures, and the Clawd and OpenAI marks are
visible in them because they show the running interface.

That is descriptive use, and distinct from shipping the assets: a screenshot does
not let anyone reconstruct the artwork. **No claim is made that either mark is
licensed to this project.** If a rights holder objects, they will be replaced with
fallback-mark captures showing the same functionality.

Before adding new screenshots, check them for personal content — app names, media
titles, file paths, account names. Prefer recapturing in a neutral app over
blurring.

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

The pose **only ever reflects actual usage**. There is no demo or cycle mode in
the shipping UI: the mascot is a second channel for the same information the
percentages carry, and a pose that did not match real usage would be
misinformation.

To see the other poses without waiting for your quota to climb:

```bash
make preview                    # renders all four to PreviewOutput/compact-*.png
```

or, to check them on the physical bar, pin the whole app to a band with a
development-only environment variable:

```bash
TBU_FORCE_SEVERITY=critical "dist/Touch Bar Usage.app/Contents/MacOS/TouchBarUsage"
```

Accepted values: `normal`, `elevated`, `warning`, `critical`, `stale`, `offline`,
`auth`, `ratelimited`, `loading`. The percentages and the pose are pinned
together, so the forced state stays internally consistent — the mascot never
disagrees with the numbers beside it. Unset the variable and the app behaves
exactly as normal; a forced launch logs `forced state active` so it cannot be
mistaken for real data.

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
