#!/usr/bin/env bash
# Oracle agent: executes the task's reference solution verbatim.
# Used by `hyperbench validate` to prove the harness and verifiers work.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
set -e
eval "$(jq -r '.oracle[]' "$HB_TASK_FILE")"
