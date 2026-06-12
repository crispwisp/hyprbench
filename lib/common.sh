#!/usr/bin/env bash
# hyprbench shared helpers.
# Sourced by the runner and by task setup/oracle/verify snippets.
# All hyprctl calls target the instance in $HYPRLAND_INSTANCE_SIGNATURE.

HB_TERMINAL=${HB_TERMINAL:-alacritty}

# --- instance lifecycle (used by the runner) -------------------------------

# Launch a nested Hyprland instance with the bench config.
# Prints the new instance signature on stdout.
#
# The nested output's size is whatever the PARENT compositor tiles the
# instance window to - which varies with host session state and silently
# changes the bench monitor's aspect ratio (dwindle split direction, float
# defaults, canvas coordinates all depend on it). hb__pin_parent_window
# floats the instance's host window to an exact 1280x800 so every run gets
# the same output geometry. Best-effort: skipped when the runner is not
# itself inside a Hyprland session.
hb_launch_instance() {
    local root=$1 logfile=$2 before after sig i
    local parent_wins=""
    [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] &&
        parent_wins=$(hyprctl -j clients 2>/dev/null |
            jq -c '[.[] | select(.class == "aquamarine") | .address]' || true)
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
                hb__pin_parent_window "$parent_wins"
                hb_record_wayland_display "$sig"
                echo "$sig"
                return 0
            fi
        fi
        sleep 0.2
    done
    return 1
}

# hb__pin_parent_window BEFORE_ADDRS - float the just-launched instance's
# window in the PARENT session and pin it to exactly 1280x800, so the nested
# output geometry is deterministic across runs. Runs in the runner env (parent
# instance); no-op without a parent session.
hb__pin_parent_window() {
    local known=$1 addr="" i
    [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} && -n $known ]] || return 0
    for ((i = 0; i < 25; i++)); do
        addr=$(hyprctl -j clients 2>/dev/null | jq -r --argjson known "$known" \
            '[.[] | select(.class == "aquamarine"
                and (.address as $a | $known | index($a) | not))][0].address // empty')
        [[ -n $addr ]] && break
        sleep 0.2
    done
    [[ -n $addr ]] || return 0
    hyprctl dispatch setfloating "address:$addr" >/dev/null 2>&1
    hyprctl dispatch resizewindowpixel "exact 1280 800,address:$addr" >/dev/null 2>&1
    hyprctl dispatch movewindowpixel "exact 0 0,address:$addr" >/dev/null 2>&1
    sleep 0.5 # let the nested output adopt the new size
    return 0
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

# hb_spawn_shell TITLE CWD [CLASS] - spawn a terminal running an interactive
# shell in CWD. For tasks that need real shells (termtopo: CWD is read back
# via /proc/PID/cwd of the shell). hb_spawn stays inert (sleep) by design.
hb_spawn_shell() {
    local title=$1 cwd=$2 class=${3:-hyprbench}
    mkdir -p "$cwd"
    hyprctl dispatch exec -- \
        "$HB_TERMINAL --class $class --title $title --working-directory $cwd -e bash --norc --noprofile" >/dev/null
    hb_wait_title "$title" 15
}

