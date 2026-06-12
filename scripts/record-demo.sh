#!/usr/bin/env bash
# record-demo — capture one task's oracle run inside a nested instance as mp4.
#
#   scripts/record-demo.sh TASK_ID OUT.mp4
#
# Launches a fresh nested Hyprland (hidden on the host via the aquamarine
# windowrule), records ITS display with wf-recorder, executes the task's
# setup -> oracle -> verify with the bench libs, then stops and cleans up.
# The clip shows exactly what an agent would see while solving the task.
set -euo pipefail

TASK=${1:?usage: record-demo.sh TASK_ID OUT.mp4}
OUT=${2:?usage: record-demo.sh TASK_ID OUT.mp4}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export HB_ROOT="$ROOT"
source "$ROOT/lib/common.sh"
[[ -r $ROOT/lib/browser.sh ]] && source "$ROOT/lib/browser.sh"
[[ -r $ROOT/lib/apps.sh ]] && source "$ROOT/lib/apps.sh"

task=$(jq -c --arg id "$TASK" '.[] | select(.id == $id)' "$ROOT"/tasks/*.json)
[[ -n $task ]] || { echo "no task '$TASK'" >&2; exit 1; }

sig=$(hb_launch_instance "$ROOT" "/tmp/hb-demo-hypr.log")
export HYPRLAND_INSTANCE_SIGNATURE=$sig
trap 'hb_kill_instance "$sig" >/dev/null 2>&1 || true' EXIT

wl=$(hb_wayland_display "$sig")
[[ -n $wl ]] || { echo "no wayland display for instance" >&2; exit 1; }

# per-task scratch like the runner provides
export HB_TASK_TMPDIR=$(mktemp -d /tmp/hb-demo.XXXXXX)
export HB_ANSWER_FILE="$HB_TASK_TMPDIR/answer"

WAYLAND_DISPLAY=$wl wf-recorder -y -f "$OUT" -r 24 >/dev/null 2>&1 &
REC=$!
sleep 1

run_lines() { while IFS= read -r l; do eval "$l"; done < <(jq -r ".$1[]? // empty" <<<"$task"); }
run_lines setup
sleep 1.5
run_lines oracle
sleep 1.5
if run_lines verify; then echo "verify: PASS"; else echo "verify: FAIL"; fi
sleep 1

kill -INT $REC 2>/dev/null; wait $REC 2>/dev/null || true
rm -rf "$HB_TASK_TMPDIR"
echo "recorded: $OUT ($(du -h "$OUT" | cut -f1))"
