# tsnake

Snake in your terminal. Written in C with ncurses — one file, zero dependencies, instant startup.

> **Status:** stable and fully working (2026-09-29) — steering, key-mash
> protection, wrap mode, resize-to-fit, auto-hunt, and the headless test
> harness (`make test`) all verified working.

## Build & run

```sh
make
./snake
```

Requires `ncurses` dev headers (`sudo pacman -S ncurses` on Arch — usually already installed).

## Controls

All keys are lowercase, one key one job.

| Key | Action |
|---|---|
| Arrows | Steer (also cancels auto-hunt) |
| `h` | Toggle auto-hunt — AI chases the nearest food |
| `p` | Pause / resume |
| `x` | Toggle wrap-around walls |
| `r` | Restart |
| `q` | Quit |

When auto-hunt or wrap is on, a yellow **ALL-CAPS** label (`AUTO HUNT`,
`WRAP`) appears at the right of the help row; it disappears when off.
While auto-hunt is armed the board border burns red-orange.

## Details

- Food is a green `$`; there are always three on the map and eating one
  respawns just that one.
- The snake is white; its head wears an arrow pointing where it's heading
  (`^` `v` `<` `>`).
- The play-field border flashes green for about half a second every time
  you eat, and burns red-orange while auto-hunt is armed.
- **Scoring is length**: that's the whole scoreboard (`length` in the
  header, plus `high`). The high score is your best length ever and
  persists to `~/.tsnake_highscore` — banked on death, restart, or quit.
- Terminal cells are ~2x taller than wide, so horizontal moves take two
  cells per tick to match the visual speed of vertical movement.
- Speed is constant (55ms/tick). It deliberately does **not** scale with
  progress — the old score-based ramp made the snake feel faster as it grew.
- Direction changes are queued, so mashing keys can't reverse you into yourself.
- Moving into the cell your tail is vacating this tick is legal (as it should be).
- **Eating yourself doesn't end the run.** Bite your own body and that cell
  plus everything from there back toward the tail tip detaches, goes red where
  it falls, and fades out over about three seconds while the head moves on
  into the scar — only a wall kills. The chunk is copied out of the snake's
  ring when it's severed, so it lies where it fell instead of sliding along
  with the body, and it stays solid (to you and to auto-hunt) until it fades.
  The red runs from the bite toward the tail tip, so it drains away rather
  than all blinking out on one tick.
- Pause and game-over show a floating menu centered over a blanked board.
  Pause preserves everything — the snake is hidden, not removed, and `p`
  brings it right back.
- Resizing the terminal refits the board without resetting the game: snake
  length, auto-hunt and wrap all survive. If the board shrinks so the
  snake no longer fits, it is relocated (coiled into the new board), not restarted.
- Auto-hunt (`h`) runs a multi-source BFS from all three tokens each tick and
  steps toward the closest one, avoiding your body and the wall on the full
  two-cell horizontal stride. Greedy, not immortal — a long body can still
  trap it.
- `make test` runs the headless hunt harness (`test_hunt.c`).

## Omarchy overlay

The same game as a fullscreen Quickshell overlay, next to the bar. `snake
--protocol` is the engine — the real rules, no curses — and the overlay is its
face. The terminal build and the overlay are one game: every command maps onto
the terminal's own key handler, and the visual language matches (green `$`,
white snake with a `^` `v` `<` `>` head, red corpses that fade, a green flash
border, red-orange while auto-hunt is armed, yellow ALL-CAPS status labels).

| File | Purpose |
|---|---|
| `manifest.json` | Plugin manifest — `schemaVersion` 1, kinds `overlay` + `bar-widget` |
| `Overlay.qml` | The surface: PanelWindow, engine child, painter, menus, keys |
| `BarWidget.qml` | The bar button that summons it |

### Install

This folder is the plugin folder — but **copy** it into `~/.config/omarchy/plugins/`,
do not symlink. The shell refuses symlinks (`omarchy-plugin-validate` fails
on any), and the shell inotify-watches that whole tree and reloads every plugin
on any close_write/create/delete/move:

```sh
make
mkdir -p ~/.config/omarchy/plugins
cp -r . ~/.config/omarchy/plugins/tsnake
omarchy-shell shell rescanPlugins
```

Then enable `io.github.londelo.tsnake` in Setup > Plugins, or add
`{"id": "io.github.londelo.tsnake"}` to a `bar.layout` section. A `tsnake`
button appears on the right of the bar; click it, or:

```sh
omarchy-shell shell toggle io.github.londelo.tsnake '{}'
```

Keys are the terminal's and nothing else: **arrows** steer, `h` auto-hunt, `p`
pause, `x` wrap, `r` restart, `q` quit, `Escape` dismiss. No wasd, no
uppercase, no `j/k/l`, no space, no Enter. Click a cell to place a `$`
(click it again to remove it); clicking does not cancel auto-hunt — it aims it.

### How it differs from the terminal

- **The engine self-ticks.** It emits a full board snapshot every 55 ms plus
  one after any input, so the overlay never drives the clock and QML stutter
  never becomes game lag. Frames are complete snapshots, never diffed — one
  dropped is one skipped paint.
- **Menus are QML's**, not the engine's, and the board's contents hide under
  them while frames keep being parsed.
- **Cells are square** (`--square-cells`); the board size is negotiated with
  `{"cmd":"size"}` and clamped by the engine to 10..400 × 6..250.
- **The high score is the engine's file**, at `~/.local/state/tsnake/highscore`
  (`--state`), never inside the plugin folder, and QML writes no file at all.
  Under `--protocol` a save is *banked*, not written: the only write is
  `{"cmd":"flush"}`, and the overlay sends it after the surface is down.

### Engine resolution

First hit wins: `$TSNAKE_BIN`, then `~/.local/state/tsnake/snake`, then the dev
build in this repo. Never the plugin folder — building in there would trip the
reload described above. If nothing starts, the overlay says so and tells you to
run `make` instead of sitting on a blank screen.

### Why the close order is fixed

`hide → flush → quit → kill`, in that order, on `close()`, `dismiss()` and
`Component.onDestruction`. Saving with the board visible would destroy the game
under the player (the reload the save itself triggers), and saving on death
would reset the game-over panel mid-display. Hidden means no process: an
engine left running grinds BFS for the rest of the session, and every hot
reload leaks another. If the overlay goes down hard, the engine sees stdin
close, banks the run and exits on its own.

### Checks

```sh
/usr/share/omarchy/bin/omarchy-plugin-validate .
/usr/lib/qt6/bin/qmllint -I /usr/share/omarchy/shell Overlay.qml BarWidget.qml
```

The overlay has not been played through Quickshell yet — see the note in
`.claude/CLAUDE.md` about acceptance being a human at the keyboard.
