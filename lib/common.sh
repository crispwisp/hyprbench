#!/usr/bin/env bash
# hyperbench shared helpers.
# Sourced by the runner and by task setup/oracle/verify snippets.
# All hyprctl calls target the instance in $HYPRLAND_INSTANCE_SIGNATURE.

HB_TERMINAL=${HB_TERMINAL:-alacritty}

# --- instance lifecycle (used by the runner) -------------------------------

# Launch a nested Hyprland instance with the bench config.
# Prints the new instance signature on stdout.
hb_launch_instance() {
    local root=$1 logfile=$2 before after sig i
    before=$(ls "$XDG_RUNTIME_DIR/hypr" 2>/dev/null || true)
    setsid Hyprland --config "$root/bench.conf" >"$logfile" 2>&1 &
    HB_HYPR_PID=$!
    for ((i = 0; i < 100; i++)); do
        after=$(ls "$XDG_RUNTIME_DIR/hypr" 2>/dev/null || true)
        sig=$(comm -13 <(sort <<<"$before") <(sort <<<"$after") | head -1)
        if [[ -n $sig && -S $XDG_RUNTIME_DIR/hypr/$sig/.socket.sock ]]; then
            if HYPRLAND_INSTANCE_SIGNATURE=$sig hyprctl monitors >/dev/null 2>&1; then
                # persist the PID: callers run us in a $() subshell, so a
                # global variable would be lost (audit finding)
                echo "$HB_HYPR_PID" >"$XDG_RUNTIME_DIR/hypr/$sig/hb_pid"
                hb_record_wayland_display "$sig"
                echo "$sig"
                return 0
            fi
        fi
        sleep 0.2
    done
    return 1
}

# Ask the instance for its WAYLAND_DISPLAY (needed by grim for the vision
# track) by exec'ing an env dump inside it. Best-effort; cached in the
# instance runtime dir.
hb_record_wayland_display() {
    local sig=$1 f="$XDG_RUNTIME_DIR/hypr/$sig/hb_wayland_display" i
    HYPRLAND_INSTANCE_SIGNATURE=$sig hyprctl dispatch exec -- \
        "sh -c 'echo \$WAYLAND_DISPLAY > $f'" >/dev/null 2>&1
    for ((i = 0; i < 25; i++)); do
        [[ -s $f ]] && return 0
        sleep 0.2
    done
    return 1
}

# hb_wayland_display [SIG] - print the instance's wayland socket name.
hb_wayland_display() {
    cat "$XDG_RUNTIME_DIR/hypr/${1:-$HYPRLAND_INSTANCE_SIGNATURE}/hb_wayland_display" 2>/dev/null
}

hb_kill_instance() {
    local sig=$1 pid i
    pid=$(cat "$XDG_RUNTIME_DIR/hypr/$sig/hb_pid" 2>/dev/null || true)
    HYPRLAND_INSTANCE_SIGNATURE=$sig hyprctl dispatch exit >/dev/null 2>&1 || true
    for ((i = 0; i < 25; i++)); do
        [[ ! -S $XDG_RUNTIME_DIR/hypr/$sig/.socket.sock ]] && break
        sleep 0.2
    done
    if [[ -n $pid ]]; then
        kill "$pid" 2>/dev/null
        # setsid made it a session leader; sweep the whole group so stray
        # clients (alacritty -e sleep) can't outlive a crashed compositor
        kill -- "-$pid" 2>/dev/null
    fi
    rm -rf "$XDG_RUNTIME_DIR/hypr/$sig" 2>/dev/null || true
    return 0
}

# --- host mode (run against a live session instead of a nested instance) ---

# Classes the bench owns; host-mode cleanup closes only these.
HB_OWNED_CLASSES='^(hyprbench|benchterm)$'

# hb_host_snapshot FILE - record everything tasks may mutate in a live session.
hb_host_snapshot() {
    {
        hyprctl -j getoption general:gaps_in | jq '{gaps_in: .custom}'
        hyprctl -j getoption general:border_size | jq '{border_size: .int}'
        hyprctl -j activeworkspace | jq '{active: .id}'
        hyprctl -j workspaces | jq '{workspaces: [.[] | {id, name}]}'
        hyprctl -j clients | jq '{addresses: [.[].address]}'
    } | jq -s 'add' >"$1"
}

