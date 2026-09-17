# Contributing

Thanks for looking. This is a small, focused utility — contributions are welcome,
and the rules below exist mostly to keep it safe to publish.

## Getting set up

```bash
git clone <this-repo>
cd touch-bar-usage
make test     # should pass on a clean clone, with no setup
make run
```

No dependencies to install beyond Xcode. `make assets` is optional — it fetches
Clawd artwork onto your own machine; without it the app uses its built-in
fallback mark and everything else works.

Requires macOS 13+ and Xcode 26 / Swift 6.3. A physical Touch Bar is needed to
verify Touch Bar changes, but not to build or test.

## Before opening a pull request

```bash
make test && make audit
```

Both must pass. `make audit` is not decoration — it enforces the security and
licensing rules below, and CI runs it too.

## The rules that matter

### Never commit credentials

No tokens, no keychain blobs, no `auth.json`, no `Authorization` headers, no real
account identifiers. Not in code, not in tests, not in fixtures, not in
screenshots.

Test fixtures must be synthetic. If you capture a real API response to work from,
reduce it to synthetic values before committing — strip account IDs, replace
percentages, remove anything identifying. `make audit` scans for the obvious
shapes, but it is a backstop, not a substitute for reading what you are adding.

### Never commit third-party artwork

Clawd is Anthropic's and the Codex mark is OpenAI's. Neither is redistributed by
this project: both are resolved on the developer's own machine at build or run
time, and the generated output is gitignored *and* excluded from release
artifacts.

Only the project's own drawn fallback marks ship. If you add artwork, it must be
original or carry a licence that permits redistribution, recorded in
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md). "It was publicly accessible"
is not a licence. See [`docs/branding.md`](docs/branding.md).

### Keep private API use in one place

Everything that touches undocumented macOS Touch Bar APIs lives in
[`SystemModalTouchBarBridge.swift`](Sources/TouchBarUsage/TouchBar/SystemModalTouchBarBridge.swift).
Do not scatter `performSelector`, Objective-C runtime lookups, or private
framework symbols elsewhere. Everything there resolves dynamically and degrades
rather than crashing — keep it that way.

### Adding a provider

Read [`docs/provider-contract.md`](docs/provider-contract.md) first. The short
version: implement `UsageProvider`, never throw, never surface credentials to
callers, never mutate stored credentials, and express `usedPercent` as **consumed**
quota. Delegate authentication to the official local CLI, as both existing providers
do. Never add direct credential access.

Adding a third provider should require no changes to either existing one. If you
find yourself writing `if provider.id == "claude"` outside the Claude directory,
the seam is in the wrong place.

## Testing

The whole suite runs headless: no network, no keychain, no Touch Bar, neither CLI
installed. Keep it that way — anything requiring hardware belongs in
[`docs/manual-test-results.md`](docs/manual-test-results.md), recorded honestly.

Two things that repeatedly bit this project and are worth knowing:

- **A private Touch Bar API returning success proves nothing.** Several
  configurations register cleanly and draw nothing. Only the physical bar settles
  it, and behaviour differs between Touch Bar presentation modes.
- **Off-device previews (`make preview`) are useful for layout, not for
  rendering.** They render light-mode; the bar is always dark, and template
  artwork inverts. An opaque image that previews fine can become a black block on
  hardware.

If you change Touch Bar behaviour and have the hardware, verify it there and say
what you checked. If you do not have the hardware, say so in the PR — that is
genuinely fine and much better than an untested claim.

## Commits

Explain *why*, not just what. Where a decision looks odd, the reason usually is
odd — record it, so the next person does not "fix" it back.

Do not rewrite existing history.

## Reporting problems

Use the issue templates. For Touch Bar problems include your Mac model, macOS
version, Touch Bar setting, app version, and the Diagnostics output — which is
designed to be safe to paste publicly. Never paste tokens, `auth.json`, or
keychain contents; nothing in this project ever needs them.
