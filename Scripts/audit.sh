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