# hb_place TITLE X Y W H - float a window and pin exact geometry.
hb_place() {
    local t=$1 x=$2 y=$3 w=$4 h=$5
    hyprctl dispatch setfloating "title:^($t)$" >/dev/null
    hyprctl dispatch resizewindowpixel "exact $w $h,title:^($t)$" >/dev/null
    hyprctl dispatch movewindowpixel "exact $x $y,title:^($t)$" >/dev/null
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

# --- answer channel (query tasks) -------------------------------------------
# The runner exports HB_ANSWER_FILE; agents write their bare answer to it.

hb_assert_answer_exact() { # EXPECTED - whitespace-trimmed comparison
    local got
    got=$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$HB_ANSWER_FILE" 2>/dev/null | head -1)
    [[ $got == "$1" ]]
}

hb_assert_answer_regex() { # ERE
    grep -Eq "$1" "$HB_ANSWER_FILE" 2>/dev/null
}

hb_assert_answer_num() { # EXPECTED [TOL] - first number in the answer
    local exp=$1 tol=${2:-0} n
    n=$(grep -Eo -m1 '[-+]?[0-9]+([.][0-9]+)?' "$HB_ANSWER_FILE" 2>/dev/null | head -1)
    [[ -n $n ]] || return 1
    jq -ne --argjson n "$n" --argjson e "$exp" --argjson t "$tol" \
        '(($n - $e) | if . < 0 then -. else . end) <= $t' >/dev/null
}

# --- layout predicates (winorg tasks) ----------------------------------------
# Geometry math over the clients on the ACTIVE workspace. Canonical
# predicates with cell-relative tolerances, not pixel-perfection.

# centers of mapped clients on the active workspace, as a jq array.
# SCOPE keeps host-mode clutter out of the math (a leaked window on the live
# session must not break a geometry predicate):
#   all   - every client on the workspace (default; nested-mode safe)
#   owned - only bench-owned classes (tasks that arrange setup-spawned windows)
#   new   - only clients not in HB_BASELINE (tasks where the agent opens them)
hb__ws_centers() {
    local scope=${1:-all} ws
    ws=$(hyprctl -j activeworkspace | jq '.id')
    case $scope in
    owned)
        hyprctl -j clients | jq --argjson ws "$ws" --arg re "$HB_OWNED_CLASSES" \
            '[.[] | select(.workspace.id == $ws and .mapped != false and (.class | test($re)))
              | {x: (.at[0] + .size[0]/2), y: (.at[1] + .size[1]/2), fl: .floating}]'
        ;;
    new)
        hyprctl -j clients | jq --argjson ws "$ws" --slurpfile base "$HB_BASELINE" \
            '[$base[0][].address] as $known
             | [.[] | select(.workspace.id == $ws and .mapped != false
                 and (.address as $a | $known | index($a) | not))
               | {x: (.at[0] + .size[0]/2), y: (.at[1] + .size[1]/2), fl: .floating}]'
        ;;
    *)
        hyprctl -j clients | jq --argjson ws "$ws" \
            '[.[] | select(.workspace.id == $ws and .mapped != false)
              | {x: (.at[0] + .size[0]/2), y: (.at[1] + .size[1]/2), fl: .floating}]'
        ;;
    esac
}

# hb_assert_layout_triangle [SCOPE] - exactly 3 windows: one apex clearly
# above two bases; bases split left/right at roughly the same height; apex x
# between the bases.
hb_assert_layout_triangle() {
    local scope=${1:-all} mon
    mon=$(hyprctl -j monitors | jq 'first | {w: .width, h: .height}')
    hb__ws_centers "$scope" | jq -e --argjson m "$mon" '
        length == 3 and (
            sort_by(.y) as $s
            | $s[0] as $apex | ($s[1:] | sort_by(.x)) as $b
            | ($m.w / 8) as $tx | ($m.h / 8) as $ty
            | ($apex.y < $b[0].y - $ty) and ($apex.y < $b[1].y - $ty)
            and (($b[1].x - $b[0].x) > $tx)
            and ((($b[0].y - $b[1].y) | if . < 0 then -. else . end) <= ($m.h / 6))
            and ($apex.x >= $b[0].x - $tx) and ($apex.x <= $b[1].x + $tx)
        )' >/dev/null
}

# hb_assert_layout_grid N M [tiled] [SCOPE] - exactly N*M windows
# partitioning the screen into N columns x M rows: sorted-by-x centers chunk
# into N column groups of M with small x-spread, and row heights align across
# columns. With "tiled", every window must also be non-floating.
hb_assert_layout_grid() {
    local n=$1 m=$2 tiled=${3:-any} scope=${4:-all} mon
    mon=$(hyprctl -j monitors | jq 'first | {w: .width, h: .height}')
    hb__ws_centers "$scope" | jq -e --argjson m_ "$mon" --argjson N "$n" --argjson M "$m" \
        --arg tiled "$tiled" '
        def chunk(s): [range(0; length; s)] as $is | [$is[] as $i | .[$i:$i+s]];
        ($m_.w / $N / 3) as $tx | ($m_.h / $M / 3) as $ty
        | length == ($N * $M)
        and (($tiled != "tiled") or all(.[]; .fl == false))
        and ((sort_by(.x) | chunk($M)) as $cols
            | all($cols[]; (map(.x) | max - min) <= $tx)
            and ([$cols[] | sort_by(.y)] as $sorted
                | all(range(0; $M);
                    . as $r | [$sorted[] | .[$r].y] | (max - min) <= $ty)))
        ' >/dev/null
}

