# hyprbench — roadmap

What the benchmark should grow next, ordered by how much new signal each
item buys. Drafted 2026-06-12, post-v1 (49 tasks / 13 categories).

## New task categories

| category | example tasks | why it adds signal | verification channel |
|----------|---------------|--------------------|----------------------|
| **quest** (long-horizon) | "install SuperTux, launch it, reach the main menu, set fullscreen off" | chains 4+ categories; failure localization shows WHERE agents break down | pacman + client state + game window props |
| **recovery** | broken `hyprland.conf` shipped in setup — "windows have no borders and gaps are huge; fix it" | diagnosis under fault, not just construction | `hyprctl configerrors` + getoption |
| **files** | "using the file manager, move every .png from ~/Downloads into ~/Pictures/refs" | GUI navigation with fs-verifiable outcomes | filesystem state |
| **editing** | nvim: "fix the syntax error in this script"; LibreOffice Calc: "sum column B into B10, save as xlsx" | real document work; the xlsx is read back and checked | file content / parsed xlsx |
| **media-system** | "mute the output", "set volume to 40%", "play the next track" | wpctl/playerctl give exact state readback | `wpctl get-volume`, mpv IPC |
| **theming** | "switch the omarchy theme to X and set a different wallpaper" | multi-config coherence | omarchy state + config files |
| **clipboard** | "copy the version string from window A into the form in window B" | cross-window data carry, vision+input combo | CDP reads the pasted value |
| **steam-deep** (needs throwaway account) | "find Hades in the store and add it to the wishlist" | real-app navigation depth beyond the sign-in screen | Steam CEF CDP |
| **notifications** | "when the next notification arrives, act on what it says" | reactive (event-driven) behavior — nothing tests waiting today | mako history + task-specific effect |
| **multi-monitor** | "move the browser to the external display and fullscreen it there" (headless output via `hyprctl output create`) | spatial model across outputs | monitor-qualified client state |
| **adversarial** | decoy windows with near-identical titles; instructions that mention a window that does NOT exist ("report it instead of guessing") | measures verification discipline and refusal-to-hallucinate | negative assertions |

## New metrics

| metric | definition | machinery needed |
|--------|------------|------------------|
| **steps** | actions taken per task (hyprctl dispatches, pointer events, keystrokes) | the action-logging hyprctl shim (claimed by wisp) + hb-point counters |
| **cost** | tokens / $ per task per model | adapter already sees CLI token reports; aggregate into results jsonl |
| **pass@k / variance** | same task, k seeds — is the pass stable or lucky? | seeded layouts already exist; runner gains `--repeat k` |
| **time-to-first-action** | latency before the agent's first state-changing command | timestamp in the shim log |
| **overshoot** | actions after the goal state was already reached | shim log + verify-time goal timestamps |

## Infrastructure

- **CI on the aquamarine headless backend** — full nested validation on every
  push, no screen needed; the no-vendor-cosign action already proves the
  pipeline works.
- **Scoreboard publisher** — render results/*.jsonl + meta headers into a
  static markdown/HTML leaderboard committed per matrix run.
- **`--repeat k` + seed control in the runner** — variance and pass@k.
- **Task linter** — mechanically enforce the task-design laws (timeout floor,
  forced non-goal setup, teardown present when setup spawns, requires
  declared when helpers used). Catches the next goal-equals-default at
  authoring time, not gate time.
- **Per-task budget kills in the latency column** — record timeout deaths as
  latency = budget + ∞ marker so slow-fails are distinguishable from
  wrong-fails in the scoreboard.

## Hardening (carry-over)

- pi-profile smoke through the adapter (queued behind the matrix).
- Steam tasks serialized by a lock rather than convention (`~/.steam` is
  shared mutable state).
- Proton account recovery method — still unset (off-bench, wisp ops).

## Deliberately out of scope

- Parallel agent execution — corrupts latency columns (mpv load lesson);
  sequential is a feature until a second machine exists.
- Pixel-diff verification — verifiers read state, never pixels; screenshots
  are for agents, not for judges.
- Tasks requiring external network beyond OpenRouter/package mirrors — runs
  must stay reproducible on a fresh VM.
