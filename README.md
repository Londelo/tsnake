# tsnake

Snake in your terminal. Written in C with ncurses — one file, zero dependencies, instant startup.

## Build & run

```sh
make
./snake
```

Requires `ncurses` dev headers (`sudo pacman -S ncurses` on Arch — usually already installed).

## Controls

| Key | Action |
|---|---|
| Arrows / WASD / vim (h/j/k/l) | Steer (also cancels auto-hunt) |
| `H` (shift+h) | Toggle auto-hunt — AI chases the nearest food |
| `p` or space | Pause |
| `x` | Toggle wrap-around walls |
| `r` | Restart |
| `q` | Quit |

## Details

- Three food tokens are always on the map; eating one respawns just that one.
- Terminal cells are ~2x taller than wide, so horizontal moves take two
  cells per tick to match the visual speed of vertical movement.
- Snake speed ramps up as you eat (80ms/tick down to 30ms).
- Direction changes are queued, so mashing keys can't reverse you into yourself.
- Moving into the cell your tail is vacating this tick is legal (as it should be).
- High score persists to `~/.tsnake_highscore`.
- Auto-hunt (`H`) runs a multi-source BFS from all three tokens each tick and
  steps toward the closest one, avoiding your body and the wall on the full
  two-cell horizontal stride. Greedy, not immortal — a long body can still
  trap it.
- `make test` runs the headless hunt harness (`test_hunt.c`).
