# Claude CLI control protocol

## Status and evidence

This is an experimental/internal interface, feature-detected at runtime. The
installed executable tested on 2026-09-17 was `~/.local/bin/claude`, resolving to
`~/.local/share/claude/versions/2.1.62`, version `2.1.62 (Claude Code)`.

Sources: installed `--help`, inspection of the installed handler, an actual
stdio exchange, and Anthropic's published
[Agent SDK 0.3.211 declarations](https://app.unpkg.com/@anthropic-ai/claude-agent-sdk@0.3.211/files/sdk.d.ts).
The SDK explicitly calls its usage method experimental and subject to removal.
The [CLI reference](https://code.claude.com/docs/en/cli-reference) documents the
stream formats and isolation flags. No model prompt was used in verification.

## Launch and exchange

Run in `~/Library/Application Support/Touch Bar Usage/ClaudeProbe/`:

```sh
claude -p --input-format stream-json --output-format stream-json --verbose \
  --no-session-persistence --tools '' --strict-mcp-config \
  --mcp-config '{"mcpServers":{}}' --setting-sources '' --no-chrome \
  --settings '{"theme":"dark","disableAllHooks":true}'
```

Write one newline-terminated JSON object, using a unique request ID:

```json
{"type":"control_request","request_id":"init-example","request":{"subtype":"initialize"}}
```

Wait for `type=control_response`, `response.request_id=init-example`,
`response.subtype=success`. The tested initialization payload included command,
model and account metadata; the app discards it rather than logging or caching it.
Then send:

```json
{"type":"control_request","request_id":"usage-example","request":{"subtype":"get_usage","skip_behaviors":true}}
```

Version 2.1.62 actually replied:

```json
{"type":"control_response","response":{"subtype":"error","request_id":"usage-example","error":"Unsupported control request subtype: get_usage"}}
```

Thus **get_usage is unsupported on 2.1.62**. A second installed executable,
`~/.vscode/extensions/anthropic.claude-code-2.1.273-darwin-arm64/resources/native-binary/claude`,
successfully returned structured limits. The editor updated to 2.1.274 during
verification; the application selected that newer installation and also succeeded.
The app discovers these official editor binaries and prefers newer known install
versions; `TBU_CLAUDE_PATH` is an explicit override.

Binary inspection exposed `skip_behaviors:true`; a live request verified it.
The application sends it to suppress session-history attribution scans. Live
five-hour utilization was 23%, weekly utilization 40%; both had ISO reset times.
Committed fixtures remain synthetic, not copied from real account responses.

A supported result nests data under `response.response`; its `rate_limits`
contains optional five-hour, seven-day and model buckets. `utilization` is a
percentage from 0 to 100 in that schema: **0.72 means 0.72%, not 72%**. The app
clamps finite numbers and refuses absent/unusable limits. It does not guess a
scale from magnitude. A future fractional schema needs an explicit adapter.
ISO-8601 `resets_at` values become absolute dates. Model-scoped windows stay out
of the compact bar. Session billing, account metadata, behavior attribution and
extra-usage credits are not retained.

## Compatibility and lifecycle

Unsupported responses are cached for the executable's reported version; a
version change causes another attempt. Timeouts and malformed responses do not
permanently disable the method. Initialization and usage each have a 12-second
bound. The process receives EOF, then termination and a forced kill if needed;
2.1.62 did not exit promptly on EOF in the live test (5.33 seconds total).
The newer protocol experiments exited cleanly on EOF in 2.79–3.21 seconds total.
The actual provider completed structured retrieval in 6.51 seconds, including
version lookup and bounded cleanup. No persistent Claude worker is used.

The app then launches an isolated PTY with the same tool/MCP/hook restrictions,
without print/stream flags. It sends only `/usage`, after a recognized ready UI.
Only a trust prompt containing the exact dedicated directory may be accepted.
Global onboarding, login selection and unknown screens are never advanced.
The probe has bounded waits, cancellation, output caps and process-group cleanup.
No raw transcript logging option remains.

On this machine the initial PTY reached first-run theme/login setup, despite
`claude auth status` confirming logged in outside the execution sandbox. The
existing global configuration lacked onboarding completion. The application now
aborts on that screen; complete normal Claude setup in your own terminal.
No login, logout or configuration repair was performed by this hotfix.

## Authentication and limitations

Only exit 0 plus `loggedIn:true` is logged in, and exit 1 plus `loggedIn:false`
is confirmed logged out. Missing executable is distinct. Malformed, contradictory,
timed-out or failed results are unknown, even if output contains login words.
This deliberately requires JSON evidence as well as the documented exit code.

The app never requests tools or inference and never opens user project files.
Claude Code controls its own internals. The verified `skip_behaviors` option
suppresses its optional session-history attribution scan; unrelated metadata is
discarded. Changes in the
CLI's internal protocol or terminal UI can require compatibility updates.
EOF, process exit, cancellation, partial lines, multiple lines and unrelated
stream events are covered by credential-free tests.
