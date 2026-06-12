#!/usr/bin/env bash
# Claude Code agent adapter, VISION track: full hyprctl IPC access plus the
# ability to look at the desktop whenever it wants (hb-look -> Read the PNG).
set -euo pipefail

exec claude -p "You are operating a Hyprland Wayland compositor instance.
The environment variable HYPRLAND_INSTANCE_SIGNATURE is already set, so every
plain 'hyprctl' command targets the correct instance - never unset or change it.
Inspect state with 'hyprctl -j clients / workspaces / activewindow / getoption'.
Act with 'hyprctl dispatch ...' and 'hyprctl keyword ...'. To open terminal
windows use: hyprctl dispatch exec -- 'alacritty --class hyprbench --title NAME -e sleep 1000'.

VISION TRACK: you may look at the desktop at any time by running 'hb-look',
which captures a screenshot and prints the PNG path - then view that file
with the Read tool. Look whenever it helps you ground or verify your actions.

After acting, verify the state actually changed before finishing.

TASK: $HB_INSTRUCTION" \
    --allowedTools "Bash,Read" \
    --max-turns 25
