#!/bin/bash

set -euo pipefail

CONFIG_FILE="${AEROSPACE_CONFIG_FILE:-$HOME/.aerospace.toml}"
OUTPUT_ROOT="$HOME/Pictures/AeroSpace Workspaces"
AEROSPACE="${AEROSPACE:-/opt/homebrew/bin/aerospace}"
MAGICK="${MAGICK:-/opt/homebrew/bin/magick}"
SCREENCAPTURE="${SCREENCAPTURE:-/usr/sbin/screencapture}"
OSASCRIPT="${OSASCRIPT:-/usr/bin/osascript}"
DELAY="0.35"
MODE="all"
CAPTURE_MODE="windows"
CURRENT_ONLY=1
COMPOSE=1
NOTIFY=0
COMPOSE_WIDTH=1600
COMPOSE_HEIGHT=900
COMPOSE_GAP=16
BLACK_MEAN_MAX=0.01
BLACK_STD_MAX=0.02
VISIBLE_RETRY=0
VISIBLE_RETRY_DELAY=0.60
DRY_RUN=0
CAPTURE_ARGS=(-x)
WORKSPACES=()
SEPARATOR=$'\037'
INITIAL_WORKSPACE=""
CAPTURED_COUNT=0
TEMP_OUTPUT_DIR=""
PROMOTED_OUTPUT_DIR=""
PREVIOUS_SNAPSHOT_DIR=""
LAST_CAPTURE_STATUS=""

usage() {
    cat >&2 <<'EOF'
Usage: aerospace-workspace-snapshot.sh [options] [workspace ...]

Options:
  --configured       Capture workspaces configured in dotfiles only
  --existing         Capture workspaces currently known to AeroSpace only
  --current          Keep only the latest successful snapshot under current/ (default)
  --history          Keep timestamped snapshot directories
  --windows          Capture each window without switching workspaces (default)
  --screen           Capture each whole workspace by switching to it
  --compose          Create one overview PNG per workspace in --windows mode (default)
  --no-compose       Skip workspace overview images in --windows mode
  --notify           Show a macOS notification after saving screenshots
  --black-threshold MEAN STD
                      Treat darker captures as invalid
  --visible-retry    Allow switching to a workspace to retry black captures
  --visible-retry-delay SECONDS
                      Delay after switching workspace for black-capture retry
  -o, --output DIR   Save run directory under DIR
  --delay SECONDS    Delay after switching workspace before capture in --screen mode
  --main             Capture main monitor only in --screen mode
  --display ID       Capture a specific macOS display ID in --screen mode
  --dry-run          Print actions without switching or capturing
  -h, --help         Show this help
EOF
}

configured_workspaces() {
    if [[ -f "$CONFIG_FILE" ]]; then
        sed -n \
            -e "s/.*summon-workspace \([^']*\)'.*/\1/p" \
            -e 's/.*summon-workspace \([^"]*\)".*/\1/p' \
            "$CONFIG_FILE"
    fi
}

existing_workspaces() {
    "$AEROSPACE" list-workspaces --all
}

sanitize() {
    printf '%s' "$1" | LC_ALL=C sed 's/[^A-Za-z0-9._-]/_/g'
}

append_workspaces() {
    local source="$1"
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] && WORKSPACES+=("$line")
    done <<< "$source"
}

workspace_is_selected() {
    local candidate="$1"
    local ws
    for ws in "${WORKSPACES[@]}"; do
        [[ "$ws" == "$candidate" ]] && return 0
    done
    return 1
}

workspace_files() {
    local ws="$1"
    awk -F '\t' -v ws="$ws" '
        NR > 1 && $2 == ws && ($NF == "captured" || $NF == "cached" || $NF == "captured-visible") {
            print $(NF - 1)
        }
    ' "$MANIFEST"
}

previous_workspace_had_no_windows() {
    local ws="$1"
    local manifest

    [[ -n "$PREVIOUS_SNAPSHOT_DIR" ]] || return 1
    manifest="$PREVIOUS_SNAPSHOT_DIR/manifest.tsv"
    [[ -f "$manifest" ]] || return 1

    ! awk -F '\t' -v ws="$ws" 'NR > 1 && $2 == ws { found = 1 } END { exit found ? 0 : 1 }' "$manifest"
}

