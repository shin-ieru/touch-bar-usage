# Release process

## Version

`VERSION` at the repository root is the single source of truth. `make_app.sh`
writes it into `Info.plist`, `package_release.sh` puts it in the artifact name,
and CI fails if the built plist disagrees with it. Bump that one file.

The build number is the short commit hash, which is more useful in a bug report
than a counter someone has to remember to increment.

## Cutting a release

```bash
make release-check          # tests + audit + release build
make package                # dist/Touch-Bar-Usage-v<version>-macOS.zip + .sha256
```

Then verify by hand on a machine with a Touch Bar, using the **packaged**
artifact rather than the development build, and record the results in
[`manual-test-results.md`](manual-test-results.md).

Finally, commit, tag, and publish:

```bash
git tag -a v0.1.0 -m "Touch Bar Usage v0.1.0"
git push origin main --follow-tags
gh release create v0.1.0 \
  "dist/Touch-Bar-Usage-v0.1.0-macOS.zip" \
  "dist/Touch-Bar-Usage-v0.1.0-macOS.zip.sha256" \
  --title "Touch Bar Usage v0.1.0" \
  --notes-file RELEASE_NOTES_v0.1.0.md
```

## What the artifact must not contain

Release builds run with `BUNDLE_BRANDED_ASSETS=0`, so the bundle ships only this
project's own fallback marks. Clawd's pose data is Anthropic's and its upstream
publishes no licence; putting it in an artifact handed to other people would be
redistribution.

`package_release.sh` fails if any branded file reaches the bundle, and CI unpacks
the built ZIP and checks the same thing. Do not weaken either guard.

The consequence is intended and documented: a downloaded build shows the fallback
mark for Claude. Clawd requires building from source with `make assets`. The
Codex mark is unaffected — it resolves at runtime from an OpenAI app on the
user's own machine.

## Signing and notarization

**v0.1.0 is ad-hoc signed and not notarized.** The only certificate available on
the development machine is an *Apple Development* identity, which is for local
development and cannot be used to distribute software. Distribution requires an
**Apple Developer ID Application** certificate, which needs a paid Apple Developer
Program membership.

`package_release.sh` reports this accurately: it looks for a `Developer ID
Application` authority rather than trusting `codesign --verify`, because an
ad-hoc signature satisfies its own designated requirement and would otherwise
look like success.

Verified state for v0.1.0:

```
codesign --verify --strict   valid, satisfies its designated requirement
signature type               ad-hoc (TeamIdentifier=not set)
entitlements                 none
spctl -a                     rejected
```

Users must right-click → **Open** once. The README says so, and deliberately does
*not* suggest disabling Gatekeeper system-wide.

### When a Developer ID becomes available

1. Sign the bundle with the Developer ID Application identity.
2. Submit with `notarytool` (not the deprecated `altool`), wait for `Accepted`.
3. `xcrun stapler staple` the app, then repackage.
4. Confirm `spctl -a -vv` reports `accepted` / `source=Notarized Developer ID`.
5. Update the README and release notes — and only then claim notarization.

Never claim signing or notarization that Apple has not actually granted, and
never put Apple credentials in the repository. `notarytool` stores them in the
keychain via `store-credentials`.

## Publication history

**v0.1.0 — published.** <https://github.com/shin-ieru/touch-bar-usage/releases/tag/v0.1.0>

Verified after publication by downloading the artifact from the Release page,
confirming its SHA-256 against the published checksum, extracting it, and
launching it. Results in [`manual-test-results.md`](manual-test-results.md).

Once a tag and its binary are public, treat them as immutable. Do not overwrite
the ZIP under the same filename, move the tag, or rewrite release history — cut
`v0.1.1` instead. Documentation-only fixes go to `main` without moving the tag.
