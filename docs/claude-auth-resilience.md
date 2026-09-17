# Claude authentication resilience

## Why the architecture changed

v0.1.0 coupled credential readability and direct HTTP errors to authentication.
v0.1.1 added an auth oracle, but still read the keychain first, retried OAuth and
left its unverified interactive fallback opt-in. It also treated a fallback login
screen as logout even after auth status said logged in. Token expiry, Keychain
permissions and terminal onboarding could therefore disagree with Claude Code.

v0.1.2 deletes the credential reader, Keychain gate and direct HTTP client.
Touch Bar Usage delegates Claude authentication and usage retrieval to the
installed Claude Code CLI. It does not refresh, rewrite, or own Claude Code
credentials.

## Source and state order

1. Experimental `get_usage` control request.
2. Isolated interactive `/usage`, enabled by default.
3. If both fail, `claude auth status --json`.

| Auth result after usage failure | With last-good cache | Without cache |
| --- | --- | --- |
| Logged in | Stale values and explanation | Unavailable |
| Unknown/error | Stale values and explanation | Unavailable |
| Confirmed logged out | Sign in | Sign in |

A login screen, unsupported method, timeout, parse error or CLI usage error alone
never produces Sign in. Authentication checks do not initiate login or logout.
The existing coordinator coalesces refreshes and keeps its five-minute cadence
and one-minute minimum interval. Local countdown updates make no usage request.

## Diagnostics and verification

Diagnostics show source, CLI version, capability, last successful refresh,
provider state and last checked auth state, never credentials or account IDs.
A successful usage response does not require a separate auth-status request.

On 2026-09-17 Claude Code 2.1.62 reported logged in outside the tool sandbox while
the isolated interactive UI showed onboarding. That reproduces why UI text is
not an authentication oracle. No real logout was attempted. Fixtures cover
logged-out behavior, stale cache, recovery and source fallback.

See [protocol evidence and limitations](claude-control-protocol.md).
