#!/usr/bin/env bash
# Manual install for Agent Orb.
#
# You do not normally need this. `omarchy plugin add <git-url>` installs and
# enables the plugin from a git checkout, and `omarchy plugin update` updates it
# in place. This script exists for people who copied the folder, or who want the
# --watch symlink mode while editing.
#
#   ./scripts/install.sh            install or update (keeps existing settings)
#   ./scripts/install.sh --watch    symlink instead of copy, for live editing
#   ./scripts/install.sh --remove   remove the plugin and its state
#
# The bar widget is a separate plugin with its own installer:
# OmarchyAgentOrbStatus.
#
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
PLUGIN_ID="$(jq -r '.id' "$HERE/manifest.json")"
PLUGIN_SRC="$HERE"
DEST="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/agent-watch"

die() { echo "error: $*" >&2; exit 1; }
say() { echo "  $*"; }

have() { command -v "$1" >/dev/null 2>&1; }

remove_plugin() {
  if [ -e "$DEST" ] || [ -L "$DEST" ]; then
    rm -rf "$DEST"
    say "removed $DEST"
  fi
  if have omarchy && omarchy plugin list 2>/dev/null | grep -q "^$PLUGIN_ID"; then
    omarchy plugin disable "$PLUGIN_ID" >/dev/null 2>&1 || true
    say "disabled $PLUGIN_ID"
  fi
  rm -rf "$STATE_DIR"
  say "removed $STATE_DIR"
  have omarchy && { omarchy restart shell >/dev/null 2>&1 || true; say "restarted shell"; }
}

if [ "${1:-}" = "--remove" ]; then
  remove_plugin
  exit 0
fi

WATCH=0
[ "${1:-}" = "--watch" ] && WATCH=1

have omarchy || die "omarchy not found in PATH"
have jq || die "jq not found in PATH"
[ -f "$PLUGIN_SRC/manifest.json" ] || die "missing manifest.json"
omarchy-plugin-validate "$PLUGIN_SRC" >/dev/null || die "manifest failed validation"

echo "Agent Orb ($PLUGIN_ID)"

# ---------------------------------------------------------------- install
mkdir -p "$HOME/.config/omarchy/plugins"
mkdir -p "$(dirname "$STATE_DIR")"

if [ "$WATCH" -eq 1 ]; then
  # Symlink the whole plugin folder: edits in this repo reload instantly.
  rm -rf "$DEST"
  ln -s "$PLUGIN_SRC" "$DEST"
  say "symlinked $PLUGIN_SRC -> $DEST"
else
  # Copy, preserving the executable bit on the watcher launcher.
  rm -rf "$DEST"
  mkdir -p "$DEST"
  cp -r "$PLUGIN_SRC/." "$DEST/"
  rm -rf "$DEST/.git"
  chmod +x "$DEST/watcher/agent-watcher.sh" 2>/dev/null || true
  say "installed to $DEST"
fi

# ---------------------------------------------------------------- enable
# A newly dropped folder is not in the registry until the shell re-walks the
# plugin dirs, so rescan before asking it to flip the bit.
omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
if omarchy plugin enable "$PLUGIN_ID" >/dev/null 2>&1; then
  say "enabled $PLUGIN_ID"
else
  say "warning: could not enable automatically; run: omarchy plugin enable $PLUGIN_ID"
fi

# ---------------------------------------------------------------- restart
say "restarting shell"
omarchy restart shell >/dev/null 2>&1 || true

echo
echo "  watching: opencode, codex, claude, hermes, pi, and a dozen more"
echo "  state:     $STATE_DIR/state.json"
echo "  add your own agent:  ~/.config/omarchy/agent-watch/sources.json"
echo "  disable:   omarchy plugin disable $PLUGIN_ID   (or ./scripts/install.sh --remove)"