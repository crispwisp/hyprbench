# hyprbench — what we test

49 tasks, 13 categories, every verifier reading real state through the
system's own introspection channels. Two execution modes, two observation
tracks, two prompt styles; correctness and end-to-end latency both scored.

```
                              ┌─────────────────────────┐
                              │        hyprbench        │
                              └────────────┬────────────┘
            ┌──────────────────┬───────────┴────────────┬─────────────────┐
         MODES              TRACKS                   STYLES            METRICS
      ┌────┴─────┐       ┌────┴─────┐             ┌────┴─────┐      ┌────┴──────┐
   nested      host   headless   vision        imperative  decl.  pass-rate  latency
  (fresh Hyprland  (live session,  (hyprctl/text  (screenshots  ("swap A    ("ws 1-3      (per    (total/
   per task, ~1s    snapshot +      only, no       via hb-look,   and B")     must each    task)   median/
   reset)           restore)        images)        pointer via                hold two              p90)
                                                   hb-point)                  windows")
```

## The skill map

| category  | n | the skill under test                       | verified through                  |
|-----------|---|--------------------------------------------|-----------------------------------|
| window    | 9 | single-window control: move/float/fullscreen/close/focus/pin/tag/resize/position | `hyprctl -j clients` |
| winorg    | 8 | spatial reasoning: triangles, grids, swaps, corner refs, vision-only labels | geometry math over client rects, baseline-relative |
| wsmgmt    | 4 | workspace logistics: gather, name, return, balance | `hyprctl -j workspaces/clients`   |
| query     | 4 | answer questions BY USING the system       | answer-file vs independently computed truth |
| canvas    | 4 | pointer accuracy where no DOM exists: click target, drag slider, connect dots, drop in bin | fixture-recorded ground truth over CDP |
| browser   | 3 | web-form hazards: prefilled fields, delayed-enable buttons, link navigation | DOM state over CDP |
| apps      | 3 | real desktop apps: mpv pause/seek, Steam sign-in field | mpv IPC socket; Steam CEF debugging |
| workspace | 3 | switch, rename, special/scratchpad         | `hyprctl -j workspaces`           |
| multi     | 3 | multi-window coordination + cleanup of junk windows | client-set predicates             |
| termtopo  | 2 | terminal↔tmux topology transforms (consolidate/explode) | shell CWDs survive the migration (`/proc`, `list-panes`) |
| config    | 2 | live compositor reconfiguration (gaps, borders) | `hyprctl getoption`               |
| exec      | 2 | launch programs with constraints (class, title) | new-client predicates             |
| install   | 2 | real package operations (install game, remove pkg) | `pacman -Q` + desktop entries     |

## The four-phase task contract

```
 setup ──────────► agent ──────────► verify ──────────► teardown
 (forced non-goal  (only the         (reads state,      (best-effort,
  start state,      instruction +     never pixels,      unconditional
  explicit          a live desktop;   never trusts       tmpdir cleanup)
  placement)        no oracle leak)   exit codes)
```

Every task also passes **two standing audits** before it may exist:

- **oracle** — the reference solution must PASS (proves the verifier can be
  satisfied);
- **noop** — doing nothing must FAIL (proves the verifier cannot be
  satisfied for free — catches goal-equals-default, degenerate inputs, and
  environment-dependent starts).

Validated green in **both modes**: oracle 46/46, noop 0/46 (pre-vision-tasks
suite; 49-task gate in progress).

## Integrity machinery

| layer | what it prevents |
|-------|------------------|
| agents run from a per-task tmpdir | CLI context ingestion handing the agent `tasks/*.json` — the oracle answers |
| agent stdin = `/dev/null` | the agent eating the suite loop (and the loop becoming its prompt) |
| `tracks` gate | headless agents being scored on vision-only tasks |
| `requires` gate | missing tools scoring as failures instead of unscored SKIPs |
| `mutates` gate (default-deny) | system-mutating tasks running without explicit `--allow-mutates` |
| scoped layout predicates (owned/new/all) | host-session clutter breaking — or faking — geometry verdicts |
| host preflight | measuring a session that already contains foreign compositor windows |
| seeded fixture layouts | answers memorized from the public repo |
| rendered labels (`hb_spawn_label`) | "what's on screen" prompts being resolved from window titles |
| provenance headers | numbers without the commit hash + CLI versions that produced them |
| token lift, never-at-rest | credentials on disk or in logs |

## Current scoreboard (first datum)

| agent | track | pass | latency (med / p90 / max) | note |
|-------|-------|------|---------------------------|------|
| claude (2.1.168) | headless | 40/42 — 95.2% | 25s / 110s / 262s | both fails = budget kills, fixed by new timeout floors |

Matrix staged: claude, codex (gpt-5.5), pi, deepseek-v4-flash,
gemma4-31b-it, qwen3.6-35b-a3b × headless + vision.
