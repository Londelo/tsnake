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

- Three food tokens are always on the map; eating one respawns just that one.
- Terminal cells are ~2x taller than wide, so horizontal moves take two
  cells per tick to match the visual speed of vertical movement.
- Speed is constant (55ms/tick). It deliberately does **not** scale with
  score — the old score-based ramp made the snake feel faster as it grew.
- Direction changes are queued, so mashing keys can't reverse you into yourself.
- Moving into the cell your tail is vacating this tick is legal (as it should be).
- Pause and game-over show a floating menu centered over a blanked board.
  Pause preserves everything — the snake is hidden, not removed, and `p`
  brings it right back.
- Resizing the terminal refits the board without resetting the game: score,
  snake length, auto-hunt and wrap all survive. If the board shrinks so the
  snake no longer fits, it is relocated (coiled into the new board), not restarted.
- High score persists to `~/.tsnake_highscore`.
- Auto-hunt (`h`) runs a multi-source BFS from all three tokens each tick and
  steps toward the closest one, avoiding your body and the wall on the full
  two-cell horizontal stride. Greedy, not immortal — a long body can still
  trap it.
- `make test` runs the headless hunt harness (`test_hunt.c`).
