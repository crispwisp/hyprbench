#!/usr/bin/env bash
# hyperbench browser-track helpers (DRAFT — proposed by wisp).
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
    [[ -n ${1:-} ]] && url="file://${HB_ROOT:-$PWD}/fixtures/browser/$1"
    HB_BROWSER_PROFILE=$(mktemp -d "${TMPDIR:-/tmp}/hb-browser.XXXXXX")
    # exec via the compositor so the window maps inside the bench instance
    hyprctl dispatch exec -- \
        "$browser_bin --remote-debugging-port=$HB_CDP_PORT \
         --user-data-dir=$HB_BROWSER_PROFILE --no-first-run \
         --disable-session-crashed-bubble $url" >/dev/null
    for ((i = 0; i < 75; i++)); do
        hb_cdp_eval 'true' >/dev/null 2>&1 && return 0
        sleep 0.2
    done
    echo "hb_browser_launch: debugging port $HB_CDP_PORT never answered" >&2
    return 1
}

hb_browser_kill() {
    # kill by profile dir when we know it, else by our debugging port —
    # also makes this safe as a setup preamble to sweep a previous task's browser
    if [[ -n ${HB_BROWSER_PROFILE:-} ]]; then
        pkill -f -- "--user-data-dir=$HB_BROWSER_PROFILE" 2>/dev/null || true
        rm -rf "$HB_BROWSER_PROFILE"
    else
        pkill -f -- "--remote-debugging-port=$HB_CDP_PORT" 2>/dev/null || true
    fi
    return 0
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
