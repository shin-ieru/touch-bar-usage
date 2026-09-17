# Touch Bar Usage v0.1.3

A build fix for people compiling from source.

## Fixed

- **Building from source works again on older Xcode / SDKs.** v0.1.2 could not
  compile on anything older than the macOS 26 SDK: it selected the POSIX-2024
  `posix_spawn_file_actions_addchdir` behind an `#available` check, but that is a
  *runtime* test — both branches still have to compile, and the unsuffixed name
  does not exist in earlier SDKs. It now always uses the Darwin
  `posix_spawn_file_actions_addchdir_np`, which has existed since macOS 10.15 and
  covers the whole supported range.

The v0.1.2 **binary** was unaffected, since it was built on the macOS 26 SDK.
Only compiling the source yourself was broken — which is the route the README
recommends over the unsigned download, so it is worth a patch release.

## Unchanged

Everything else is identical to v0.1.2: Claude usage and authentication delegate
to the installed official Claude Code CLI, with no credential access, no keychain
use and no HTTP requests of our own. Codex, the Touch Bar badge and the dashboard
are untouched.

Still ad-hoc signed and not notarized — right-click → **Open** on first launch.

## Known limitations

As in v0.1.2: structured `get_usage` is experimental and version-scoped (Claude
Code 2.1.62 rejects it; newer editor-bundled CLIs support it), the interactive
`/usage` fallback parses a terminal UI that may change, and distributed builds
ship repository-safe artwork — Clawd is available when you build from source with
`make assets`.

---

Touch Bar Usage is an independent open-source project and is not affiliated with,
endorsed by, or sponsored by Anthropic or OpenAI.
