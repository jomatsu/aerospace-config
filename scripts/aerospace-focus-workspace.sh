#!/bin/bash

set -euo pipefail

direction="${1:-}"
if [[ "$direction" != "next" && "$direction" != "prev" ]]; then
    echo "Usage: $0 <next|prev> <workspace>..." >&2
    exit 1
fi
shift
if [[ $# -eq 0 ]]; then
    echo "No workspaces configured." >&2
    exit 1
fi

AEROSPACE="${AEROSPACE:-/opt/homebrew/bin/aerospace}"
LOCK_FILE="${AEROSPACE_FOCUS_LOCK_FILE:-${TMPDIR:-/tmp}/aerospace-focus-workspace.lock}"

# Serialize rapid shortcut presses so each invocation observes the last focus change.
exec 9>"$LOCK_FILE"
/usr/bin/lockf -s -t 2 9

printf '%s\n' "$@" \
    | /usr/bin/grep -Fxf <("$AEROSPACE" list-workspaces --monitor focused) \
    | "$AEROSPACE" workspace --stdin --wrap-around "$direction"
