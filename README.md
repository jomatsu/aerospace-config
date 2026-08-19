# aerospace-config

AeroSpace (macOS tiling window manager) configuration and companion scripts.

Workspace definitions, app-to-workspace assignments, and keybindings are
generated from a single source of truth (`aerospace/aerospace.ts`) into
`~/.aerospace.toml`. The scripts directory holds the tools those bindings
invoke.

## Requirements

- [AeroSpace](https://github.com/nikitabobko/AeroSpace) — `brew install aerospace`
- [Deno](https://deno.com) — `brew install deno`

Optional:
- ImageMagick (`magick`) — only needed for workspace overview images in the snapshot script

## Install

```sh
git clone git@github.com:jomatsu/aerospace-config.git
cd aerospace-config
./install.sh
aerospace reload-config
```

`install.sh` runs `deno task setup` in `aerospace/`, which merges the template
(`aerospace/.aerospace.toml`) with the definitions in `aerospace/aerospace.ts`
and writes `~/.aerospace.toml`. The repository's actual path is injected into
the generated config, so the repo can live anywhere. If you move it, just run
`install.sh` again.

## Customization

The single source of truth is `aerospace/aerospace.ts`:

- `WORKSPACES` — workspace names and summon/move keybindings
- `APP_ASSIGNMENTS` — app bundle IDs (and optional window-title regexes) mapped to workspaces, with optional post-move layout commands

Edit the file, then regenerate:

```sh
cd aerospace
deno task setup
aerospace reload-config
```

The generated `~/.aerospace.toml` is not meant to be hand-edited — unmanaged
settings live in the template `aerospace/.aerospace.toml`.

### Refresh

`alt-0` (or `deno task refresh` in `aerospace/`) moves open windows to their
designated workspaces, applies post-move layout commands, and evicts stray
windows from reserved workspaces.

## Layout

```
aerospace/
  aerospace.ts        SSOT: workspaces, app assignments, bindings, refresh logic
  .aerospace.toml     template with markers; @REPO_ROOT@ is injected at setup
  deno.json           deno tasks: setup / refresh
scripts/
  aerospace-focus-workspace.sh      alt-left/alt-right workspace navigation
  aerospace-workspace-snapshot-request.sh  cheap "dirty marker" for debounced snapshots
  aerospace-workspace-snapshot.sh   screenshot each window / workspace into ~/Pictures
  aerospace-monitor-preset.sh       save/restore workspace-to-monitor layouts (service mode keys 1-3 / shift-1-3)
```

## Default keybindings

| Keys | Action |
| --- | --- |
| `alt-1..4`, `alt-q..r` | summon workspace |
| `alt-shift-1..4`, `alt-shift-q..r` | move focused window to workspace |
| `alt-left` / `alt-right` | focus previous / next workspace on the focused monitor |
| `alt-h/j/k/l` (+ `shift`) | focus / move within the workspace tree |
| `alt-slash` / `alt-comma` | cycle tiling / accordion layout |
| `alt-minus` / `alt-equal` | resize window |
| `alt-tab` / `alt-shift-tab` | workspace back-and-forth / next monitor |
| `alt-f` | toggle floating/tiling |
| `alt-0` | refresh workspace assignments |
| `alt-shift-;` | enter `service` mode (`esc` to quit) |

`service` mode: `r` reset layout, `f` toggle floating, `backspace` close all
but current, `s` snapshot workspaces, `1-3`/`shift-1-3` restore/save monitor
presets, arrows manage volume.

## Notes

- The app-to-workspace assignments are examples (Chrome profile names are
  placeholders). Change `APP_ASSIGNMENTS` in `aerospace.ts` to match your apps.
- The snapshot script stores captures under
  `~/Pictures/AeroSpace Workspaces/` (override with `-o`).
- Monitor presets are stored under `~/.config/aerospace/presets/`.