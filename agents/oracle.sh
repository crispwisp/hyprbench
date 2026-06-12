#!/usr/bin/env bash
# Oracle agent: executes the task's reference solution verbatim.
# Used by `hyperbench validate` to prove the harness and verifiers work.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
[[ -r $ROOT/lib/browser.sh ]] && source "$ROOT/lib/browser.sh"
[[ -r $ROOT/lib/apps.sh ]] && source "$ROOT/lib/apps.sh"
set -e
eval "$(jq -r '.oracle[]' "$HB_TASK_FILE")"
