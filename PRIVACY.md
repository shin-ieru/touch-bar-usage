# Privacy

**Short version: this app collects nothing, sends nothing anywhere except
Anthropic, and has no server.**

## What leaves your Mac

**For Claude:** one read-only HTTPS GET to
`https://api.anthropic.com/api/oauth/usage`, carrying the Claude Code access
token already stored on your machine in its `Authorization` header. That request
asks Anthropic "how much of my quota have I used?" and nothing else.

**For Codex: nothing this app sends.** It talks to the Codex App Server already
on your machine over a local pipe and asks it for your usage numbers. That server
— not this app — makes whatever network request it needs, using credentials this
app never sees. This app holds no OpenAI token and contacts no OpenAI host.

Anthropic's and OpenAI's handling of those requests is governed by their own
privacy policies, not this project's.

## What stays on your Mac

A single cache file:

```
~/Library/Application Support/com.gabrielanyog.touchbarusage/usage-claude.json
```

It contains normalized usage data only — percentages, reset timestamps, window
labels, and the time of the last fetch. You can read it yourself; it is
pretty-printed JSON. It contains no credential, no account identifier, and no
conversation data, because the type that is written to it has no field capable of
holding any of those.

Delete it any time; the app will simply re-fetch.

## What the app never touches

- your Claude conversations, prompts, or model responses
- your source code or project files
- your terminal history
- browser data or cookies
- any Keychain item other than the single Claude Code credential
- `~/.codex/auth.json` or any OpenAI credential
- your Codex threads, prompts, or session history
- any other application's data

## Telemetry

There is none:

- no analytics
- no usage tracking
- no crash-reporting SDK that transmits anything
- no advertising
- no update or "phone home" ping
- **no developer-operated server exists at all**

The project has no backend. There is nowhere for your data to go.

## Logging

The app logs to the macOS unified log under the subsystem
`com.gabrielanyog.touchbarusage`. Log lines record normalized states — for
example `usage refresh succeeded {provider=claude windows=3}` — never response
bodies, never request headers, and never credentials. The logger redacts values
both by key name and by recognising token-shaped strings.

---

Touch Bar Usage is an independent open-source project and is not affiliated with,
endorsed by, or sponsored by Anthropic.
