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
| Arrows / WASD / vim (h/j/k/l) | Steer |
| `p` or space | Pause |
| `x` | Toggle wrap-around walls |
| `r` | Restart |
| `q` | Quit |

## Details

- Snake speed ramps up as you eat (120ms/tick down to 45ms).
- Direction changes are queued, so mashing keys can't reverse you into yourself.
- Moving into the cell your tail is vacating this tick is legal (as it should be).
- High score persists to `~/.tsnake_highscore`.
