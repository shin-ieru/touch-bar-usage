# Touch Bar Usage v0.1.1

A patch release fixing a Claude authentication bug.

## Fixed

- **Claude no longer asks you to sign in when Claude Code is still signed in.**
  v0.1.0 treated a locally expired OAuth token as proof of logout. Claude Code
  refreshes that token *lazily* — when Claude Code itself next runs — so anyone
  not actively using Claude Code could see a false "Sign in" for hours while their
  account was perfectly fine.

- **Only Claude Code can now declare you logged out.** When the OAuth path fails
  for any reason — expired token, HTTP 401/403, unreadable keychain, malformed
  credential — the app asks `claude auth status` instead of guessing. "Sign in"
  appears only when Claude Code itself says you are signed out.

- **Temporary failures keep your last known figures**, marked stale, instead of
  being replaced by a sign-in prompt.

- **The keychain prompt no longer hangs or nags.** Reading Claude Code's
  credential can raise a macOS permission dialog. That dialog blocked refreshes
  indefinitely, and dismissing it only meant being asked again five minutes later.
  The read is now time-limited, and after a denial the fast path pauses for 30
  minutes and uses cached figures. Granting access takes effect immediately.

## Unchanged

Everything else: the Touch Bar badge, the on-demand dashboard, Codex support,
sleep/wake behaviour, and the Touch Bar setting requirement are all as in v0.1.0.

**Claude Code still owns its own authentication.** This app never reads the
refresh token, never exchanges or rotates it, and never writes to your keychain.

## Known limitations

Everything listed for v0.1.0 still applies, plus:

- A **Claude Code `/usage` fallback** is included but **off by default**. It is
  meant to read your figures when the OAuth path is unavailable, but on
  macOS 26.6.2 with Claude Code 2.1.62 it does not get past Claude Code's
  first-run setup screen, so it is opt-in (`TBU_CLAUDE_CLI_FALLBACK=1`) rather
  than run on every refresh. Nothing depends on it — the sign-in fix does not use
  it, and cached figures cover the gap.
- When it is enabled, it parses Claude Code's **interactive UI**, which is not a
  stable interface and may change without notice.
- Still **ad-hoc signed and not notarized**; right-click → **Open** on first
  launch.

## Details

`docs/claude-auth-resilience.md` documents the diagnosis, the fix, and both
defects found on hardware.

---

Touch Bar Usage is an independent open-source project and is not affiliated with,
endorsed by, or sponsored by Anthropic or OpenAI.
