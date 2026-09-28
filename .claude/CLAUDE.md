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
- **Rules**: tail-vacating-a-cell is legal (see `snake_contains` skip_tail arg); high score in `.tsnake_highscore`.
- **Aspect ratio**: terminal cells are ~2x taller than wide, so `game_step` advances horizontal moves two cells per tick (`advance_one` called twice, each cell checked) to even out visual speed; speed ramps 80ms → 30ms per tick as score climbs.
- **Food**: `FOOD_COUNT` (3) tokens always on the board; eating respawns only that slot (`spawn_food` re-rolls clear of snake and other tokens).

## Build

```sh
make        # gcc -O2 -Wall -Wextra -std=c11 ... -lncurses
make run
```

## Conventions

Keep it one file, zero deps. Controls are vim + arrows + wasd; new keys go in `handle_key`. Board size lives in the `BOARD_W`/`BOARD_H` globals, recomputed by `fit_board()` from `COLS`/`LINES` (min 10×6).
