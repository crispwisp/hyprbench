# hyperbench

A computer-use benchmark for **Hyprland**. Agents receive a natural-language
instruction and must drive a real Hyprland compositor to the requested state.
Success is judged by **execution-based verification** of compositor state via
`hyprctl -j` — never by inspecting the agent's transcript.

Repo: [crispwisp/hyperbench](https://github.com/crispwisp/hyperbench)

## Related work

The design follows [OSWorld](https://os-world.github.io/) (NeurIPS 2024,
[xlang-ai/OSWorld](https://github.com/xlang-ai/OSWorld)): declarative tasks
with initial-state setup and execution-based evaluators, with full environment
reset between tasks. OSWorld runs Ubuntu/Windows/macOS VMs; nothing existed for
Wayland tiling compositors. Adjacent projects: [trycua/cua](https://github.com/trycua/cua)
(CUA sandboxes/benchmarks), [OS-Harm](https://github.com/tml-epfl/os-harm)
(safety), OSWorld-Human (efficiency), and an experimental Hyprland MCP server
(automation, not evaluation). hyprland-bench fills the gap: it is native
(no VM), per-task reset costs ~1 second via nested compositor instances, and
verification reads structured compositor state instead of pixels.

## Tracks

The same 19 tasks run under two tracks; the difference is the **observation
modality available to the model**, not tool access. Both tracks have full
`hyprctl` IPC access. Scores are reported as **hyperbench_headless** and
**hyperbench_vision**.

| Track (`--track`) | Sees pixels? | Notes |
|-------------------|--------------|-------|
| `headless` | no | May screenshot and convert to *text* (`hb-look --text` ASCII via chafa, `hb-look --ocr` via tesseract) — but images must never reach the model. |
| `vision` | yes | May look at the desktop whenever it wants: `hb-look` captures a PNG of the bench instance for direct viewing. May act at screen coordinates with `hb-point` (click / move / drag with hand-like interpolated motion). |

Select with `--track headless` (default) or `--track vision`. The track is an
honor-system contract enforced by the agent adapter (e.g. the headless Claude
adapter does not allow the Read tool and forbids image viewing in its prompt);
results record which track was run.

## Modes

Orthogonal to tracks, `--mode` selects the environment the tasks run in:

| Mode | Environment | Reset | Use when |
|------|-------------|-------|----------|
| `nested` (default) | fresh nested Hyprland per task, pinned `bench.conf` | kill instance (~1s, hermetic) | everyday runs on a workstation |
| `host` | the **live session** the runner is started in | snapshot/restore: bench-owned windows closed, mutated options & workspace names restored | disposable VMs; evaluating agents against a *real* session |

Host mode is deliberately not hermetic — that's the point (real configs, real
clutter, real focus dynamics). Run it only in a session you can afford to
lose, e.g. a VM spun up for evaluation. Verifiers are written to be
baseline-relative (`hb_assert_new`) wherever pre-existing windows could
otherwise satisfy them.

## How it works

For every task the runner:

1. provides an environment: boots a **fresh nested Hyprland instance** with
   the pinned `bench.conf`, or in host mode snapshots the live session,
2. runs the task's `setup` (e.g. spawn titled terminal windows),
3. captures the client **baseline** (for relative assertions),
4. executes the **agent** with `HB_INSTRUCTION` and
   `HYPRLAND_INSTANCE_SIGNATURE` pointing at the bench instance,
5. runs the `verify` assertions against `hyprctl -j` output,
6. kills the instance (nested) or restores the session (host) and records
   the result as JSONL.

## Usage

```sh
bin/hyperbench list                              # show the 19 tasks
bin/hyperbench doctor                            # dependency + vision pipeline check
bin/hyperbench validate                          # oracle must pass all, noop none
bin/hyperbench validate --mode host              # same, against the live session
bin/hyperbench run --agent agents/claude-code.sh                  # headless track
bin/hyperbench run --agent agents/claude-code-vision.sh --track vision
bin/hyperbench run --agent agents/claude-code.sh --mode host      # live session
bin/hyperbench run --agent agents/oracle.sh --task win-float
```

## Tasks

19 tasks in `tasks/*.json`, grouped by category:

| Category  | Tasks | Examples |
|-----------|-------|----------|
| workspace | 3     | switch, rename, special workspace |
| window    | 9     | move/float/fullscreen/close/focus/pin/tag/resize/position |
| exec      | 2     | launch terminal, launch with given class |
| config    | 2     | runtime gaps / border via `hyprctl keyword` |
| multi     | 3     | multi-step arrangements and selective cleanup |

Task schema:

```json
{
  "id": "win-move-ws",
  "category": "window",
  "difficulty": "easy",
  "instruction": "Move the window titled 'Target' to workspace 4.",
  "setup":  ["hb_spawn Target"],
  "oracle": ["hyprctl dispatch movetoworkspacesilent '4,title:^(Target)$'"],
  "verify": ["hb_assert_client Target '.workspace.id == 4'"],
  "timeout": 60
}
```

`setup`, `oracle`, `verify` and the optional `teardown` (best-effort, not
scored — for cross-task resources like a browser pinned to a port) are bash
lines run with `lib/common.sh` (and `lib/browser.sh`, if present) sourced and
`HYPRLAND_INSTANCE_SIGNATURE` set to the bench instance. The `oracle` is the
reference solution — `validate` proves every task is solvable and every
verifier is non-trivial (noop must fail it).

A task may declare runtime dependencies: `"requires": ["node", "chromium"]`.
If any are missing the task yields an unscored **SKIP** (excluded from the
total, recorded in the JSONL with `reason: "missing:..."`), so optional
categories degrade gracefully instead of erroring on lean installs.

A task may also declare track membership: `"tracks": ["vision"]` (absent =
all tracks). Scored runs SKIP (unscored) tasks whose tracks exclude the run's
`--track`; `validate` ignores track gating, because oracles prove verifier
soundness via IPC/CDP regardless of observation modality — every task
validates on every machine that has its `requires`.

## Writing an agent

An agent is any executable. It gets:

| Env var | Meaning |
|---------|---------|
| `HB_INSTRUCTION` | the natural-language task |
| `HB_TASK_ID` | task id |
| `HB_TASK_FILE` | path to the task json (oracle only, don't cheat) |
| `HB_TRACK` | `headless` or `vision` |
| `HB_BASELINE` | path to the post-setup clients snapshot |
| `HB_WAYLAND_DISPLAY` | bench wayland socket (vision track) |
| `HYPRLAND_INSTANCE_SIGNATURE` | routes plain `hyprctl` to the bench instance |

`hb-look` is on `PATH` in both tracks (text modes only in headless).
`hb-point` injects real pointer input (wlr-virtual-pointer, spoken directly by
`lib/vpointer.py` — zero deps; wlrctl cannot hold a button, which drags
require). Coordinates are compositor/screenshot pixels; canvas fixtures
expose `__cv.rect` for page↔screen mapping.

Exit when done; the runner verifies afterwards.

The canonical adapter is **`agents/unleash.sh`**, which runs any agent CLI
through [unleash](https://github.com/heiervang-technologies/unleash) (the
unified agent runner) and injects the right track rules from `HB_TRACK`:

```sh
HB_UNLEASH_PROFILE=claude bin/hyperbench run --agent agents/unleash.sh
HB_UNLEASH_PROFILE=codex  bin/hyperbench run --agent agents/unleash.sh --track vision
```

`agents/claude-code.sh` / `agents/claude-code-vision.sh` are direct-CLI
equivalents kept as reference implementations.

## Scoring

`results/<run>/results.jsonl` has one record per task: status, agent exit
code, wall-clock seconds. Headline metric: pass rate. Secondary: time per task.

## Limitations / future work

- **Actions are IPC-level in both tracks**: a future `input` track could force
  acting through synthetic keyboard/mouse (wtype/wlrctl) against keybinds,
  like a human.
- Nested instances render on your screen; true offscreen rendering (aquamarine
  headless backend) would enable CI. (Note: the `headless` *track* name refers
  to the agent having no vision, not to offscreen rendering.)
- Host-mode restore covers what tasks mutate (windows created after the
  snapshot — any class — plus gaps, border, workspace names, active
  workspace). It does NOT restore per-window properties an agent might set on
  pre-existing windows (fullscreen/float/pin/tag). Use a disposable VM.
- **Environment boundary at `hyprctl dispatch exec`**: exec'd processes
  inherit the *compositor's* environment, not the runner's. Nested mode is
  safe (the nested compositor inherits the runner env), but in host mode the
  session compositor may lack runner-visible PATH entries (e.g. mise shims) —
  so the `requires` gate could pass while an exec'd process fails to find a
  binary. Convention: anything that crosses the dispatch-exec boundary must
  resolve its binary to an absolute path at snippet time and fail loudly if
  resolution is empty (see `hb_browser_launch` in `lib/browser.sh`).
- A **browser track** is drafted (`tasks/browser.json.draft`, `lib/browser.sh`,
  `lib/cdp.mjs`, `fixtures/browser/`): hermetic `file://` fixtures driven over
  the Chrome DevTools Protocol, verified by DOM state. Rename the `.draft`
  file to activate once chromium+node deps are settled.
- See `docs/computer-use-notes.md` for field-collected gotchas that inform
  task and verifier design.
- No step-count metric yet (needs an action-logging hyprctl shim).
- Single-monitor only.

## Requirements

Hyprland (tested on 0.54), `jq`, `alacritty`, a running Wayland session to
nest inside (or to evaluate directly in host mode). Vision track: `grim`;
headless text rendering: `chafa`, `tesseract`. Check with
`bin/hyperbench doctor`.
