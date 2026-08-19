#!/bin/bash

# Save/restore workspace-to-monitor layout presets for AeroSpace.
# Usage:
#   aerospace-monitor-preset.sh save <number>
#   aerospace-monitor-preset.sh restore <number>

PRESET_DIR="$HOME/.config/aerospace/presets"
CONFIG_FILE="${AEROSPACE_CONFIG_FILE:-$HOME/.aerospace.toml}"

action="$1"
preset="$2"

if [[ -z "$action" || -z "$preset" ]]; then
    echo "Usage: $0 (save|restore) <preset-number>" >&2
    exit 1
fi

preset_file="$PRESET_DIR/$preset"

resolve_workspace() {
    local workspace="$1"
    local shortcut resolved
    if [[ ! -f "$CONFIG_FILE" ]]; then
        printf '%s\n' "$workspace"
        return
    fi
    shortcut="$(printf '%s' "$workspace" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    resolved="$(
        awk -v binding="alt-$shortcut" '
            $1 == binding && $2 == "=" {
                value = $0
                sub(/^.*summon-workspace /, "", value)
                gsub(/["\047]/, "", value)
                print value
                exit
            }
        ' "$CONFIG_FILE"
    )"
    printf '%s\n' "${resolved:-$workspace}"
}

case "$action" in
    save)
        mkdir -p "$PRESET_DIR"
        aerospace list-workspaces --all --format '%{workspace}|%{monitor-name}' > "$preset_file"
        osascript -e "display notification \"Preset $preset saved\" with title \"AeroSpace\""
        ;;
    restore)
        if [[ ! -f "$preset_file" ]]; then
            osascript -e "display notification \"Preset $preset not found\" with title \"AeroSpace\""
            exit 1
        fi
        while IFS='|' read -r ws monitor; do
            target_ws="$(resolve_workspace "$ws")"
            aerospace move-workspace-to-monitor --workspace "$target_ws" "$monitor" &
        done < "$preset_file"
        wait
        osascript -e "display notification \"Preset $preset restored\" with title \"AeroSpace\""
        ;;
    *)
        echo "Unknown action: $action" >&2
        exit 1
        ;;
esac
