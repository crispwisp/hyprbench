#!/usr/bin/env bash
# hyperbench desktop-app helpers: mpv (JSON IPC socket) and Steam (CEF CDP).
# Sourced after lib/common.sh and lib/browser.sh (steam helpers reuse cdp.mjs).
# Philosophy as everywhere else: verifiers read application state through the
# app's own introspection channel, never pixels.

# --- mpv -------------------------------------------------------------------
# mpv is fully scriptable over --input-ipc-server: every property (pause,
# time-pos, filename, volume, ...) is readable and settable as JSON.

HB_MPV_SOCK=${HB_MPV_SOCK:-${TMPDIR:-/tmp}/hb-mpv.sock}

# hb_media_fixture [SECONDS] - generate procedural test media (testsrc video
# + sine audio), print its path. Nothing binary lives in the repo.
hb_media_fixture() {
    local dur=${1:-30} out="${TMPDIR:-/tmp}/hb-media-${1:-30}s.mp4"
    [[ -s $out ]] || ffmpeg -loglevel error -y \
        -f lavfi -i "testsrc=duration=$dur:size=640x360:rate=24" \
        -f lavfi -i "sine=frequency=440:duration=$dur" \
        -c:v libx264 -preset ultrafast -c:a aac "$out" || return 1
    echo "$out"
}

# hb_mpv_launch FILE [EXTRA_MPV_ARGS...] - start mpv on FILE inside the bench
# instance with the IPC socket, wait until the socket answers.
hb_mpv_launch() {
    local file=$1 i; shift || true
    rm -f "$HB_MPV_SOCK"
    # --log-file: mpv's own account of a failed start is otherwise lost —
    # dispatch-exec'd stderr goes to the compositor log, not the phase log
    hyprctl dispatch exec -- \
        "mpv --input-ipc-server=$HB_MPV_SOCK --loop=inf \
         --log-file=${TMPDIR:-/tmp}/hb-mpv-last.log $* -- $file" >/dev/null
    # 30s, not 10: under load (parallel validation, ffmpeg generating the
    # fixture in the same setup) mpv can take >10s to bring the socket up —
    # observed live; the socket then answers fine
    for ((i = 0; i < 150; i++)); do
        [[ -S $HB_MPV_SOCK ]] && hb_mpv_get pause >/dev/null 2>&1 && return 0
        sleep 0.2
    done
    echo "hb_mpv_launch: IPC socket never answered at $HB_MPV_SOCK" >&2
    return 1
}

# hb_mpv_cmd ARG... - run one mpv command, print the raw JSON reply.
# Args that parse as JSON pass through typed (true, 20); the rest as strings.
# NB: `try fromjson catch .` is WRONG here — catch's input is the error
# MESSAGE, not the original value, so unparseable strings like get_property
# become jq error text and mpv rejects the command. Bind the value first.
# Example: hb_mpv_cmd set_property pause true
hb_mpv_cmd() {
    jq -nc '{command: [$ARGS.positional[] | . as $s | (try ($s | fromjson) catch $s)]}' --args "$@" |
        socat - "$HB_MPV_SOCK"
}

# hb_mpv_get PROP - print a property's value as JSON.
hb_mpv_get() {
    local reply
    reply=$(hb_mpv_cmd get_property "$1") || return 1
    jq -e 'select(.error == "success")' <<<"$reply" >/dev/null || return 1
    jq '.data' <<<"$reply"
}

# hb_assert_mpv PROP JQ_EXPR - assert JQ_EXPR over a property value.
# Example: hb_assert_mpv pause '. == true'
hb_assert_mpv() {
    hb_mpv_get "$1" | jq -e "$2" >/dev/null
}

hb_mpv_kill() {
    pkill -f -- "--input-ipc-server=$HB_MPV_SOCK" 2>/dev/null || true
    rm -f "$HB_MPV_SOCK"
    return 0
}

# --- steam -----------------------------------------------------------------
# Steam's UI is CEF. Launched with -cef-enable-debugging it serves CDP on
# port 8080 (pinned by steam, not configurable), multiple page targets —
# always pass a TARGET match (e.g. 'sign in') to disambiguate.

HB_STEAM_CDP_PORT=8080

# hb_steam_launch - start steam with CEF debugging inside the bench instance,
# wait for the CDP endpoint. Refuses if port 8080 is already owned.
hb_steam_launch() {
    local i
    if curl -s -m 1 "http://127.0.0.1:$HB_STEAM_CDP_PORT/json/version" >/dev/null 2>&1; then
        echo "hb_steam_launch: port $HB_STEAM_CDP_PORT already owned" >&2
        return 1
    fi
    local steam_bin
    steam_bin=$(command -v steam) || { echo "hb_steam_launch: no steam" >&2; return 1; }
    hyprctl dispatch exec -- "$steam_bin -cef-enable-debugging" >/dev/null
    # Gate on the SIGN-IN PAGE TARGET, not the endpoint: a bootstrapped steam
    # answers /json within seconds, long before the sign-in window exists —
    # gating on the endpoint hands oracle/verify a target that isn't there.
    for ((i = 0; i < 300; i++)); do
        if curl -s -m 1 "http://127.0.0.1:$HB_STEAM_CDP_PORT/json" 2>/dev/null |
            jq -e '[.[] | select(.type == "page") | .title] | any(test("sign in"; "i"))' >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.5
    done
    echo "hb_steam_launch: sign-in page target never appeared" >&2
    return 1
}

