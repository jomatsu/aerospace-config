#!/bin/bash

# Install AeroSpace configuration from this repository.
#
# Generates ~/.aerospace.toml from the template. The repository's actual
# location is injected into the generated config at setup time, so this
# works no matter where the repo is cloned.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_ROOT"

if ! command -v deno >/dev/null 2>&1; then
    echo "Error: Deno is required. Install it first:" >&2
    echo "  brew install deno" >&2
    exit 1
fi

echo "Generating ~/.aerospace.toml"
echo "  repository: $REPO_ROOT"
cd "$REPO_ROOT/aerospace"
deno task setup

echo ""
echo "Done."
echo "Next steps:"
echo "  aerospace reload-config   # apply immediately"
echo "  # or restart AeroSpace"
echo "  # alt-0 refreshes workspace assignments with the current layout"
echo ""
echo "If you move this repository later, re-run install.sh to regenerate."