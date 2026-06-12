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

## Proposed: browser task track

CDP makes browser tasks as verifiable as window-manager tasks: launch a pinned
profile on the debugging port, let the agent work however it wants, then the
verifier asserts DOM/URL/storage state over the same socket. No DOM diffing of
live websites — pin local fixture pages into the profile so runs are hermetic.
