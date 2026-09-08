# Claude authentication resilience

Why v0.1.0 could show **Sign in** while Claude Code was still signed in, and what
v0.1.1 does instead.

## The bug, as observed

From the app's own log on 2026-09-08 (local time):

```
08:11:55  usage refresh needs authentication {provider=claude}
08:16:55  usage refresh needs authentication {provider=claude}
08:21:55  usage refresh needs authentication {provider=claude}
08:24:55  claude access token expired
08:24:55  usage refresh needs authentication {provider=claude}
...
08:28:23  usage refresh succeeded {provider=claude windows=3}
```

Claude Code was authenticated the entire time. The app recovered on its own once
Claude Code next refreshed its token.

## Root cause

`ClaudeUsageProvider.fetchUsage()` treated a **locally computed** token expiry as
proof of logout:

```swift
if credential.isExpired(now: now()) {
    return .needsAuthentication      // ← wrong conclusion
}
```

Claude Code refreshes its OAuth access token **lazily** — when Claude Code itself
next runs, not on a timer. So there is a window, potentially hours long if you are
not actively using Claude Code, where:

- the stored access token has passed `expiresAt`,
- Claude Code is perfectly well signed in,
- and Touch Bar Usage said "Sign in".

Two other paths reached the same wrong conclusion:

| Path | v0.1.0 result | Reality |
| --- | --- | --- |
| Local `expiresAt` in the past | `needsAuthentication` | Claude Code refreshes on next use |
| HTTP 401 / 403 from the usage endpoint | `needsAuthentication` | Could be a stale token, scope change, or endpoint change |
| Keychain item not found, Claude Code installed | `needsAuthentication` | Could be an ACL or storage-format change |

Every one of these is *"we could not use the OAuth fast path"*. None of them is
*"the user is logged out"*.

## Diagnosis performed

The keychain item was probed with a purpose-built tool that prints only booleans
and timestamps — never the token, never the raw JSON:

```
OSStatus:            0            (readable, no prompt, ACL intact)
topLevelKeys:        claudeAiOauth, organizationUuid
claudeAiOauth:       present
accessToken:         present
expiresAt:           2026-09-08T08:26:53Z
subscriptionType:    pro
```

So the credential was readable and well-formed. The failure was purely the
**expiry short-circuit**, and the recovery at 08:28 was Claude Code refreshing
its own credential.

Independently, Claude Code's own view:

```
$ claude auth status --json
{ "loggedIn": true, "authMethod": "claude.ai", "subscriptionType": "pro", ... }
```

Confirming the distinction that matters:

```
A. Touch Bar Usage cannot use the OAuth credential   ← what actually happened
B. Claude Code is genuinely logged out               ← never true here
```

## The fix

### 1. Stop guessing from the local clock

The expiry short-circuit is gone. The request is attempted regardless; the server
is the authority on whether a token works. A local clock comparison is not.

### 2. Ask Claude Code, don't infer

`claude auth status --json` answers the logout question directly, and it is a
plain subcommand: no PTY, no model prompt, no tools, no session. It is the only
thing permitted to produce `needsAuthentication`.

```
OAuth fails
    ↓
claude auth status --json
    ├─ loggedIn: false  → needsAuthentication   (genuine, and the only route to it)
    └─ loggedIn: true   → not a logout; keep going
    └─ unknown/timeout  → not a logout; keep going
```

This is a better oracle than the interactive UI: it is structured, exits
immediately, and cannot be confused by terminal rendering.

### 3. Let Claude Code refresh its own credential

When the auth probe confirms the user is signed in, the credential is re-read and
the OAuth path retried **once**. Running the CLI is often enough for Claude Code
to refresh its own token, which resolves the exact failure observed above.

Note what this is *not*: Touch Bar Usage never exchanges, rotates, or writes the
refresh token. Claude Code refreshes its own credential as a side effect of being
run; we simply read the result afterwards.

### 4. Fall back to Claude Code's own `/usage` — implemented, opt-in

If OAuth still cannot be used but the user is signed in, the numbers can be read
from Claude Code's `/usage` command, run in an isolated no-tools PTY session.

