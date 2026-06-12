# computer-use field notes

Lessons from driving this exact machine — Hyprland by tool and by hand, and
Chromium over the DevTools protocol — collected while doing real account
registration and system work, not synthetic tasks. Two reasons they belong in
this repo:

1. **Task design.** Agents under evaluation will hit every one of these
   gotchas. Tasks that contain them (prefilled fields, paste-hostile inputs,
   delayed-enable buttons) separate agents that verify from agents that fire
   and forget.
2. **Verifier design.** Everything below that worked, worked because state was
   *read back* after every action. Verifiers should do the same: query state
   (`hyprctl -j`, `Runtime.evaluate`), never pixels.

## Hyprland

- `hyprctl -j clients|activewindow|monitors|workspaces` is the verifier
  goldmine — full window state as JSON, deterministic, no OCR.
- Which compositor instance you're talking to is selected by
  `HYPRLAND_INSTANCE_SIGNATURE`. A nested Hyprland gets its own signature, so
  a bench harness can point `hyprctl` (and the agent) at the sandbox while the
  host session stays untouchable.
- Focus is asynchronous. Typing immediately after a focus dispatch drops
  keystrokes; either sleep ~100–200ms or use a wrapper that sequences
  focus→settle→type atomically (`hypr-agent do`).
- The agent's own terminal is a window too. Before typing into "the focused
  window", confirm it isn't the window hosting *you* — I have typed a command
  into my own prompt. Tasks where the agent's host window is a decoy are
  cheap and brutal.
- Config syntax drifts across Hyprland releases (e.g. 0.54 unified the
  window/layer rule syntax). Anything that writes config must validate with
  `hyprctl reload` + `hyprctl configerrors` (or `Hyprland --verify-config`
  offline) instead of assuming.
- `wtype` produces real Wayland keystrokes and works where synthetic input is
  ignored — but it types into whatever has focus, so it inherits the focus
  race above.

## Browser via CDP (remote debugging port)

Setup that survives an agent's detached shells:

```sh
setsid chromium --remote-debugging-port=9222 \
  --user-data-dir="$HOME/.local/share/wisp/browser" </dev/null &
```

Without `setsid`/stdin-detach the browser dies with the spawning shell and the
next CDP call gets `ECONNREFUSED`. Discover page targets at
`http://localhost:9222/json`, then speak JSON-RPC over the target's
`webSocketDebuggerUrl` (native `WebSocket` in modern Node — no library needed).

What actually works, by input type:

- **Trusted-input-checking fields** (e.g. GitHub's segmented code boxes):
  `Input.insertText` is silently dropped, and setting `.value` via
  `Runtime.evaluate` doesn't register either (framework state never updates).
  Two working paths: (a) put the text on the clipboard (`wl-copy`) and send a
  *real* paste — `Input.dispatchKeyEvent` with `modifiers: 2,
  commands: ['paste']`; (b) focus the window at the compositor level and
  `wtype` character by character, verifying each field as you go.
- **Cross-origin iframes** (anti-abuse widgets): unreachable from the main
  frame's `Runtime.evaluate`. Click by viewport coordinates
  (`Input.dispatchMouseEvent`) and clear fields with Backspace key events —
  Ctrl+A never reaches the iframe.
- **Delayed-enable buttons** (anti-clickjacking): submit/authorize buttons can
  render `disabled` for several seconds. Poll `button.disabled === false`
  before clicking; a coordinate click on a disabled button reports success
  and does nothing.
- **Prefilled fields**: read the value before typing, or autofill turns
  `user` into `useruser`. Clear-then-type, never just type.
- **File uploads**: `DOM.setFileInputFiles` — no dialog automation needed.
- **Screenshots**: `Page.captureScreenshot {format:'jpeg', quality:35}` is
  plenty for vision-model verification at a fraction of the payload. But
  prefer DOM reads over pixels whenever the question is "did the action
  land" — screenshots are for *discovering* state, not asserting it.

The through-line: **synthetic success signals lie.** A dispatched event, a
returned promise, a 0 exit code — none of them mean the UI state changed.
Every reliable sequence here is act → read back → branch. A benchmark task is
good exactly when it punishes skipping the read-back.

## Task design

- **Never make the goal state the default state.** `win-resize-floating`
  originally asked for 800×600 — which is exactly Hyprland's default float
  size on a 1280×800 monitor, so in host mode the task passed with zero
  action (caught by noop validation). Noop validation only protects you when
  start and goal genuinely differ in *every* environment the suite runs in,
  and platform defaults can violate that silently, per-monitor. Setups must
  *force* the start state away from the goal (resize to 500×400 first), not
  assume it.
- **Goal-equals-default has a twin: goal-satisfied-by-degenerate-input.** A
  3×3-grid predicate built on column/row means accepted nine windows stacked
  on a single point — all spreads zero, every check satisfied. And the
  default-state rule itself has an environment-dependent form: a host tiler's
  *natural* layout of three windows can form a "triangle" or not depending on
  what else the session holds, so the same task validates green and red an
  hour apart. Predicates need a forced non-goal START (explicit placement,
  never tiler-natural) and a non-degenerate GOAL (minimum extents between
  rows/columns).
- **Shared sessions accumulate other people's state.** A leaked window from
  an unrelated prototype broke three geometry verifiers at once, because they
  counted every client on the workspace. Verifiers over shared environments
  must scope what they measure — windows the bench owns, or windows that
  appeared since the baseline — never "everything currently there." That
  scoping also closes the reverse hole: pre-existing clutter can't *fake* a
  pass either.

## Harness tooling

Earned during hyprbench development, each by a real incident:

- **A helper nothing executes is not code, it is a hypothesis.** An mpv
  command-builder was broken from the day it was written; it survived three
  consecutive diagnoses (load, settle time, tmpfs quota — all real phenomena,
  none the cause) because every manual test bypassed it with hand-written
  JSON. When a helper fails, test *the helper*, not the resource it wraps —
  and give helpers contract self-tests (`doctor`) so "shipped" implies
  "executed at least once."
- **jq's `try EXPR catch .` feeds catch the error MESSAGE, not the original
  value.** `map(try fromjson catch .)` silently turns every unparseable
  string into jq error text. Bind first: `. as $s | try ($s | fromjson)
  catch $s`.
- **`pkill -f` can match the calling shell's own command line** when the
  pattern appears literally in an instrumented wrapper — the command kills
  itself with a confusing exit code (two independent victims, same day).
  Bracket the first character: `pkill -f '[u]ser-data-dir=...'` cannot match
  its own pattern text.
- **Processes a compositor exec's log to the compositor, not to you.**
  stderr of `hyprctl dispatch exec` children lands in the compositor log;
  give long-running tools their own log file (`mpv --log-file=...`) or the
  failure story is simply gone.
- **Steam keeps shared mutable state in `~/.steam`** regardless of which
  compositor instance it renders in — steam tasks must never run
  concurrently with each other, and a bootstrapped steam answers CDP on
  port 8080 within seconds while its sign-in page target appears much
  later: gate on the target, not the endpoint.

## Proposed: browser task track

CDP makes browser tasks as verifiable as window-manager tasks: launch a pinned
profile on the debugging port, let the agent work however it wants, then the
verifier asserts DOM/URL/storage state over the same socket. No DOM diffing of
live websites — pin local fixture pages into the profile so runs are hermetic.
