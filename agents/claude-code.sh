#!/usr/bin/env bash
# Claude Code agent adapter, HEADLESS track: solves the task with `claude -p`.
# Requires the claude CLI. The bench instance signature is already exported,
# so plain hyprctl calls inside the agent target the nested instance.
set -euo pipefail

exec claude -p "You are operating a Hyprland Wayland compositor instance.
HEADLESS TRACK RULES: you must never view images or screenshots directly.
If you need to see the screen, run 'hb-look --text' (ASCII rendering) or
'hb-look --ocr' (extracted text) - text output only.
The environment variable HYPRLAND_INSTANCE_SIGNATURE is already set, so every
plain 'hyprctl' command targets the correct instance - never unset or change it.
Inspect state with 'hyprctl -j clients / workspaces / activewindow / getoption'.
Act with 'hyprctl dispatch ...' and 'hyprctl keyword ...'. To open terminal
windows use: hyprctl dispatch exec -- 'alacritty --class hyprbench --title NAME -e sleep 1000'.
If the task asks a question, write the bare answer (no prose) to the file
\$HB_ANSWER_FILE (already exported).
After acting, verify the state actually changed before finishing.

TASK: $HB_INSTRUCTION" \
    --allowedTools "Bash" \
    --max-turns 25