# hb_host_cleanup [SNAPFILE] - close windows the bench (or the agent) created.
# With a snapshot: close every window that did not exist at snapshot time,
# whatever its class (agents may spawn terminals with default classes).
# Without: fall back to closing bench-owned classes.
hb_host_cleanup() {
    local snap=${1:-} i addr
    for ((i = 0; i < 50; i++)); do
        if [[ -n $snap && -r $snap ]]; then
            addr=$(hyprctl -j clients | jq -r --slurpfile s "$snap" \
                '($s[0].addresses // []) as $known
                 | [.[] | select(.address as $a | $known | index($a) | not)][0].address // empty')
        else
            addr=$(hyprctl -j clients |
                jq -r --arg re "$HB_OWNED_CLASSES" \
                    '[.[] | select(.class | test($re))][0].address // empty')
        fi
        [[ -z $addr ]] && return 0
        hyprctl dispatch closewindow "address:$addr" >/dev/null 2>&1
        sleep 0.2
    done
    echo "hb_host_cleanup: bench windows still open after timeout" >&2
    return 1
}

# hb_host_restore FILE - cleanup, then restore the snapshotted session state.
hb_host_restore() {
    local f=$1 id name cur
    hb_host_cleanup "$f"
    hyprctl keyword general:gaps_in "$(jq -r '.gaps_in' "$f")" >/dev/null
    hyprctl keyword general:border_size "$(jq -r '.border_size' "$f")" >/dev/null
    while IFS=$'\t' read -r id name; do
        cur=$(hyprctl -j workspaces |
            jq -r --argjson id "$id" '[.[] | select(.id == $id)][0].name // empty')
        [[ -n $cur && $cur != "$name" ]] &&
            hyprctl dispatch renameworkspace "$id $name" >/dev/null
    done < <(jq -r '.workspaces[] | select(.id > 0) | [.id, .name] | @tsv' "$f")
    hyprctl dispatch workspace "$(jq -r '.active' "$f")" >/dev/null
    return 0
}

# --- window helpers (used in setup / oracle snippets) ----------------------

# hb_spawn TITLE [CLASS] - spawn a terminal window inside the bench instance
# and wait until it is mapped.
hb_spawn() {
    local title=$1 class=${2:-hyprbench}
    hyprctl dispatch exec -- "$HB_TERMINAL --class $class --title $title -e sleep 1000" >/dev/null
    hb_wait_title "$title" 15
}

# hb_wait_title TITLE [TIMEOUT] - wait until a client with TITLE exists.
hb_wait_title() {
    local t=$1 timeout=${2:-10} i
    for ((i = 0; i < timeout * 5; i++)); do
        hyprctl -j clients | jq -e --arg t "$t" 'any(.[]; .title == $t)' >/dev/null && return 0
        sleep 0.2
    done
    echo "hb_wait_title: timed out waiting for '$t'" >&2
    return 1
}

# hb_wait_gone TITLE [TIMEOUT] - wait until no client with TITLE exists.
hb_wait_gone() {
    local t=$1 timeout=${2:-10} i
    for ((i = 0; i < timeout * 5; i++)); do
        hyprctl -j clients | jq -e --arg t "$t" 'any(.[]; .title == $t) | not' >/dev/null && return 0
        sleep 0.2
    done
    echo "hb_wait_gone: timed out waiting for '$t' to close" >&2
    return 1
}

# hb_close_matching JQ_SELECT [TIMEOUT] - close every window matching the jq
# selector (by address, so title collisions are safe) and wait until gone.
hb_close_matching() {
    local sel=$1 timeout=${2:-10} i addr
    for ((i = 0; i < timeout * 5; i++)); do
        addr=$(hyprctl -j clients | jq -r "[.[] | select($sel)][0].address // empty")
        [[ -z $addr ]] && return 0
        hyprctl dispatch closewindow "address:$addr" >/dev/null 2>&1
        sleep 0.2
    done
    echo "hb_close_matching: windows matching '$sel' still open" >&2
    return 1
}

# hb_wait_count N [TIMEOUT] - wait until at least N clients exist.
hb_wait_count() {
    local n=$1 timeout=${2:-10} i
    for ((i = 0; i < timeout * 5; i++)); do
        hyprctl -j clients | jq -e --argjson n "$n" 'length >= $n' >/dev/null && return 0
        sleep 0.2
    done
    echo "hb_wait_count: timed out waiting for $n clients" >&2
    return 1
}

# --- assertion helpers (used in verify snippets) ---------------------------

# hb_assert_client TITLE JQ_EXPR - assert JQ_EXPR over the client with TITLE.
# Example: hb_assert_client Target '.workspace.id == 4'
hb_assert_client() {
    local t=$1 expr=$2
    hyprctl -j clients | jq -e --arg t "$t" \
        "[.[] | select(.title == \$t)][0] | ($expr)" >/dev/null
}

# hb_assert_clients JQ_EXPR - assert JQ_EXPR over the full clients array.
hb_assert_clients() {
    hyprctl -j clients | jq -e "$1" >/dev/null
}

# hb_assert_active JQ_EXPR - assert over the active window object.
hb_assert_active() {
    hyprctl -j activewindow | jq -e "$1" >/dev/null
}

# hb_assert_workspaces JQ_EXPR - assert over the workspaces array.
hb_assert_workspaces() {
    hyprctl -j workspaces | jq -e "$1" >/dev/null
}

# hb_assert_new JQ_SELECT [COUNT_TEST] - assert over clients that did NOT
# exist at baseline (HB_BASELINE is captured by the runner after task setup).
# Baseline-relative checks keep verifiers correct in host mode, where
# unrelated windows already exist.
# Example: hb_assert_new '.class == "benchterm"'        # at least one new
#          hb_assert_new '.workspace.id == 5' '== 2'    # exactly two new
hb_assert_new() {
    local sel=$1 cnt=${2:->= 1}
    if [[ -z ${HB_BASELINE:-} || ! -r ${HB_BASELINE:-} ]]; then
        echo "hb_assert_new: HB_BASELINE not set/readable" >&2
        return 1
    fi
    hyprctl -j clients | jq -e --slurpfile base "$HB_BASELINE" \
        "[\$base[0][].address] as \$known
         | [.[] | select(.address as \$a | \$known | index(\$a) | not) | select($sel)]
         | length $cnt" >/dev/null
}

# hb_assert_baseline_gone JQ_SELECT - assert that every baseline client
# matching the selector no longer exists (by address). The complement of
# hb_assert_new: use it for "close window X" tasks, where the windows that
# must disappear are IN the baseline.
hb_assert_baseline_gone() {
    local sel=$1
    if [[ -z ${HB_BASELINE:-} || ! -r ${HB_BASELINE:-} ]]; then
        echo "hb_assert_baseline_gone: HB_BASELINE not set/readable" >&2
        return 1
    fi
    hyprctl -j clients | jq -e --slurpfile base "$HB_BASELINE" \
        "[.[].address] as \$alive
         | [\$base[0][] | select($sel) | .address]
         | all(. as \$a | \$alive | index(\$a) | not)" >/dev/null
}

# hb_assert_activeworkspace JQ_EXPR - assert over the active workspace object.
hb_assert_activeworkspace() {
    hyprctl -j activeworkspace | jq -e "$1" >/dev/null
}

# hb_assert_near TITLE FIELD X Y [TOL] - assert a client's 2-int field
# ('size' or 'at') is within TOL px (default 2) of X,Y. Terminals snap their
# size to the cell grid, so exact-pixel checks are unrealistic.
hb_assert_near() {
    local t=$1 field=$2 x=$3 y=$4 tol=${5:-2}
    hyprctl -j clients | jq -e --arg t "$t" --arg f "$field" \
        --argjson x "$x" --argjson y "$y" --argjson tol "$tol" '
        [.[] | select(.title == $t)][0][$f]
        | ((.[0] - $x) | if . < 0 then -. else . end) <= $tol
          and ((.[1] - $y) | if . < 0 then -. else . end) <= $tol' >/dev/null
}

# hb_assert_option NAME JQ_EXPR - assert over `hyprctl getoption NAME` json.
# Example: hb_assert_option general:border_size '.int == 5'
hb_assert_option() {
    hyprctl -j getoption "$1" | jq -e "$2" >/dev/null
}
