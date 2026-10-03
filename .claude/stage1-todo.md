# Stage 1 — tsnake as a local Omarchy plugin (+ unit tests)

Scope: **Brodie's machine only.** No marketplace work, no prebuilt-binary decision,
no `preview.png`, no publishing. Plan of record: `.claude/omarchy-plugin-plan.md`.

Owner key: `me` = Claude, `qml` = qml-plugin subagent, `ut` = unittests subagent,
`Brodie` = human play-test.

| # | Task | Owner | Status |
|---|---|---|---|
| 1 | De-mirror the lifted test ban in `omarchy-plugin-plan.md` | me | [x] |
| 2 | Verify Omarchy/quickshell environment on this box | me | [x] Quickshell 0.3.1, refs present, plugins dir empty, no `qmllint` on PATH, **no `omarchy-shell` running** |
| 3 | `snake --protocol`: NDJSON frame emit + command read, self-ticking | me | [x] |
| 4 | `snake --state <path>`: engine-owned file, hardened read, flush-only writes | me | [x] verified by hand: nothing on disk while live, one write after close; symlink read+write refused with target intact; garbage file ignored; nested dirs created |
| 5 | `--square-cells`: 2-cell aspect stride becomes a renderer-side option | me | [x] `stride_len_for()` is the single decider, shared by `game_step` and `hunt_stride_free` |
| 6 | `make` warning-free under `-Wall -Wextra` (both targets) | me | [x] engine commit; re-check after the agents land |
| 7 | Unit tests for the mechanics behind the ncurses seam | ut | [x] **1853 checks, 0 failures**, 28/28 suites, exit 0, warning-free, repeat runs byte-identical. All 22 initial failures were rig bugs; `snake.c` was never touched. Independently mutation-tested by me: no `O_NOFOLLOW` → 2 failures, `ensure_food` neutered → 12, wrap disabled → 14 |
| 8 | `manifest.json` at repo root (`overlay` + `bar-widget`) | qml | [x] passes the real `omarchy-plugin-validate` |
| 9 | `Overlay.qml`: PanelWindow/Overlay layer, exclusive focus, raw `Keys.onPressed`, board | qml | [x] 780 lines; qmllint exit 0, no silencing comments, its warning categories reproduce on first-party `Emojis.qml` |
| 10 | `BarWidget.qml`: bar button that toggles the overlay | qml | [x] 36 lines, shaped from `plugins/menu/BarWidget.qml:1-24` |
| 11 | Engine lifecycle: start on `open()`, kill on `close()`/`dismiss()`/`onDestruction` | qml | [x] candidate list, `launchPending` + 1500 ms watchdog, 600 ms grace then SIGTERM backstop |
| 12 | Save data: read at `open()`, flush only after the overlay is closed | qml + me | [x] `opened = false` precedes `stopEngine()` in both paths; flush→quit→kill. State at `$HOME/.local/state/tsnake/highscore`, engine binary outside the plugins dir — the inotify trap is designed out, not trusted |
| 13 | Plugin install into `~/.config/omarchy/plugins/` + `omarchy plugin validate` + `qmllint` | me | [x] installed at `~/.config/omarchy/plugins/io.github.londelo.tsnake` + engine at `~/.local/state/tsnake/snake`; validator exit 0 on the installed folder; installed binary proven to stream frames and flush on quit |
| 14 | Human play-test: does it feel like the terminal game | Brodie | [ ] **the only thing left.** Needs a login session with `omarchy-shell` up; never yet run under Quickshell |
| 15 | README: install, removal, keybind line (local-facing only) | qml | [x] append-only: 84 insertions, 0 deletions |

## Stage-1 landing notes (verified, not assumed)

Three ways the brief was wrong about the 0.3.1 API, each caught against
qmltypes/qmllint rather than guessed: `SplitParser` takes `splitMarker`, not
`token`; `errorOccurred` is an overridable method with zero first-party users
(dropped — a watchdog Timer + `onExited` share one `launchPending` flag instead);
and `Qt.Key_h/p/x/r/q` **do not exist** on the QML `Qt` object, so those five
keys would have silently never fired — they now match lowercase `event.text`,
which also makes the lowercase-only rule real (`Shift+h` arrives as `H`).
`q` calls `dismiss()`, not `close()`: `close()` stops the engine and hides the
surface but leaves the host's `openPanelIds` holding the id, and the bar button
toggles through `shell toggle` — a stale id makes the next press hide an already
hidden panel and strands the Loader item.

Unproven by any amount of automation, and not pretending to be: exclusive
keyboard focus under hyprland, `Color.menu.*` on Canvas `fillStyle`,
`Style.font.menuFamily` strings, and the feel of click-to-place.

Found and fixed while building task 4: `ensure_parent_dir`'s component walk ran
past the end of its own buffer, so the first save segfaulted under `--protocol`
and returned garbage to its caller in the terminal build. Caught by hand-smoke,
not by a rig.

Deliberately deferred to stage 2: marketplace submission, Automated Security Baseline
handling, `keepLoaded: true`, `preview.png`, category/tag choice.

Invariant reminders the build must not break:
- curses path stays behaviourally identical (same keys, same 2-cell horizontal stride,
  same constant `TICK_MS` 55)
- the hunt AI plans on the SAME topology the snake travels — stride checks must cover
  the WHOLE stride, both cells, including when `--square-cells` makes it one
- the board is never empty of tokens (`ensure_food`)
- only walls kill; a self bite wounds
- the engine is the only writer of the state file, and it writes only while the overlay
  is closed. The state file now lives at `$HOME/.local/state/tsnake/highscore`, outside
  the inotify-watched plugins dir, so a stray write can no longer trigger a reload by
  itself — but a save during play would still reset the panel under the player

## Known latent engine bug (found by the suite's read-through, NOT fixed — needs Brodie's call)

`snake.c:340`, in `snake_bite`: `if (n > MAX_SNAKE - s->wound_len) n = ...;` then
`if (n <= 0) return;`. That returns *before* `s->len = depth`, so once the corpse queue
is saturated the bite severs nothing and `advance_one` pushes the head onto a live body
cell anyway — the snake silently overlaps itself, with no severing and no death.
Unreachable on any real board (it wants ~4096 un-faded corpses at once, and `WOUND_FADE`
is 55 ticks), so it is latent; the reason it is worth writing down is that the failure
mode is silent rather than loud. The fix is to treat "cannot sever" as "cannot bite" and
skip the push, or to drop the oldest corpses to make room.

Hygiene: `test_game` shows as untracked build output (`snake`/`test_hunt` are ignored);
one `.gitignore` line closes that.