# hb_steam_eval EXPR [TARGET] - evaluate JS in a steam page (default: the
# sign-in window), print the result as JSON.
hb_steam_eval() {
    node "$HB_CDP" "$HB_STEAM_CDP_PORT" "$1" "${2:-sign in}"
}

# hb_assert_steam EXPR JQ_EXPR [TARGET] - assert over a steam page.
hb_assert_steam() {
    hb_steam_eval "$1" "${3:-sign in}" | jq -e "$2" >/dev/null
}

hb_steam_kill() {
    pkill -f steamwebhelper 2>/dev/null || true
    pkill -x steam 2>/dev/null || true
    local i
    for ((i = 0; i < 50; i++)); do
        pgrep -x steam >/dev/null 2>&1 || break
        sleep 0.2
    done
    return 0
}

# --- rendered labels (vision-only window references) ------------------------
# "Swap window 1 with window 6" is resolvable from hyprctl when the number is
# in the title. These helpers render the number INSIDE the window instead,
# with an opaque random title — the reference then exists only on screen,
# which makes spatial-reference prompts vision-track-only by construction.
# The digit→title mapping is recorded for verifiers in HB_LABELMAP. (An agent
# reading that file is out of bounds; it is harness state, not desktop state.)

HB_LABELMAP=${HB_LABELMAP:-${TMPDIR:-/tmp}/hb-labelmap}

# hb_banner_digit N - print one large block-glyph digit (0-9) on stdout.
hb_banner_digit() {
    local rows
    case $1 in
        0) rows=("███" "█ █" "█ █" "█ █" "███") ;;
        1) rows=(" █ " "██ " " █ " " █ " "███") ;;
        2) rows=("███" "  █" "███" "█  " "███") ;;
        3) rows=("███" "  █" "███" "  █" "███") ;;
        4) rows=("█ █" "█ █" "███" "  █" "  █") ;;
        5) rows=("███" "█  " "███" "  █" "███") ;;
        6) rows=("███" "█  " "███" "█ █" "███") ;;
        7) rows=("███" "  █" "  █" "  █" "  █") ;;
        8) rows=("███" "█ █" "███" "█ █" "███") ;;
        9) rows=("███" "█ █" "███" "  █" "███") ;;
        *) echo "hb_banner_digit: want 0-9, got '$1'" >&2; return 1 ;;
    esac
    # scale 3x wide, 2x tall so it reads in a screenshot of a small window
    local r line i ch
    for r in "${rows[@]}"; do
        line=""
        for ((i = 0; i < ${#r}; i++)); do
            ch=${r:i:1}
            line+="$ch$ch$ch"
        done
        printf '%s\n%s\n' "$line" "$line"
    done
}

# hb_spawn_label N [CLASS] - spawn a terminal rendering digit N as content,
# titled with an opaque random string. Records "N TITLE" in HB_LABELMAP.
hb_spawn_label() {
    local n=$1 class=${2:-hblabel} bannerfile title
    bannerfile=$(mktemp "${TMPDIR:-/tmp}/hb-label-XXXXXX")
    hb_banner_digit "$n" >"$bannerfile" || { rm -f "$bannerfile"; return 1; }
    title="hb-$(od -An -tx1 -N4 /dev/urandom | tr -d ' \n')"
    hyprctl dispatch exec -- "$HB_TERMINAL --class $class --title $title \
        -e bash -c 'clear; cat $bannerfile; sleep 1000'" >/dev/null
    hb_wait_title "$title" 15 || return 1
    echo "$n $title" >>"$HB_LABELMAP"
}

# hb_label_title N - print the window title behind rendered label N.
hb_label_title() {
    awk -v n="$1" '$1 == n {print $2; exit}' "$HB_LABELMAP"
}

# --- terminal topology (termtopo) ------------------------------------------

# hb_assert_term_cwds CWD... - assert that for EVERY given CWD there exists a
# terminal client in the bench instance whose shell (any descendant) has it
# as working directory. Proves a migration preserved the shells' state.
hb_assert_term_cwds() {
    local want pid found
    for want in "$@"; do
        found=0
        while read -r pid; do
            [[ -z $pid ]] && continue
            local d
            for d in $(pgrep -P "$pid" 2>/dev/null) "$pid"; do
                if [[ $(readlink "/proc/$d/cwd" 2>/dev/null) == "$want" ]]; then
                    found=1; break
                fi
            done
            ((found)) && break
        done < <(hyprctl -j clients | jq -r '.[].pid')
        ((found)) || { echo "hb_assert_term_cwds: no window shell in $want" >&2; return 1; }
    done
    return 0
}

# hb_assert_tmux_cwds SESSION CWD... - assert the tmux session exists and its
# panes' working directories cover every given CWD.
hb_assert_tmux_cwds() {
    local session=$1; shift
    tmux has-session -t "$session" 2>/dev/null || {
        echo "hb_assert_tmux_cwds: no session '$session'" >&2; return 1; }
    local paths want
    paths=$(tmux list-panes -s -t "$session" -F '#{pane_current_path}')
    for want in "$@"; do
        grep -qx "$want" <<<"$paths" || {
            echo "hb_assert_tmux_cwds: no pane in $want" >&2; return 1; }
    done
    return 0
}
