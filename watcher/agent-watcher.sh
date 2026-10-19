#!/usr/bin/env bash
# Leak-free launcher: `exec` replaces this shell with node, so the process the
# Omarchy shell supervises *is* the watcher. No child processes to orphan.
set -u
HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
exec node "$HERE/agent-watch.js"
