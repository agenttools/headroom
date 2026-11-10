#!/usr/bin/env bash
# extension-id.sh — print the Chrome extension id that follows from the manifest's fixed "key" (SPEC §8.2).
#
#   scripts/extension-id.sh [path/to/manifest.json]      default: Extension/manifest.json
#
# Chrome's rule: sha256 of the DER public key, first 32 hex digits, each digit 0-f mapped to a-p.
set -euo pipefail
MANIFEST="${1:-$(cd "$(dirname "$0")/.." && pwd)/Extension/manifest.json}"
[[ -f "$MANIFEST" ]] || { echo "extension-id: no manifest at $MANIFEST" >&2; exit 1; }
KEY="$(plutil -extract key raw -o - "$MANIFEST" 2>/dev/null || true)"
[[ -n "$KEY" ]] || { echo "extension-id: $MANIFEST has no \"key\"" >&2; exit 1; }
printf '%s' "$KEY" | base64 -D | shasum -a 256 | cut -c1-32 | tr '0-9a-f' 'a-p'
