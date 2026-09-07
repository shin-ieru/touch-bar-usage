# Branding and assets

## Why this repository ships a placeholder

The Touch Bar widget shows a small character mark beside Claude's usage. This
repository ships an **original, generated placeholder** — a rounded square with a
simple two-dot face, drawn in code in
[`MascotProvider.swift`](../Sources/TouchBarUsage/TouchBar/MascotProvider.swift).
There is no image file to license.

Anthropic's own artwork is deliberately **not** bundled. Being able to download an
image is not permission to redistribute it, and this repository is intended to be
public. Shipping trademarked artwork without verifying its redistribution terms
would put every downstream fork at risk, so the placeholder is intentionally
generic and does not imitate any official mark.

## Using your own mascot locally

Drop an image here:

```
LocalAssets/claude-mascot.png
```

The app prefers it automatically — no setting to toggle. `LocalAssets/` is in
`.gitignore`, so your local asset cannot be committed by accident. When you run
`make app`, the bundler copies the override into the bundle's `Resources/` if it
is present, and silently skips it otherwise, so a clean checkout and CI are
unaffected.

Recommended: a square PNG, at least 40×40 px (it renders at 18 pt, so 2× is
36 px). The image is scaled proportionally to the bar height.

## Before adding artwork to a public release

Do not commit third-party artwork — including Anthropic's — unless **all** of the
following are true:

1. the redistribution terms have actually been read, not assumed;
2. they permit redistribution in an MIT-licensed open-source project;
3. the attribution they require is recorded in `THIRD_PARTY_NOTICES.md`;
4. the use is not one that implies endorsement or affiliation.

"It was publicly accessible" satisfies none of these.

Studying how another project handles an interaction is fine. Copying its
animation frames, sprites, or artwork is not.

## Animation

Phase 1 ships a static mark deliberately. A continuously animating Touch Bar
widget costs CPU all day for no informational gain, which conflicts directly with
the project's idle-cost target. If animation is added later it should be
event-driven and brief, never a persistent loop.

---

Touch Bar Usage is an independent open-source project and is not affiliated with,
endorsed by, or sponsored by Anthropic. The placeholder mark is original to this
project and is not an Anthropic asset.
