#!/usr/bin/env bash
# publish-leaderboard — push a run's results to the hyprbench HF Space.
#
#   scripts/publish-leaderboard.sh RESULTS_DIR [--note "text"]
#
# Reads results.jsonl (+ meta-*.json when present) from RESULTS_DIR, computes
# the aggregate row, upserts it into the Space's results.json (keyed by run
# label), and pushes. The Space renders it immediately — this is the live
# channel between matrix runs landing and the public board.
#
# Auth: hf_token line in ~/.local/share/wisp/credentials (never echoed).
set -euo pipefail

DIR=${1:?usage: publish-leaderboard.sh RESULTS_DIR [--note TEXT]}
NOTE=""
[[ ${2:-} == --note ]] && NOTE=${3:-}

SPACE=${HB_SPACE_DIR:-$HOME/ht/hb-space}
JSONL="$DIR/results.jsonl"
[[ -r $JSONL ]] || { echo "no results.jsonl in $DIR" >&2; exit 1; }

meta=$(cat "$DIR"/meta-*.json 2>/dev/null || echo '{}')

row=$(jq -s --argjson meta "$meta" --arg note "$NOTE" --arg date "$(date +%F)" '
  map(select(.status != "skip")) as $scored |
  {
    label: (.[0].agent // "run"),
    harness: ($meta.harness // $meta.agent_cli // "unleash"),
    harness_version: ($meta.versions.agent // $meta.cli_version // ""),
    model: ($meta.model // $meta.profile // .[0].agent),
    profile: ($meta.profile // ""),
    track: (.[0].track // "headless"),
    mode: (.[0].mode // "nested"),
    commit: ($meta.commit // "unknown"),
    date: ($meta.date // $date),
    scored: ($scored | length),
    passed: ($scored | map(select(.status == "pass")) | length),
    failed: ($scored | map(select(.status != "pass")) | length),
    skipped: (length - ($scored | length)),
    pass_rate: (($scored | map(select(.status == "pass")) | length) * 100 / ($scored | length) | floor),
    latency: {
      median: ($scored | map(.seconds) | sort | .[length/2|floor]),
      p90:    ($scored | map(.seconds) | sort | .[(length*0.9)|floor]),
      max:    (map(.seconds) | max),
      total:  (map(.seconds) | add)
    },
    note: $note
  }' "$JSONL")

cd "$SPACE"
git pull -q
jq --argjson row "$row" '
  .runs = ([.runs[] | select(.label != $row.label)] + [$row]) |
  .updated = (now | todate)
' results.json > results.json.tmp && mv results.json.tmp results.json

git add results.json
git commit -q -m "results: $(jq -r '.label + " " + (.pass_rate|tostring) + "% (" + .track + "/" + .mode + ")"' <<<"$row")"
git push -q
echo "published: $(jq -r '.label' <<<"$row") -> https://huggingface.co/spaces/crispwisp/hyprbench"
