# tsnake — Terminal Snake Game

Single-file C + ncurses snake game. No dependencies beyond ncurses; no build system beyond make.

## Structure

| File | Purpose |
|---|---|
| `snake.c` | The entire game (~280 lines) |
| `Makefile` | `make` builds `snake`; `make run` builds and plays |

## Architecture (snake.c)

- **Game loop**: input drained every 5ms (`getch` in `nodelay` mode) so controls feel instant; the snake advances on a separate monotonic tick clock (`now_ms`, `tick_delay_ms`) — input latency never waits for a tick.
- **State**: `Game` struct holds a `Snake` (ring buffer of `Point`s in `MAX_SNAKE` cells), direction, a 4-deep `pending` direction queue (prevents key-mash self-reversal), score, wrap/pause/alive flags.
- **Rendering**: `draw()` uses curses diff-refresh — write cells with `mvaddch`, `refresh()` diffs. Colors via `init_pair` (red food `@`, green snake `O`/`o`).
- **Rules**: tail-vacating-a-cell is legal (see `snake_contains` skip_tail arg); speed ramps 120ms → 45ms per tick as score climbs; high score in `.tsnake_highscore`.

## Build

```sh
make        # gcc -O2 -Wall -Wextra -std=c11 ... -lncurses
make run
```

## Conventions

Keep it one file, zero deps. Controls are vim + arrows + wasd; new keys go in `handle_key`. Board size is `BOARD_W`/`BOARD_H` defines at the top.
