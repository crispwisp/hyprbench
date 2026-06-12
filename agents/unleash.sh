#!/usr/bin/env bash
# Universal agent adapter: runs any agent CLI through unleash
# (github.com/heiervang-technologies/unleash) - the unified agent runner.
# This is the canonical way to run hyperbench against different agents:
#
#   HB_UNLEASH_PROFILE=claude bin/hyperbench run --agent agents/unleash.sh
#   HB_UNLEASH_PROFILE=codex  bin/hyperbench run --agent agents/unleash.sh --track vision
#
# Env: HB_UNLEASH_PROFILE  agent profile (claude, codex, gemini, opencode,
#                          antigravity, or custom; default claude)
#      HB_UNLEASH_MODEL    optional model override
# Track rules are injected into the prompt based on HB_TRACK.
set -euo pipefail

profile=${HB_UNLEASH_PROFILE:-claude}
extra=()
[[ -n ${HB_UNLEASH_MODEL:-} ]] && extra+=(-m "$HB_UNLEASH_MODEL")

if [[ ${HB_TRACK:-headless} == "vision" ]]; then
    track_rules="VISION TRACK: you may look at the desktop at any time by running 'hb-look',
which captures a screenshot and prints the PNG path - then view that file with
your image-reading capability. Look whenever it helps you ground or verify."
else
    track_rules="HEADLESS TRACK RULES: you must never view images or screenshots directly.
If you need to see the screen, run 'hb-look --text' (ASCII rendering) or
'hb-look --ocr' (extracted text) - text output only."
fi

exec unleash "$profile" "${extra[@]}" -p "You are operating a Hyprland Wayland compositor instance.
$track_rules
The environment variable HYPRLAND_INSTANCE_SIGNATURE is already set, so every
plain 'hyprctl' command targets the correct instance - never unset or change it.
Inspect state with 'hyprctl -j clients / workspaces / activewindow / getoption'.
Act with 'hyprctl dispatch ...' and 'hyprctl keyword ...'. To open terminal
windows use: hyprctl dispatch exec -- 'alacritty --class hyprbench --title NAME -e sleep 1000'.
If the task asks a question, write the bare answer (no prose) to the file
\$HB_ANSWER_FILE (already exported).
After acting, verify the state actually changed before finishing.

TASK: $HB_INSTRUCTION"
