#!/usr/bin/env bash
# Render preview.html to a 1600x900 PNG with headless Chrome.
# usage: render.sh <out.png> [query-string]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$(realpath -m "$1")"; q="${2:-}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/agent-pulse-preview.XXXX")"
trap 'rm -rf "$scratch"' EXIT
XDG_CACHE_HOME="$scratch/cache" TMPDIR="$scratch" "${CHROME:-google-chrome}" \
  --headless=new --no-sandbox --disable-gpu --hide-scrollbars \
  --user-data-dir="$scratch/profile" --allow-file-access-from-files \
  --window-size=1600,900 --virtual-time-budget=8000 \
  --screenshot="$out" "file://$here/preview.html${q:+?$q}" 2>/dev/null
echo "$out"