# --- baseline-geometry references (winorg extension) ------------------------
# HB_BASELINE records post-setup client geometry, so spatial references like
# "swap these two" or "the top-right window" resolve against where windows
# WERE, independent of what the agent has since moved.

# hb__baseline_rect TITLE - the baseline {x,y,w,h} of the client with TITLE.
hb__baseline_rect() {
    jq -e --arg t "$1" \
        '[.[] | select(.title == $t)][0]
         | {x: .at[0], y: .at[1], w: .size[0], h: .size[1]}' "$HB_BASELINE"
}

# hb_assert_swapped T1 T2 [TOL] - T1 now occupies T2's baseline region and
# vice versa: current center within TOL (default: quarter of the smaller
# baseline dimension) of the other window's baseline center.
hb_assert_swapped() {
    local t1=$1 t2=$2 tol=${3:-} r1 r2
    r1=$(hb__baseline_rect "$t1") || return 1
    r2=$(hb__baseline_rect "$t2") || return 1
    hyprctl -j clients | jq -e --arg t1 "$t1" --arg t2 "$t2" \
        --argjson r1 "$r1" --argjson r2 "$r2" --arg tol "${tol:-}" '
        def center(c): {x: (c.at[0] + c.size[0]/2), y: (c.at[1] + c.size[1]/2)};
        def bcenter(r): {x: (r.x + r.w/2), y: (r.y + r.h/2)};
        def near(a; b; t): ((a.x - b.x) | if . < 0 then -. else . end) <= t
            and ((a.y - b.y) | if . < 0 then -. else . end) <= t;
        ([$r1.w, $r1.h, $r2.w, $r2.h] | min / 4) as $deftol
        | (if $tol == "" then $deftol else ($tol | tonumber) end) as $t
        | [.[] | select(.title == $t1)][0] as $c1
        | [.[] | select(.title == $t2)][0] as $c2
        | ($c1 != null) and ($c2 != null)
        and near(center($c1); bcenter($r2); $t)
        and near(center($c2); bcenter($r1); $t)' >/dev/null
}

# hb_baseline_corner CORNER - print the title of the baseline client whose
# center is most toward CORNER (top-left|top-right|bottom-left|bottom-right).
hb_baseline_corner() {
    local corner=$1 dx dy
    case $corner in
    top-left) dx=-1 dy=-1 ;;
    top-right) dx=1 dy=-1 ;;
    bottom-left) dx=-1 dy=1 ;;
    bottom-right) dx=1 dy=1 ;;
    *) echo "hb_baseline_corner: bad corner '$corner'" >&2; return 1 ;;
    esac
    jq -re --argjson dx "$dx" --argjson dy "$dy" \
        'max_by((.at[0] + .size[0]/2) * $dx + (.at[1] + .size[1]/2) * $dy)
         | .title' "$HB_BASELINE"
}

# hb_assert_in_corner TITLE CORNER - the client's current center lies in the
# outer-third region of the monitor toward CORNER.
hb_assert_in_corner() {
    local title=$1 corner=$2 mon
    mon=$(hyprctl -j monitors | jq 'first | {w: .width, h: .height}')
    hyprctl -j clients | jq -e --arg t "$title" --arg c "$corner" --argjson m "$mon" '
        [.[] | select(.title == $t)][0] as $w
        | $w != null
        | if . then
            ($w.at[0] + $w.size[0]/2) as $cx | ($w.at[1] + $w.size[1]/2) as $cy
            | (($c | startswith("top")) and $cy <= $m.h/3
               or (($c | startswith("bottom")) and $cy >= 2*$m.h/3))
              and (($c | endswith("left")) and $cx <= $m.w/3
               or (($c | endswith("right")) and $cx >= 2*$m.w/3))
          else false end' >/dev/null
}
