#!/bin/bash

set -euo pipefail

CACHE_DIR="${AEROSPACE_SNAPSHOT_CACHE_DIR:-$HOME/Library/Caches/AeroSpaceWorkspaceSnapshots}"
REQUEST_FILE="$CACHE_DIR/request.tsv"
REASON="${1:-unknown}"
NOW="$(date '+%s')"
TMP_FILE="$CACHE_DIR/.request-$$.tmp"

mkdir -p "$CACHE_DIR"
printf '%s\t%s\t%s\t%s\n' \
    "$NOW" \
    "$REASON" \
    "${AEROSPACE_FOCUSED_WORKSPACE:-}" \
    "${AEROSPACE_PREV_WORKSPACE:-}" > "$TMP_FILE"
mv "$TMP_FILE" "$REQUEST_FILE"
