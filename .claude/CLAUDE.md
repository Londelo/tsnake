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
- **State**: `Game` struct holds a `Snake` (ring buffer of `Point`s in `MAX_SNAKE` cells, plus the `wound`/`wound_len` severed-cell queue), direction, a 4-deep `pending` direction queue (prevents key-mash self-reversal), a `flash` countdown, and wrap/pause/alive flags. There is no score field.
- **Rendering**: `draw()` uses curses diff-refresh — write cells with `mvaddch`, `refresh()` diffs. Color pairs: 1 green (food `$` + eat flash), 2 white (snake `o`; head is a direction glyph `^ v < >` via `head_glyph(g->dir)`), 3 red (severed cells; the hunt border adds `A_BOLD` for red-orange), 4 yellow (status labels/titles), 5 cyan (menu border). Border priority in `draw`: `g->flash > 0` → green, else hunt → orange.
- **Scoring is length**: there is no score field — the snake's length IS the score. High score = best length ever, stored as one integer in `$HOME/.tsnake_highscore` (plain text, cwd fallback if HOME unset); `save_highscore()` is called on death, on `r` restart, and on `q` quit, and only writes when it beats the stored value.
- **Self-bite is a wound, not a death**: only a wall sets `alive = 0`. `advance_one` lands one cell per call and asks `snake_chain_depth` where the landing cell sat in the body: `-1` (free, incl. every cell the body ever shed) or `len-1` (the vacating tail tip — see the classic rule) is an ordinary push+pop, anything else is a bite. `snake_bite` severs the bitten cell plus everything toward the tail tip by setting `len = depth`, copying those points into `Snake.wound` first (the ring belongs to the live body, so an un-copied corpse drifts with the head instead of lying where it fell) and staggering `ttl` across `WOUND_FADE` so the chunk drains from the bitten end toward the tip. Corpses are drawn red (`COLOR_PAIR(3)`, `A_DIM` over the last third) and stay solid via `snake_occupied` (= live body ∪ `snake_wound_contains`) until `wound_tick` expires them.
- **Keys are lowercase-only, arrows-only steering** (`q`/`p`/`x`/`h`/`r` + arrows; no WASD/vim/uppercase/space/Enter aliases).
- **Speed is constant** (`TICK_MS` 55). It must NOT scale with progress — the old score-based ramp read as "longer snake = faster" and was removed.
- **Aspect ratio**: terminal cells are ~2x taller than wide, so `game_step` advances horizontal moves two cells per tick (`advance_one` called twice, each cell checked) to even out visual speed.
- **Food**: `FOOD_COUNT` (3) tokens always on the board; eating respawns only that slot. `spawn_food` re-rolls until the cell is clear of the snake (`snake_occupied`) and of every OTHER token (`other_token_at`) — it must test "is something else here", never `food_index_at(...) != i`, because an empty cell reads `-1` which is `!= i`, so that version rejects every legal cell and only escapes by re-rolling onto the token's own old position, which after an eat is under the head: an infinite loop that looks like a frozen game. Bounded at 1000 rolls so a packed board can't hang either.
- **Auto-hunt** (`h`): `hunt_step` does multi-source BFS from all food over an occupancy grid (`fill_occupancy`, guard-capped at 200×120), head steps to the min-distance neighbor. Validates both cells of the horizontal 2-cell stride; refuses reversals; falls back to straight/any-legal-cell when boxed in. Any steering key cancels hunt. Greedy AI, no flood-fill survival heuristic — can self-trap when long. While armed, the board border draws red-orange (`COLOR_PAIR(3)` + `A_BOLD`).
- **Menus**: `draw_panel()` renders the floating centered menu for pause/game-over — `werase`s its rect (hiding the board; state untouched underneath), cyan border, yellow title, key hints. Food/snake/wounds are hidden while `paused || !alive` under ONE `if` block — never an early `return` there: the help row, both panels and the trailing `refresh()` live below it, and returning early renders no menu and flushes nothing (the screen just freezes).
- **Status labels**: right-aligned ALL-CAPS yellow (`COLOR_PAIR(4)` + `A_BOLD`) `AUTO HUNT` / `WRAP` on the help row, only when enabled.
- **Resize preserves state**: `sanitize_after_resize` never calls `game_init` on the whole game — if the snake no longer fits it saves hunt/wrap/paused/alive/length, relocates via `relocate_snake` (serpentine coil from (0,0)), restores the saved fields, re-rolls only food that's off-board or under the snake, and drops any corpse cell that ended up off the new board. `KEY_RESIZE` runs `fit_board` + this, then `endwin()`/`refresh()` for a clean full redraw.

## Build

```sh
make        # gcc -O2 -Wall -Wextra -std=c11 ... -lncurses
make run
```

## Conventions

Keep it one file, zero deps. Controls are lowercase-only (arrows + `h`/`p`/`x`/`r`/`q`) — don't reintroduce vim/wasd/uppercase/space/Enter aliases; new keys go in `handle_key`. Board size lives in the `BOARD_W`/`BOARD_H` globals, recomputed by `fit_board()` from `COLS`/`LINES` (min 10×6); resize must never reset game state.