**This path is off by default** (`TBU_CLAUDE_CLI_FALLBACK=1` enables it) because it
does not currently work on this hardware — see "The CLI probe" below. It is not
load-bearing: the fix for the false "Sign in" is the auth-status oracle, and the
last-good snapshot covers the numbers.

### 5. Stop the keychain becoming a recurring interruption

A second defect surfaced while testing the first. Reading the credential can raise
a macOS **ACL** dialog, and:

- `SecItemCopyMatching` **blocks** while that dialog is on screen. In a background
  menu-bar app that is an invisible hang — the app sat at 0% CPU logging nothing.
- Dismissing it only means the next refresh asks again: a dialog every five
  minutes, indefinitely.

`kSecUseAuthenticationUI` does not help; it governs biometric prompts, not the ACL
dialog. Ad-hoc signed builds make it worse, because the signature changes on every
rebuild so the ACL never matches.

The fix is two parts: the read runs with a short deadline so it can never hang a
refresh, and once the keychain proves unavailable the fast path is paused for 30
minutes. A successful read clears the pause immediately, so granting access takes
effect without a restart.

### 6. Never blank out on a transient failure

If neither source works and a recent snapshot exists, the last good values stay on
screen marked stale. `Sign in` is shown only when the auth probe actually says so.

## Resulting strategy

```
Auto
 ├─ OAuth fast path            → ready (source: oauth)
 ├─ auth probe says logged out → needsAuthentication      ← only route
 ├─ OAuth retry after probe    → ready (source: oauth)
 ├─ CLI /usage probe           → ready (source: cli)
 ├─ last-good snapshot         → stale (source: staleCache)
 └─ nothing                    → failed — never "Sign in"
```

The regression assertion, enforced by tests: **an OAuth failure alone can never
produce `needsAuthentication`.**

## The CLI probe

> **Status: implemented, fixture-tested, not working on hardware.** Enable with
> `TBU_CLAUDE_CLI_FALLBACK=1`.
>
> In a fresh probe directory Claude Code 2.1.62 shows its first-run setup wizard
> (theme picker). Four approaches were tried on real hardware — answering the
> screen, matching its text after ANSI stripping, matching whitespace-collapsed
> text (the TUI positions words with cursor moves, so stripped output reads
> `choosethetextstyle`), and pre-supplying `--settings` — and the session still
> does not reach the prompt. Each failed attempt costs about 27 seconds, which is
> why it is not run on every refresh.
>
> The parser itself is covered by 16 tests against synthetic renderings, so the
> remaining work is getting a session to the prompt, not reading the output.

| | |
| --- | --- |
| Executable | the installed `claude`, resolved as before |
| Invocation | `claude --allowed-tools ""` in a PTY |
| Working directory | `~/Library/Application Support/…/ClaudeProbe/` — an empty directory containing no user code |
| Environment | `CLAUDECODE` and related session variables cleared, so the probe cannot be mistaken for, or collide with, a nested session |
| Commands sent | `/usage` only |
| Timeout | bounded; the child is terminated and reaped |
| Cleanup | probe session artifacts in the probe directory only; normal Claude Code history is never touched |

It does not send a model prompt, does not use tools, does not read your projects,
does not touch terminal history, and never runs `/login`.

A PTY is needed only because `/usage` is an interactive slash command. If Claude
Code ever exposes usage non-interactively — as it already does for auth status —
this fallback should move to that immediately.

## Security position, unchanged

1. Read-only OAuth usage fast path when the credential is readable.
2. Otherwise, run the installed Claude CLI in an isolated no-tools session.
3. **Claude Code owns authentication and credential refresh.**
4. Touch Bar Usage never refreshes, rotates, or rewrites Claude Code credentials,
   and never reads the refresh token.

## Known limitation

The `/usage` fallback parses Claude Code's **interactive UI**, which is not a
stable interface and may change without notice. The parser is deliberately
tolerant — it strips ANSI, works from section labels and percentages rather than
fixed columns, and accepts both "% used" and "% left" — but a sufficiently large
redesign upstream would break it.

That is why it is a *fallback*. The OAuth path remains the primary source, and if
the fallback breaks, the app shows stale data or an honest failure rather than a
false "Sign in".
