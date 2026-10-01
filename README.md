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
