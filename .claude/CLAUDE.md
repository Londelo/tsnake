# tsnake — Terminal Snake Game

Single-file C + ncurses snake game. No dependencies beyond ncurses; no build system beyond make.

## Structure

| File | Purpose |
|---|---|
| `snake.c` | The entire game (~400 lines) |
| `test_hunt.c` | Headless harness: `#define main snake_unused_main`, includes `snake.c`, drives the AI with no terminal |
| `Makefile` | `make` builds `snake`; `make run` plays; `make test` runs the hunt harness |

## Architecture (snake.c)

- **Game loop**: input drained every 5ms (`getch` in `nodelay` mode) so controls feel instant; the snake advances on a separate monotonic tick clock (`now_ms`, `tick_delay_ms`) — input latency never waits for a tick.
- **State**: `Game` struct holds a `Snake` (ring buffer of `Point`s in `MAX_SNAKE` cells), direction, a 4-deep `pending` direction queue (prevents key-mash self-reversal), score, wrap/pause/alive flags.
- **Rendering**: `draw()` uses curses diff-refresh — write cells with `mvaddch`, `refresh()` diffs. Colors via `init_pair` (red food `@`, green snake `O`/`o`).
- **Rules**: tail-vacating-a-cell is legal (see `snake_contains` skip_tail arg); high score in `.tsnake_highscore`.
- **Keys are lowercase-only, arrows-only steering** (`q`/`p`/`x`/`h`/`r` + arrows; no WASD/vim/uppercase/space/Enter aliases).
- **Speed is constant** (`TICK_MS` 55). It must NOT scale with score — the old score ramp read as "longer snake = faster" and was removed.
- **Aspect ratio**: terminal cells are ~2x taller than wide, so `game_step` advances horizontal moves two cells per tick (`advance_one` called twice, each cell checked) to even out visual speed.
- **Food**: `FOOD_COUNT` (3) tokens always on the board; eating respawns only that slot (`spawn_food` re-rolls clear of snake and other tokens).
- **Auto-hunt** (`h`): `hunt_step` does multi-source BFS from all food over an occupancy grid (`fill_occupancy`, guard-capped at 200×120), head steps to the min-distance neighbor. Validates both cells of the horizontal 2-cell stride; refuses reversals; falls back to straight/any-legal-cell when boxed in. Any steering key cancels hunt. Greedy AI, no flood-fill survival heuristic — can self-trap when long. While armed, the board border draws red-orange (`COLOR_PAIR(3)` + `A_BOLD`).
- **Menus**: `draw_panel()` renders the floating centered menu for pause/game-over — `werase`s its rect (hiding the board; state untouched underneath), cyan border, yellow title, key hints. Food/snake are simply not drawn while `paused || !alive`.
- **Status labels**: right-aligned ALL-CAPS yellow (`COLOR_PAIR(4)` + `A_BOLD`) `AUTO HUNT` / `WRAP` on the help row, only when enabled.
- **Resize preserves state**: `sanitize_after_resize` never calls `game_init` on the whole game — if the snake no longer fits it saves score/hunt/wrap/paused/alive/length, relocates via `relocate_snake` (serpentine coil from (0,0)), restores the saved fields, and re-rolls only food that's off-board or under the snake.

## Build

```sh
make        # gcc -O2 -Wall -Wextra -std=c11 ... -lncurses
make run
```

## Conventions

Keep it one file, zero deps. Controls are lowercase-only (arrows + `h`/`p`/`x`/`r`/`q`) — don't reintroduce vim/wasd/uppercase/space/Enter aliases; new keys go in `handle_key`. Board size lives in the `BOARD_W`/`BOARD_H` globals, recomputed by `fit_board()` from `COLS`/`LINES` (min 10×6); resize must never reset game state.