reuse_previous_workspace_overview() {
    local ws="$1"
    local out="$2"
    local prev

    previous_workspace_had_no_windows "$ws" || return 1

    prev="$PREVIOUS_SNAPSHOT_DIR/workspace-$(sanitize "$ws").png"
    [[ -f "$prev" ]] || return 1

    cp "$prev" "$out"
    return 0
}

resolved_current_snapshot_dir() {
    local current="$OUTPUT_ROOT/current"
    local target

    if [[ -L "$current" ]]; then
        target="$(readlink "$current" || true)"
        [[ -n "$target" ]] || return 1
        if [[ "$target" = /* ]]; then
            printf '%s\n' "$target"
        else
            printf '%s\n' "$OUTPUT_ROOT/$target"
        fi
    elif [[ -d "$current" ]]; then
        printf '%s\n' "$current"
    else
        return 1
    fi
}

safe_rm_tree() {
    local path="$1"
    local tmp_root="${TMPDIR:-/tmp}"
    case "$path" in
        "$OUTPUT_ROOT"/*|/tmp/*|/private/tmp/*|"$tmp_root"/*)
            rm -rf "$path"
            ;;
        *)
            echo "Refusing to remove unexpected path: $path" >&2
            return 1
            ;;
    esac
}

workspace_root_layout() {
    local ws="$1"
    awk -F '\t' -v ws="$ws" '
        NR > 1 && $2 == ws && $9 != "" {
            print $9
            exit
        }
    ' "$MANIFEST"
}

image_is_blackish() {
    local file="$1"
    local stats mean std

    if [[ ! -x "$MAGICK" || ! -f "$file" ]]; then
        return 1
    fi

    stats="$("$MAGICK" identify -format '%[fx:mean] %[fx:standard_deviation]' "$file" 2>/dev/null || true)"
    read -r mean std <<< "$stats"
    [[ -n "${mean:-}" && -n "${std:-}" ]] || return 1

    awk \
        -v mean="$mean" \
        -v std="$std" \
        -v max_mean="$BLACK_MEAN_MAX" \
        -v max_std="$BLACK_STD_MAX" \
        'BEGIN { exit !(mean <= max_mean && std <= max_std) }'
}

reuse_previous_capture() {
    local file="$1"
    local rel prev

    [[ -n "$PREVIOUS_SNAPSHOT_DIR" ]] || return 1
    rel="${file#"$OUTPUT_DIR"/}"
    [[ "$rel" != "$file" ]] || return 1

    prev="$PREVIOUS_SNAPSHOT_DIR/$rel"
    [[ -f "$prev" ]] || return 1
    if image_is_blackish "$prev"; then
        return 1
    fi

    cp "$prev" "$file"
    LAST_CAPTURE_STATUS="cached"
    return 0
}

capture_window_image() {
    local id="$1"
    local workspace="$2"
    local file="$3"

    LAST_CAPTURE_STATUS="captured"

    if ! "$SCREENCAPTURE" -x -o "-l$id" "$file"; then
        return 1
    fi

    if image_is_blackish "$file"; then
        echo "Window $id captured black while hidden." >&2
        if reuse_previous_capture "$file"; then
            echo "Window $id reused previous valid capture." >&2
            return 0
        fi
        if [[ "$VISIBLE_RETRY" -eq 1 ]]; then
            echo "Window $id retrying on visible workspace $workspace." >&2
            "$AEROSPACE" workspace "$workspace"
            sleep "$VISIBLE_RETRY_DELAY"
            if ! "$SCREENCAPTURE" -x -o "-l$id" "$file"; then
                return 1
            fi
            if image_is_blackish "$file"; then
                echo "Window $id still black after visible retry." >&2
                return 2
            fi
            LAST_CAPTURE_STATUS="captured-visible"
            return 0
        fi
        return 2
    fi

    return 0
}

tile_columns() {
    local count="$1"
    local layout="$2"

    if [[ "$layout" == h_tiles && "$count" -le 4 ]]; then
        echo "$count"
    elif [[ "$layout" == v_tiles && "$count" -le 4 ]]; then
        echo 1
    elif [[ "$count" -le 1 ]]; then
        echo 1
    elif [[ "$count" -le 4 ]]; then
        echo 2
    elif [[ "$count" -le 9 ]]; then
        echo 3
    elif [[ "$count" -le 16 ]]; then
        echo 4
    else
        echo 5
    fi
}

compose_workspace_snapshots() {
    if [[ ! -x "$MAGICK" ]]; then
        echo "ImageMagick 'magick' is required for --compose." >&2
        return 1
    fi

    local ws ws_safe out layout count cols rows cell_w cell_h inner_w inner_h thumb
    for ws in "${WORKSPACES[@]}"; do
        local files=()
        while IFS= read -r file; do
            [[ -n "$file" && -f "$file" ]] && files+=("$file")
        done < <(workspace_files "$ws")

        ws_safe="$(sanitize "$ws")"
        out="$OUTPUT_DIR/workspace-${ws_safe}.png"
        count="${#files[@]}"

        if [[ "$count" -eq 0 ]]; then
            if reuse_previous_workspace_overview "$ws" "$out"; then
                continue
            fi
            "$MAGICK" -quiet -size "${COMPOSE_WIDTH}x${COMPOSE_HEIGHT}" xc:'#111111' "$out"
            continue
        fi

        layout="$(workspace_root_layout "$ws")"
        cols="$(tile_columns "$count" "$layout")"
        rows=$(( (count + cols - 1) / cols ))
        cell_w=$(( (COMPOSE_WIDTH - COMPOSE_GAP * (cols + 1)) / cols ))
        cell_h=$(( (COMPOSE_HEIGHT - COMPOSE_GAP * (rows + 1)) / rows ))
        inner_w=$(( cell_w - COMPOSE_GAP ))
        inner_h=$(( cell_h - COMPOSE_GAP ))
        if [[ "$inner_w" -lt 80 ]]; then inner_w="$cell_w"; fi
        if [[ "$inner_h" -lt 60 ]]; then inner_h="$cell_h"; fi
        thumb="${inner_w}x${inner_h}"

        local tmpdir
        tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/aerospace-compose.XXXXXX")"

        local index=0
        local file cell row
        for file in "${files[@]}"; do
            cell="$tmpdir/cell-$(printf '%04d' "$index").png"
            "$MAGICK" -quiet "$file" \
                -auto-orient \
                -thumbnail "$thumb" \
                -background '#111111' \
                -gravity center \
                -extent "${inner_w}x${inner_h}" \
                -bordercolor '#222222' \
                -border "$((COMPOSE_GAP / 2))" \
                -gravity center \
                -extent "${cell_w}x${cell_h}" \
                "$cell"
            index=$((index + 1))
        done

        while (( index % cols != 0 )); do
            cell="$tmpdir/cell-$(printf '%04d' "$index").png"
            "$MAGICK" -quiet -size "${cell_w}x${cell_h}" xc:'#111111' "$cell"
            index=$((index + 1))
        done

        local total="$index"
        for (( row = 0; row < rows; row++ )); do
            local row_files=()
            for (( col = 0; col < cols; col++ )); do
                row_files+=("$tmpdir/cell-$(printf '%04d' "$((row * cols + col))").png")
            done
            "$MAGICK" -quiet "${row_files[@]}" +append "$tmpdir/row-$(printf '%04d' "$row").png"
        done

        local row_images=()
        for (( row = 0; row < rows; row++ )); do
            row_images+=("$tmpdir/row-$(printf '%04d' "$row").png")
        done
        "$MAGICK" -quiet "${row_images[@]}" -append \
            -background '#111111' \
            -gravity center \
            -extent "${COMPOSE_WIDTH}x${COMPOSE_HEIGHT}" \
            "$out"
        safe_rm_tree "$tmpdir"
    done
}

restore_workspace() {
    if [[ -n "${INITIAL_WORKSPACE:-}" ]]; then
        "$AEROSPACE" workspace "$INITIAL_WORKSPACE" >/dev/null 2>&1 || true
    fi
}

cleanup() {
    restore_workspace
    if [[ -n "${TEMP_OUTPUT_DIR:-}" && -d "$TEMP_OUTPUT_DIR" && "$TEMP_OUTPUT_DIR" != "$PROMOTED_OUTPUT_DIR" ]]; then
        safe_rm_tree "$TEMP_OUTPUT_DIR" || true
    fi
}

capture_screen_snapshots() {
    INITIAL_WORKSPACE="$("$AEROSPACE" list-workspaces --focused | sed -n '1p')"

    printf 'timestamp\tworkspace\twindow_id\tapp_id\tapp_name\twindow_title\twindow_layout\twindow_parent_container_layout\tworkspace_root_container_layout\tfile\tstatus\n' > "$MANIFEST"

    local ws file
    for ws in "${WORKSPACES[@]}"; do
        file="$OUTPUT_DIR/workspace-$(sanitize "$ws").png"
        "$AEROSPACE" workspace "$ws"
        sleep "$DELAY"
        if "$SCREENCAPTURE" "${CAPTURE_ARGS[@]}" "$file"; then
            CAPTURED_COUNT=$((CAPTURED_COUNT + 1))
            printf '%s\t%s\t\t\t\t\t\t\t\t%s\tcaptured\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$ws" "$file" >> "$MANIFEST"
        else
            printf '%s\t%s\t\t\t\t\t\t\t\t%s\tfailed\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$ws" "$file" >> "$MANIFEST"
        fi
    done
}

capture_window_snapshots() {
    local window_output line id app_id app_name workspace title window_layout parent_layout root_layout ws_dir file safe_app status
    local selected_window_count=0
    window_output="$(
        "$AEROSPACE" list-windows --all --format "%{window-id}${SEPARATOR}%{app-bundle-id}${SEPARATOR}%{app-name}${SEPARATOR}%{workspace}${SEPARATOR}%{window-title}${SEPARATOR}%{window-layout}${SEPARATOR}%{window-parent-container-layout}${SEPARATOR}%{workspace-root-container-layout}"
    )"

    printf 'timestamp\tworkspace\twindow_id\tapp_id\tapp_name\twindow_title\twindow_layout\twindow_parent_container_layout\tworkspace_root_container_layout\tfile\tstatus\n' > "$MANIFEST"

    local ws
    for ws in "${WORKSPACES[@]}"; do
        mkdir -p "$OUTPUT_DIR/workspace-$(sanitize "$ws")"
    done

    while IFS="$SEPARATOR" read -r id app_id app_name workspace title window_layout parent_layout root_layout; do
        [[ -n "${id:-}" ]] || continue
        workspace_is_selected "$workspace" || continue
        selected_window_count=$((selected_window_count + 1))

        ws_dir="$OUTPUT_DIR/workspace-$(sanitize "$workspace")"
        safe_app="$(sanitize "${app_name:-window}")"
        file="$ws_dir/window-${id}-${safe_app}.png"

        if capture_window_image "$id" "$workspace" "$file"; then
            CAPTURED_COUNT=$((CAPTURED_COUNT + 1))
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$workspace" "$id" "$app_id" "$app_name" "$title" "$window_layout" "$parent_layout" "$root_layout" "$file" "$LAST_CAPTURE_STATUS" >> "$MANIFEST"
        else
            status="failed"
            if [[ -f "$file" ]] && image_is_blackish "$file"; then
                status="failed-black"
                rm -f "$file"
            fi
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$workspace" "$id" "$app_id" "$app_name" "$title" "$window_layout" "$parent_layout" "$root_layout" "$file" "$status" >> "$MANIFEST"
        fi
    done <<< "$window_output"

    if [[ "$COMPOSE" -eq 1 ]]; then
        if [[ "$selected_window_count" -gt 0 && "$CAPTURED_COUNT" -eq 0 ]]; then
            echo "No windows captured." >&2
            return 1
        fi
        compose_workspace_snapshots
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --configured)
            MODE="configured"
            shift
            ;;
        --existing)
            MODE="existing"
            shift
            ;;
        --current)
            CURRENT_ONLY=1
            shift
            ;;
        --history)
            CURRENT_ONLY=0
            shift
            ;;
        --windows)
            CAPTURE_MODE="windows"
            shift
            ;;
        --screen)
            CAPTURE_MODE="screen"
            shift
            ;;
        --compose)
            COMPOSE=1
            shift
            ;;
        --no-compose)
            COMPOSE=0
            shift
            ;;
        --notify)
            NOTIFY=1
            shift
            ;;
        --black-threshold)
            if [[ $# -lt 3 ]]; then
                echo "Missing values for $1" >&2
                usage
                exit 1
            fi
            BLACK_MEAN_MAX="$2"
            BLACK_STD_MAX="$3"
            shift 3
            ;;
        --visible-retry)
            VISIBLE_RETRY=1
            shift
            ;;
        --visible-retry-delay)
            if [[ $# -lt 2 ]]; then
                echo "Missing value for $1" >&2
                usage
                exit 1
            fi
            VISIBLE_RETRY_DELAY="$2"
            shift 2
            ;;
        -o|--output)
            if [[ $# -lt 2 ]]; then
                echo "Missing value for $1" >&2
                usage
                exit 1
            fi
            OUTPUT_ROOT="$2"
            shift 2
            ;;
        --delay)
            if [[ $# -lt 2 ]]; then
                echo "Missing value for $1" >&2
                usage
                exit 1
            fi
            DELAY="$2"
            shift 2
            ;;
        --main)
            CAPTURE_ARGS+=("-m")
            shift
            ;;
        --display)
            if [[ $# -lt 2 ]]; then
                echo "Missing value for $1" >&2
                usage
                exit 1
            fi
            CAPTURE_ARGS+=("-D$2")
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            while [[ $# -gt 0 ]]; do
                WORKSPACES+=("$1")
                shift
            done
            ;;
        -*)
            echo "Unknown option: $1" >&2
            usage
            exit 1
            ;;
        *)
            WORKSPACES+=("$1")
            shift
            ;;
    esac
done

if [[ ${#WORKSPACES[@]} -eq 0 ]]; then
    case "$MODE" in
        configured)
            append_workspaces "$(configured_workspaces | awk 'NF && !seen[$0]++')"
            ;;
        existing)
            append_workspaces "$(existing_workspaces | awk 'NF && !seen[$0]++')"
            ;;
        all)
            append_workspaces "$({ configured_workspaces; existing_workspaces; } | awk 'NF && !seen[$0]++')"
            ;;
    esac
fi

if [[ ${#WORKSPACES[@]} -eq 0 ]]; then
    echo "No workspaces found." >&2
    exit 1
fi

RUN_ID="$(date '+%Y%m%d-%H%M%S')"
if [[ "$CURRENT_ONLY" -eq 1 ]]; then
    OUTPUT_DIR="$OUTPUT_ROOT/current"
else
    OUTPUT_DIR="$OUTPUT_ROOT/$RUN_ID"
fi
MANIFEST="$OUTPUT_DIR/manifest.tsv"

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "Output: $OUTPUT_DIR"
    if [[ "$CAPTURE_MODE" == "screen" ]]; then
        for ws in "${WORKSPACES[@]}"; do
            file="$OUTPUT_DIR/workspace-$(sanitize "$ws").png"
            echo "aerospace workspace '$ws'"
            echo "screencapture ${CAPTURE_ARGS[*]} '$file'"
        done
    else
        echo "aerospace list-windows --all"
        echo "screencapture -x -o -l<window-id> '$OUTPUT_DIR/workspace-<workspace>/window-<window-id>-<app-name>.png'"
        if [[ "$VISIBLE_RETRY" -eq 1 ]]; then
            echo "aerospace workspace '<workspace>' # only for black-capture retry"
        else
            echo "black captures reuse previous valid images or are excluded"
        fi
        if [[ "$COMPOSE" -eq 1 ]]; then
            echo "magick compose cells ... '$OUTPUT_DIR/workspace-<workspace>.png'"
        fi
    fi
    exit 0
fi

if [[ "$CURRENT_ONLY" -eq 1 ]]; then
    mkdir -p "$OUTPUT_ROOT"
    PREVIOUS_SNAPSHOT_DIR="$(resolved_current_snapshot_dir || true)"
    TEMP_OUTPUT_DIR="$(mktemp -d "$OUTPUT_ROOT/.next-${RUN_ID}.XXXXXX")"
    OUTPUT_DIR="$TEMP_OUTPUT_DIR"
    MANIFEST="$OUTPUT_DIR/manifest.tsv"
fi

mkdir -p "$OUTPUT_DIR"
trap cleanup EXIT

case "$CAPTURE_MODE" in
    screen)
        capture_screen_snapshots
        ;;
    windows)
        capture_window_snapshots
        ;;
    *)
        echo "Unknown capture mode: $CAPTURE_MODE" >&2
        exit 1
        ;;
esac

if [[ "$CURRENT_ONLY" -eq 1 ]]; then
    FINAL_OUTPUT_DIR="$OUTPUT_ROOT/.current-${RUN_ID}"
    CURRENT_LINK="$OUTPUT_ROOT/current"
    NEXT_LINK="$OUTPUT_ROOT/.current-link-$$"
    PREVIOUS_CURRENT=""

    if [[ -e "$FINAL_OUTPUT_DIR" || -L "$FINAL_OUTPUT_DIR" ]]; then
        safe_rm_tree "$FINAL_OUTPUT_DIR"
    fi
    mv "$OUTPUT_DIR" "$FINAL_OUTPUT_DIR"
    PROMOTED_OUTPUT_DIR="$FINAL_OUTPUT_DIR"
    TEMP_OUTPUT_DIR=""

    if [[ -f "$FINAL_OUTPUT_DIR/manifest.tsv" ]]; then
        awk -F '\t' -v OFS='\t' -v old="$OUTPUT_DIR" -v new="$FINAL_OUTPUT_DIR" '
            NR > 1 && index($10, old) == 1 {
                $10 = new substr($10, length(old) + 1)
            }
            { print }
        ' "$FINAL_OUTPUT_DIR/manifest.tsv" > "$FINAL_OUTPUT_DIR/.manifest.tsv.tmp"
        mv "$FINAL_OUTPUT_DIR/.manifest.tsv.tmp" "$FINAL_OUTPUT_DIR/manifest.tsv"
    fi

    if [[ -e "$CURRENT_LINK" && ! -L "$CURRENT_LINK" ]]; then
        PREVIOUS_CURRENT="$OUTPUT_ROOT/.previous-current-$$"
        mv "$CURRENT_LINK" "$PREVIOUS_CURRENT"
    fi

    ln -s "$(basename "$FINAL_OUTPUT_DIR")" "$NEXT_LINK"
    if [[ -L "$CURRENT_LINK" ]]; then
        rm -f "$CURRENT_LINK"
    fi
    mv -f "$NEXT_LINK" "$CURRENT_LINK"

    if [[ -n "$PREVIOUS_CURRENT" && -e "$PREVIOUS_CURRENT" ]]; then
        safe_rm_tree "$PREVIOUS_CURRENT"
    fi

    CURRENT_TARGET="$(readlink "$CURRENT_LINK" || true)"
    for old in "$OUTPUT_ROOT"/20[0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9] "$OUTPUT_ROOT"/.current-*; do
        [[ -e "$old" || -L "$old" ]] || continue
        if [[ "$(basename "$old")" == "$CURRENT_TARGET" ]]; then
            continue
        fi
        safe_rm_tree "$old"
    done

    OUTPUT_DIR="$CURRENT_LINK"
fi

if [[ "$NOTIFY" -eq 1 ]]; then
    "$OSASCRIPT" -e "display notification \"Saved ${#WORKSPACES[@]} workspace screenshots\" with title \"AeroSpace\"" >/dev/null 2>&1 || true
fi
echo "$OUTPUT_DIR"
