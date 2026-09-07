#!/usr/bin/env bash
# Pre-commit safety scan: credential-shaped strings, machine-specific paths, and
# artwork that should not be tracked. Run via `make audit`.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
status=0

# Only inspect tracked files: build products and gitignored assets are irrelevant.
files() { git ls-files; }

echo "==> Scanning tracked files for credential material"
# Real Anthropic tokens carry a long opaque suffix; test literals do not.
if files | xargs grep -nE 'sk-ant-(oat|ort)[0-9]{2}-[A-Za-z0-9_-]{40,}' 2>/dev/null; then
  echo "FAIL: a real-looking Anthropic token is tracked"; status=1
else
  echo "  ok: no token-shaped strings"
fi

echo "==> Scanning for stored credential blobs"
if files | xargs grep -nE '"refreshToken"[[:space:]]*:[[:space:]]*"[A-Za-z0-9_-]{20,}' 2>/dev/null; then
  echo "FAIL: a refresh token value is tracked"; status=1
else
  echo "  ok: no credential blobs"
fi

echo "==> Scanning for real Authorization headers"
if files | xargs grep -nE 'Bearer [A-Za-z0-9_-]{30,}' 2>/dev/null; then
  echo "FAIL: a bearer token value is tracked"; status=1
else
  echo "  ok: no bearer values"
fi

echo "==> Scanning for machine-specific absolute paths"
# /Users/<name>/ in tracked source would break every other contributor.
if files | xargs grep -nE '/Users/[a-zA-Z0-9._-]+/' 2>/dev/null; then
  echo "FAIL: a user-specific absolute path is tracked"; status=1
else
  echo "  ok: no user-specific paths"
fi

echo "==> Scanning for account identifiers"
# The all-zero nil UUID is an obvious placeholder and is allowed in fixtures.
if files | xargs grep -nE '"organizationUuid"[[:space:]]*:[[:space:]]*"[0-9a-f]{8}-' 2>/dev/null \
   | grep -v '00000000-0000-0000-0000-000000000000'; then
  echo "FAIL: an organization UUID is tracked"; status=1
else
  echo "  ok: no account identifiers"
fi

echo "==> Checking local assets are not tracked"
if files | grep -E '^LocalAssets/' 2>/dev/null; then
  echo "FAIL: LocalAssets/ must stay gitignored"; status=1
else
  echo "  ok: LocalAssets/ untracked"
fi

echo "==> Checking preview renders are not tracked"
if files | grep -E '^PreviewOutput/' 2>/dev/null; then
  echo "FAIL: PreviewOutput/ must stay gitignored"; status=1
else
  echo "  ok: PreviewOutput/ untracked"
fi

echo "==> Checking generated Clawd assets are not tracked"
# Clawd is Anthropic's character and the upstream pose library publishes no
# licence, so none of it may ever be committed here.
if files | grep -E '^GeneratedAssets/|clawd-poses\.json|clawd_presets\.h' 2>/dev/null; then
  echo "FAIL: generated Clawd pose data must stay gitignored"; status=1
else
  echo "  ok: no Clawd pose data tracked"
fi

echo "==> Checking the mascot has no runtime network dependency"
# Pose data is fetched at build time by Scripts/, never by the running app.
if files | grep -E '^Sources/.*(Mascot|Clawd)' | xargs grep -nE 'URLSession|dataTask|URLRequest|fetch\(' 2>/dev/null; then
  echo "FAIL: mascot code must not perform network requests at runtime"; status=1
else
  echo "  ok: mascot resolves from disk only"
fi

echo "==> Checking Codex credentials are never read directly"
# The App Server owns OpenAI authentication; this app must never touch the
# credential file or hold an OpenAI token.
# Comment lines are excluded: the docs deliberately state that this app does
# *not* read auth.json, and that promise must not trip its own check.
if files | grep -E '^Sources/' \
   | xargs grep -nE 'auth\.json|OPENAI_API_KEY|sk-proj-|api\.openai\.com' 2>/dev/null \
   | grep -vE ':[0-9]+:[[:space:]]*(///|//|\*)'; then
  echo "FAIL: Codex credentials must be left to the App Server"; status=1
else
  echo "  ok: no direct Codex credential or OpenAI endpoint access"
fi

echo "==> Checking only read-only Codex RPC methods are sent"
# These spend the user's credits or email them; a monitor must never call them.
if files | grep -E '^Sources/' \
   | xargs grep -nE '"account/(rateLimitResetCredit/consume|sendAddCreditsNudgeEmail|logout|login)' 2>/dev/null \
   | grep -v 'must never'; then
  echo "FAIL: a non-read-only Codex method is referenced"; status=1
else
  echo "  ok: Codex usage is read-only"
fi

echo "==> Checking Anthropic is the only network destination"
offenders="$(files | grep -E '^Sources/.*\.swift$' | xargs grep -lE 'URLSession' 2>/dev/null \
  | grep -v 'AnthropicUsageClient.swift' || true)"
if [ -n "$offenders" ]; then
  echo "$offenders" | sed 's/^/  unexpected URLSession use: /'
  echo "FAIL: network access belongs in AnthropicUsageClient only"; status=1
else
  echo "  ok: URLSession confined to AnthropicUsageClient"
fi

echo "==> Checking no synthetic Escape key is injected"
# This hardware has a physical Escape key; synthesising one would also risk
# pulling in an Accessibility permission we deliberately do not request.
if files | grep -E '^Sources/' | xargs grep -nE 'escapeKeyReplacementItemIdentifier' 2>/dev/null; then
  echo "FAIL: no synthetic Escape item should be injected"; status=1
else
  echo "  ok: no synthetic Escape item"
fi

echo "==> Checking no broad permissions are requested"
if files | grep -E '^Sources/|Info\.plist|\.entitlements' \
   | xargs grep -nE 'NSAccessibility|kAXTrusted|ScreenCapture|InputMonitoring|com\.apple\.security\.automation' 2>/dev/null; then
  echo "FAIL: unexpected permission request"; status=1
else
  echo "  ok: no Accessibility/Screen Recording/Input Monitoring requests"
fi

echo "==> Listing tracked binary assets for licensing review"
binaries="$(files | grep -iE '\.(png|jpg|jpeg|gif|icns|pdf|tiff|svg)$' || true)"
if [ -n "$binaries" ]; then
  echo "$binaries" | sed 's/^/  review: /'
  echo "  (confirm redistribution terms — see docs/branding.md)"
else
  echo "  ok: no tracked binary assets"
fi

echo
if [ "$status" -eq 0 ]; then echo "AUDIT PASSED"; else echo "AUDIT FAILED"; fi
exit "$status"
