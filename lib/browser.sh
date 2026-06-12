#!/usr/bin/env bash
# hyprbench browser-track helpers (DRAFT — proposed by wisp).
# Sourced after lib/common.sh. Drives a Chromium pinned to a debugging port
# inside the bench instance; verifiers assert DOM state over CDP instead of
# pixels. Fixture pages live in fixtures/browser/ and are loaded as file://
# URLs, so runs are hermetic — no network.

HB_CDP_PORT=${HB_CDP_PORT:-9333}
HB_BROWSER=${HB_BROWSER:-chromium}
HB_CDP=${HB_ROOT:+$HB_ROOT/lib/cdp.mjs}
HB_CDP=${HB_CDP:-$(dirname "${BASH_SOURCE[0]}")/cdp.mjs}

# hb_browser_launch [FIXTURE] - start the browser inside the bench instance
# with a throwaway profile, optionally opening fixtures/browser/FIXTURE.
# Waits until the debugging port answers and a page target exists.
hb_browser_launch() {
    local url="" i browser_bin
    # dispatch-exec children inherit the COMPOSITOR env, not ours — in host
    # mode that env predates mise shims etc. Resolve to an absolute path in
    # snippet context so the requires gate and the launch can never disagree.
    browser_bin=$(command -v "$HB_BROWSER") || {
        echo "hb_browser_launch: cannot resolve browser '$HB_BROWSER'" >&2
        return 1
    }
    # refuse to launch when something else already owns the CDP port —
    # otherwise every hb_cdp_eval silently talks to the WRONG browser while
    # input goes to the right window (observed; cost four debugging rounds)
    if curl -s -m 1 "http://127.0.0.1:$HB_CDP_PORT/json/version" >/dev/null 2>&1; then
        echo "hb_browser_launch: port $HB_CDP_PORT already owned by another CDP endpoint — kill it or set HB_CDP_PORT" >&2
        return 1
    fi
    [[ -n ${1:-} ]] && url="file://${HB_ROOT:-$PWD}/fixtures/browser/$1"
    # Deterministic path, NOT mktemp: setup/verify/teardown run in separate
    # shells, so a random path chosen in setup is unknowable in teardown —
    # that exact bug leaked 144 profiles (~3GB) into /tmp across runs and
    # tripped the tmpfs quota. Derivable-per-port means any phase can clean.
    HB_BROWSER_PROFILE=${HB_BROWSER_PROFILE:-${HB_TASK_TMPDIR:-${TMPDIR:-/tmp}}/hb-browser-$HB_CDP_PORT}
    rm -rf "$HB_BROWSER_PROFILE"
    # exec via the compositor so the window maps inside the bench instance
    hyprctl dispatch exec -- \
        "$browser_bin --remote-debugging-port=$HB_CDP_PORT \
         --user-data-dir=$HB_BROWSER_PROFILE --no-first-run \
         --force-device-scale-factor=1 \
         --disable-session-crashed-bubble $url" >/dev/null
    for ((i = 0; i < 75; i++)); do
        hb_cdp_eval 'true' >/dev/null 2>&1 && return 0
        sleep 0.2
    done
    echo "hb_browser_launch: debugging port $HB_CDP_PORT never answered" >&2
    return 1
}

hb_browser_kill() {
    # derive the profile the same way launch does, so teardown (a fresh
    # shell — phases don't share variables) can always find and remove it
    local i prof=${HB_BROWSER_PROFILE:-${HB_TASK_TMPDIR:-${TMPDIR:-/tmp}}/hb-browser-$HB_CDP_PORT}
    pkill -f -- "--user-data-dir=$prof" 2>/dev/null || true
    pkill -f -- "--remote-debugging-port=$HB_CDP_PORT" 2>/dev/null || true
    # chromium keeps writing the profile while dying — wait it out, then
    # retry the rm (a racing write can resurrect a dir mid-removal)
    for ((i = 0; i < 25; i++)); do
        pgrep -f -- "--user-data-dir=$prof" >/dev/null 2>&1 || break
        sleep 0.2
    done
    rm -rf "$prof" 2>/dev/null || { sleep 0.5; rm -rf "$prof"; }
    return 0
}

# hb_seed - per-task layout seed for seeded fixtures. Uses the runner's
# HB_SEED when exported (reproducible runs); otherwise random per task so
# layouts cannot be memorized.
hb_seed() {
    echo "${HB_SEED:-$((RANDOM % 100000 + 1))}"
}

# hb_pin_browser_geometry [W H X Y] - float the bench browser window and pin
# exact geometry, so screenshot pixel coordinates are deterministic for the
# vision track (pairs with --force-device-scale-factor=1 at launch).
hb_pin_browser_geometry() {
    local w=${1:-1000} h=${2:-700} x=${3:-100} y=${4:-50} i addr=""
    for ((i = 0; i < 50; i++)); do
        addr=$(hyprctl -j clients |
            jq -r '[.[] | select(.class | test("chromium"; "i"))][0].address // empty')
        [[ -n $addr ]] && break
        sleep 0.2
    done
    [[ -n $addr ]] || { echo "hb_pin_browser_geometry: no browser window" >&2; return 1; }
    hyprctl dispatch setfloating "address:$addr" >/dev/null
    hyprctl dispatch resizewindowpixel "exact $w $h,address:$addr" >/dev/null
    hyprctl dispatch movewindowpixel "exact $x $y,address:$addr" >/dev/null
}

# hb_cdp_eval EXPR - evaluate JS in the page, print the result as JSON.
hb_cdp_eval() {
    node "$HB_CDP" "$HB_CDP_PORT" "$1"
}

# hb_assert_page EXPR [JQ_EXPR] - evaluate EXPR in the page and assert
# JQ_EXPR (default: truthiness) over the JSON result.
# Example: hb_assert_page 'document.querySelector("#username").value' '. == "wisp"'
hb_assert_page() {
    hb_cdp_eval "$1" | jq -e "${2:-.}" >/dev/null
}

# hb_wait_page EXPR [TIMEOUT] - wait until EXPR is truthy in the page.
hb_wait_page() {
    local expr=$1 timeout=${2:-10} i
    for ((i = 0; i < timeout * 5; i++)); do
        hb_cdp_eval "$expr" 2>/dev/null | jq -e . >/dev/null && return 0
        sleep 0.2
    done
    echo "hb_wait_page: timed out on: $expr" >&2
    return 1
}
