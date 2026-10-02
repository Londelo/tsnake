/*
 * tsnake — terminal snake in C + ncurses
 *
 * Build: make   Run: ./snake   Quit: q
 */

#define _POSIX_C_SOURCE 200809L

#include <curses.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define MAX_SNAKE 4096
#define MIN_BOARD_W 10
#define MIN_BOARD_H 6
#define INPUT_QUEUE_SIZE 4
#define FOOD_COUNT 3      /* tokens the game starts out with */
#define MAX_FOOD 64       /* ... plus however many the player clicks in */
#define FLASH_TICKS 10    /* ticks the border stays green after eating (~0.5s) */
#define WOUND_FADE 55     /* ticks a severed cell stays red before vanishing (~3s) */

/* board size is derived from the terminal on startup and on SIGWINCH */
static int BOARD_W = 40;
static int BOARD_H = 20;

/* Layout: row 0 = header, rows 1..BOARD_H+2 = bordered play field,
   the cell (x, y) is drawn at screen row y+CELL_TOP, screen col x+CELL_LEFT
   (the box border occupies the outer ring).
   The click handler maps mouse coordinates back through this same pair, so
   what you point at is what gets drawn — change one, not both. */
#define CELL_TOP 2
#define CELL_LEFT 2

static void fit_board(void) {
    int w = COLS - 4;      /* border (2 cols) + 2 col right margin */
    int h = LINES - 6;     /* header + border + help row + breathing room */
    BOARD_W = w < MIN_BOARD_W ? MIN_BOARD_W : w;
    BOARD_H = h < MIN_BOARD_H ? MIN_BOARD_H : h;
}

typedef struct {
    int x, y;
} Point;

static int in_bounds(Point p) {
    return p.x >= 0 && p.x < BOARD_W && p.y >= 0 && p.y < BOARD_H;
}

/* A self bite is a wound, not a death. The bitten cell and every cell from
   there toward the tail tip detach, go red where they fell, and fade out a
   few seconds later while the head keeps travelling.
   The severed cells have to be COPIED OUT of the ring into `wound`, because
   the ring belongs to the live body: its cells keep moving with the head, so
   a cell that has dropped out of the body no longer holds the position it
   fell at. Reading the corpse back out of the ring by index would make it
   drift along with the snake instead of lying where it fell.
   Each severed cell carries its own countdown, so the chunk fades as a wave
   running away from the bite — the bitten cell dies first, the tail tip last
   — rather than the whole chunk blinking out on one tick. */
typedef struct {
    Point p;
    int ttl;            /* ticks left before this cell vanishes; <=0 = gone */
} WoundCell;

typedef struct {
    Point cells[MAX_SNAKE];
    int head;       /* index of the head */
    int len;        /* live body: the len ring cells ending at `head` */
    /* the severed tail, still bleeding out: drawn red, and still solid */
    WoundCell wound[MAX_SNAKE];
    int wound_len;
} Snake;

/* A token the player clicked in is THEIRS: eating it spends it, it does not
   teleport somewhere random. The game's own FOOD_COUNT tokens keep respawning
   when eaten. The flag travels with the token, not with its slot index,
   because removing a token compacts the array and shuffles indices. */
typedef struct {
    Point p;
    int placed;
} Food;

typedef struct {
    Food food[MAX_FOOD];
    int food_n;            /* live tokens, always [0, food_n) */
    Snake snake;
    int dir[2];            /* current direction: dx, dy */
    int pending[INPUT_QUEUE_SIZE][2]; /* queued direction changes */
    int pending_head, pending_count;
    int flash;               /* ticks left of green border flash after a eat */
    int alive;
    int paused;
    int wrap;
    int hunt;              /* auto-hunt mode: AI steers to nearest food */
} Game;

static int rng(int limit) {
    return rand() % limit;
}

/* ~/.tsnake_highscore (falls back to the cwd if HOME is unset) */
static const char *highscore_path(void) {
    static char path[512];
    const char *home = getenv("HOME");
    if (home && *home)
        snprintf(path, sizeof(path), "%s/.tsnake_highscore", home);
    else
        snprintf(path, sizeof(path), ".tsnake_highscore");
    return path;
}

/* the high score IS the best snake length ever reached */
static void load_highscore(int *best) {
    *best = 0;
    FILE *f = fopen(highscore_path(), "r");
    if (f) {
        if (fscanf(f, "%d", best) != 1) *best = 0;
        fclose(f);
    }
}

static void save_highscore(int length) {
    int best = 0;
    load_highscore(&best);
    if (length <= best) return;
    FILE *f = fopen(highscore_path(), "w");
    if (f) {
        fprintf(f, "%d\n", length);
        fclose(f);
    }
}

static void snake_init(Snake *s) {
    s->head = 0;
    s->len = 0;
    s->wound_len = 0;
}

/* The ring head, and the live body length, both counted in ring cells
   BEHIND the head. The body never rewrites its own cells, so a step can
   always be read straight back down the ring. */
static void snake_push(Snake *s, Point p) {
    s->head = (s->head + 1) % MAX_SNAKE;
    s->cells[s->head] = p;
    if (s->len < MAX_SNAKE) s->len++;
}

/* a normal step: the tail tip keeps up with the head */
static void snake_pop_tail(Snake *s) {
    if (s->len > 0) s->len--;
}

/* How far back from the head does the live body run? 0 is the head itself,
   len-1 is the tail tip. -1 means p is not part of the live body at all —
   which includes every cell the body has ever shed, since the ring cells
   holding those positions no longer belong to it. */
static int snake_chain_depth(const Snake *s, Point p) {
    for (int i = 0; i < s->len; i++) {
        int idx = (s->head - i + MAX_SNAKE * 2) % MAX_SNAKE;
        if (s->cells[idx].x == p.x && s->cells[idx].y == p.y) return i;
    }
    return -1;
}

/* Is p one of the live body's cells? */
static int snake_contains(const Snake *s, Point p) {
    return snake_chain_depth(s, p) >= 0;
}

/* Still lying where it fell? A severed cell is drawn red, and stays solid to
   the hunt AI, right up until its own countdown runs out. */
static int snake_wound_contains(const Snake *s, Point p) {
    for (int i = 0; i < s->wound_len; i++)
        if (s->wound[i].ttl > 0 &&
            s->wound[i].p.x == p.x && s->wound[i].p.y == p.y) return 1;
    return 0;
}

/* is this cell occupied — living body, or a corpse still bleeding out? */
static int snake_occupied(const Game *g, Point p) {
    return snake_contains(&g->snake, p) || snake_wound_contains(&g->snake, p);
}

/* A self bite severs the cell at chain depth `depth` and every cell from
   there toward the tail tip, so the live body stops at the bite and the
   length on screen is the live snake from this tick onward. The severed
   positions are copied out of the ring first: shortening the body is what
   stops the ring from holding them (see WoundCell). */
static void snake_bite(Snake *s, int depth) {
    if (depth < 0 || depth >= s->len) return;
    int n = s->len - depth;
    if (n > MAX_SNAKE - s->wound_len) n = MAX_SNAKE - s->wound_len;
    if (n <= 0) return;
    for (int i = 0; i < n; i++) {
        int idx = (s->head - (depth + i) + MAX_SNAKE * 2) % MAX_SNAKE;
        s->wound[s->wound_len].p = s->cells[idx];
        /* The bitten cell dies first and the tail tip last, so the red runs
           away from the bite rather than the whole chunk ending on one tick.
           The spread stays inside WOUND_FADE: however big the chunk is, the
           board is clean again within a few seconds of the bite. */
        s->wound[s->wound_len].ttl =
            WOUND_FADE / 2 + (WOUND_FADE / 2) * i / (n > 1 ? n - 1 : 1);
        s->wound_len++;
    }
    s->len = depth;
}

/* one tick of bleeding. The queue drains from the front, which is always the
   oldest bite; a cell that expires in the middle of the queue (possible once
   a second bite lands behind the first) is harmless, since every reader
   checks ttl before trusting a cell. */
static void wound_tick(Snake *s) {
    for (int i = 0; i < s->wound_len; i++) s->wound[i].ttl--;
    int gone = 0;
    while (gone < s->wound_len && s->wound[gone].ttl <= 0) gone++;
    if (gone == 0) return;                          /* nothing has faded yet */
    s->wound_len -= gone;
    if (s->wound_len > 0)
        memmove(s->wound, &s->wound[gone],
                (size_t)s->wound_len * sizeof(s->wound[0]));
}

static int food_index_at(const Game *g, Point p) {
    for (int i = 0; i < g->food_n; i++)
        if (g->food[i].p.x == p.x && g->food[i].p.y == p.y) return i;
    return -1;
}

/* is a DIFFERENT token already sitting on p? slot i's own cell does not
   count, since that is the one being re-rolled */
static int other_token_at(const Game *g, Point p, int i) {
    for (int j = 0; j < g->food_n; j++)
        if (j != i && g->food[j].p.x == p.x && g->food[j].p.y == p.y) return 1;
    return 0;
}

/* take a token out of play for good, compacting the live prefix */
static void remove_food(Game *g, int i) {
    if (i < 0 || i >= g->food_n) return;
    g->food_n--;
    for (int j = i; j < g->food_n; j++) g->food[j] = g->food[j + 1];
}

static void spawn_food(Game *g, int i) {
    /* Re-roll until the token lands clear of the snake and of every other
       token. The test has to ask "is something else already here" rather than
       "food_index_at != i": an empty cell reads as -1, which is != i, so that
       version rejects every legal cell and escapes only by re-rolling onto the
       token's own old position — which, right after an eat, is under the head,
       so the loop never ends and the game hangs where it looks like it froze.
       The cap is the same kind of guard the BFS uses: a board packed solid has
       no legal cell to offer, and a bounded spin beats a frozen terminal. */
    for (int guard = 0; guard < 1000; guard++) {
        g->food[i].p.x = rng(BOARD_W);
        g->food[i].p.y = rng(BOARD_H);
        /* the `placed` flag rides along: this re-rolls where a token sits, never
           what kind of token it is. "Clear of every other token" also means a
           random respawn can never stack on top of one the player clicked in. */
        if (!snake_occupied(g, g->food[i].p) && !other_token_at(g, g->food[i].p, i))
            return;
    }
}

/* The board is never left empty of tokens. Food is the only way to grow, so a
   board with none on it is a dead game — and the auto-hunt AI, whose entire
   plan is a distance field seeded FROM the tokens, then has nothing to steer
   by: no seeds means every cell reads "no path", and the snake walks straight
   forever (see hunt_step).
   Tokens leave play in exactly two ways — the player clicks one away, or the
   snake eats the last of the ones it clicked in — and both call this after it
   happens. What comes back is one of the GAME's tokens (placed = 0), so it
   respawns in turn rather than being spent. */
static void ensure_food(Game *g) {
    if (g->food_n > 0) return;
    g->food[0].placed = 0;
    g->food_n = 1;
    spawn_food(g, 0);
}

static void game_init(Game *g) {
    memset(g, 0, sizeof(*g));   /* also wipes any leftover death debris */
    snake_init(&g->snake);
    /* push tail-first so the last cell pushed is the head at `start` */
    Point start = { BOARD_W / 4, BOARD_H / 2 };
    for (int i = 2; i >= 0; i--) {
        Point seg = { start.x - i, start.y };
        snake_push(&g->snake, seg);
    }
    g->dir[0] = 1; g->dir[1] = 0;
    g->alive = 1;

    /* the game's own tokens: respawned when eaten */
    g->food_n = FOOD_COUNT;
    for (int i = 0; i < FOOD_COUNT; i++) {
        g->food[i].placed = 0;
        spawn_food(g, i);
    }
}

static void queue_direction(Game *g, int dx, int dy) {
    int last_dx = g->dir[0], last_dy = g->dir[1];
    if (g->pending_count > 0) {
        int i = (g->pending_head + g->pending_count - 1) % INPUT_QUEUE_SIZE;
        last_dx = g->pending[i][0];
        last_dy = g->pending[i][1];
    }
    /* ignore reversals and no-ops relative to the last queued move */
    if (dx == last_dx && dy == last_dy) return;
    if (dx == -last_dx && dy == -last_dy) return;
    if (g->pending_count < INPUT_QUEUE_SIZE) {
        int i = (g->pending_head + g->pending_count) % INPUT_QUEUE_SIZE;
        g->pending[i][0] = dx;
        g->pending[i][1] = dy;
        g->pending_count++;
    }
}

/* One cell forward. game_step calls this twice per tick for a horizontal
   move (terminal cells are ~2x taller than wide), checking each cell on its
   own, so a step only ever has to reason about the single cell it lands on.
   In wrap mode the seam is a tunnel; otherwise a wall is the ONLY thing that
   kills — a step onto the snake's own body is a bite, not a death: that cell
   and every cell from there back toward the tail tip detach, go red where
   they fall, and the head moves on into the scar they leave.
   Two landings are never a bite: the tail tip, which is vacated by the very
   act of stepping, and any cell the body has already shed, which the head is
   merely flying over — its own past is not in the way. */
static void advance_one(Game *g) {
    Snake *s = &g->snake;
    Point head = s->cells[s->head];
    Point next = { head.x + g->dir[0], head.y + g->dir[1] };

    if (g->wrap) {
        next.x = (next.x + BOARD_W) % BOARD_W;
        next.y = (next.y + BOARD_H) % BOARD_H;
    } else if (!in_bounds(next)) {
        g->alive = 0;   /* walls stay lethal */
        return;
    }

    int fi = food_index_at(g, next);
    if (fi >= 0) {
        snake_push(s, next);
        g->flash = FLASH_TICKS;         /* celebrate on the border */
        if (g->food[fi].placed) remove_food(g, fi);  /* the player's: spent */
        else spawn_food(g, fi);                      /* ours: re-rolled */
        ensure_food(g);                 /* never eat the board down to nothing */
        return;                         /* a step that eats does not bite */
    }

    int depth = snake_chain_depth(s, next);
    if (depth < 0 || depth == s->len - 1) {
        snake_push(s, next);
        snake_pop_tail(s);
        return;
    }

    /* A real bite: the bitten cell and everything from there toward the tail
       tip detach, and the head moves on into the wound they used to be. */
    snake_bite(s, depth);
    snake_push(s, next);
}

/* ---- auto-hunt: multi-source BFS from all food to the head ---- */

/* Guard rails for the BFS scratch arrays. Beyond these the AI declines to
   plan at all and the snake simply steers straight, so they have to cover any
   terminal a person can actually open — a maximized window on a wide monitor
   goes past 200 columns without trying. */
#define MAX_BOARD_W 400
#define MAX_BOARD_H 250

/* Fills an occupancy grid from the snake — the live body, and any severed
   cell still bleeding out — so hunt mode can read it in O(1) per cell.
   Both passes only ever walk the live body and the live corpse, never the
   whole ring, because hunt mode calls this every single tick.
   A severed tail counts as solid right up until it fades: until then it is
   still a wall in the middle of the board, so hunt mode gives it the same
   wide berth it gives the live body. */
static void fill_occupancy(Game *g, unsigned char *occ, int w, int h) {
    memset(occ, 0, (size_t)w * h);
    Snake *s = &g->snake;
    for (int i = 0; i < s->len; i++) {
        int idx = (s->head - i + MAX_SNAKE * 2) % MAX_SNAKE;
        Point p = s->cells[idx];
        if (p.x >= 0 && p.x < w && p.y >= 0 && p.y < h) occ[p.y * w + p.x] = 1;
    }
    for (int i = 0; i < s->wound_len; i++) {
        if (s->wound[i].ttl <= 0) continue;
        Point p = s->wound[i].p;
        if (p.x >= 0 && p.x < w && p.y >= 0 && p.y < h) occ[p.y * w + p.x] = 1;
    }
}

static const int HUNT_DX[4] = {1, -1, 0, 0};
static const int HUNT_DY[4] = {0, 0, 1, -1};

/* Where one step from p along d lands, and whether the snake may be there at
   all. Wrap has to agree with advance_one here, or the AI would refuse to
   cross a seam the game is perfectly happy to tunnel through and starve
   itself waiting for food on the far side of the board.
   Every stepping the hunt AI does — the BFS wave included — goes through this
   one function, so the board the AI plans on cannot drift away from the board
   the snake actually travels. */
static int hunt_next_cell(Game *g, Point p, int dx, int dy, Point *out) {
    out->x = p.x + dx;
    out->y = p.y + dy;
    if (g->wrap) {
        out->x = (out->x + BOARD_W) % BOARD_W;
        out->y = (out->y + BOARD_H) % BOARD_H;
        return 1;
    }
    return in_bounds(*out);
}

/* Is the WHOLE stride from p along (dx, dy) free — of the live body and of any
   corpse still bleeding out? A horizontal move covers two cells per tick, so
   the AI has to walk both of them: a direction whose second cell is taken is
   no escape, it only postpones the crunch by a tick. The head ends the tick on
   the FAR cell; `first`, when asked for, is the near one — that is the cell the
   distance field is read at. Pass NULL for a plain yes/no. */
static int hunt_stride_free(Game *g, Point from, int dx, int dy, Point *first) {
    Point c1, c2;
    if (!hunt_next_cell(g, from, dx, dy, &c1)) return 0;
    if (snake_occupied(g, c1)) return 0;
    if (dy == 0) {
        if (!hunt_next_cell(g, c1, dx, dy, &c2)) return 0;
        if (snake_occupied(g, c2)) return 0;
    }
    if (first) *first = c1;
    return 1;
}

/* chooses the best direction toward the nearest food; returns 0 if the
   AI cannot find any legal move */
static int hunt_step(Game *g, int out[2]) {
    if (BOARD_W > MAX_BOARD_W || BOARD_H > MAX_BOARD_H) return 0;
    static int dist[MAX_BOARD_H][MAX_BOARD_W];
    static int qx[MAX_BOARD_W * MAX_BOARD_H];
    static int qy[MAX_BOARD_W * MAX_BOARD_H];
    static unsigned char occ[MAX_BOARD_H * MAX_BOARD_W];

    int w = BOARD_W, h = BOARD_H;
    fill_occupancy(g, occ, w, h);

    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++) dist[y][x] = -1;

    /* seed the queue with every food token: BFS then yields distance-to-
       nearest-token for every reachable cell */
    int qh = 0, qt = 0;
    for (int i = 0; i < g->food_n; i++) {
        Point f = g->food[i].p;
        if (f.x < 0 || f.x >= w || f.y < 0 || f.y >= h) continue;
        if (dist[f.y][f.x] == 0) continue;      /* duplicate token */
        dist[f.y][f.x] = 0;
        qx[qt] = f.x; qy[qt] = f.y; qt++;
    }

    /* The wave spreads via hunt_next_cell, the same step advance_one takes, so
       in wrap mode it crosses the seam the game tunnels through. Truncating it
       at the edges instead — clipping nx/ny against the board rather than
       wrapping them — made the AI plan on a plane while the snake lived on a
       torus, and that mismatch is fatal rather than merely suboptimal: a body
       wall running edge to edge, which is just what a long snake looks like,
       seals the wave off in the plane topology even though the real board has
       an opening at the seam. Every legal neighbour of the head then reads
       dist -1 ("no food reachable"), the loop below finds no direction worth
       taking, and the boxed-in branch falls through to marching straight —
       which in wrap mode is always legal, so the snake walks a single
       horizontal line across the screen and through the seam forever, never
       turning, never eating. */
    while (qh < qt) {
        Point cur = { qx[qh], qy[qh] }; qh++;
        for (int d = 0; d < 4; d++) {
            Point np;
            if (!hunt_next_cell(g, cur, HUNT_DX[d], HUNT_DY[d], &np)) continue;
            if (dist[np.y][np.x] != -1 || occ[np.y * w + np.x]) continue;
            dist[np.y][np.x] = dist[cur.y][cur.x] + 1;
            qx[qt] = np.x; qy[qt] = np.y; qt++;
        }
    }

    Point head = g->snake.cells[g->snake.head];
    int best_dist = 1 << 30, best_d = -1;
    for (int d = 0; d < 4; d++) {
        int dx = HUNT_DX[d], dy = HUNT_DY[d];
        if (dx == -g->dir[0] && dy == -g->dir[1]) continue; /* no reversal */
        Point c1;
        if (!hunt_stride_free(g, head, dx, dy, &c1)) continue;
        int dd = dist[c1.y][c1.x];
        if (dd < 0) continue;                 /* no path to any food */
        if (dd < best_dist) { best_dist = dd; best_d = d; }
    }

    if (best_d >= 0) { out[0] = HUNT_DX[best_d]; out[1] = HUNT_DY[best_d]; return 1; }

    /* Nothing is reachable: stay alive and stay mobile rather than starve in
       place. Keep straight ONLY when the whole stride is free, else take the
       first direction whose whole stride is free. Testing a single cell here
       made "legal" a lie for a horizontal move — the second cell of the stride
       then ran into the wall (a death) or into its own body — and because the
       straight case always wins when it is allowed at all, one half-checked
       cell was enough to pin the AI to that direction indefinitely. */
    if (hunt_stride_free(g, head, g->dir[0], g->dir[1], NULL)) return 0;
    for (int d = 0; d < 4; d++) {
        int dx = HUNT_DX[d], dy = HUNT_DY[d];
        if (dx == -g->dir[0] && dy == -g->dir[1]) continue;
        if (hunt_stride_free(g, head, dx, dy, NULL)) {
            out[0] = dx; out[1] = dy; return 1;
        }
    }
    return 0;
}

static void game_step(Game *g) {
    Snake *s = &g->snake;

    if (g->paused || !g->alive) return;
    if (g->flash > 0) g->flash--;

    /* a severed cell is a live thing for WOUND_FADE ticks (see WoundCell) */
    wound_tick(s);

    if (g->hunt) {
        int d[2];
        /* hunt_step returning 0 means "keep going straight" */
        if (hunt_step(g, d)) { g->dir[0] = d[0]; g->dir[1] = d[1]; }
        g->pending_count = 0;
    }

    if (g->pending_count > 0) {
        /* a lean that lands on the snake's own body is a bite, not a
           death: whatever direction it clips (see advance_one) */
        g->dir[0] = g->pending[g->pending_head][0];
        g->dir[1] = g->pending[g->pending_head][1];
        g->pending_head = (g->pending_head + 1) % INPUT_QUEUE_SIZE;
        g->pending_count--;
    }

    /* Terminal cells are ~2x taller than wide, so a vertical cell per tick
       *looks* twice as fast as a horizontal one. Horizontal moves take two
       cells per tick (each cell checked separately) to even out visual
       speed. */
    int steps = (g->dir[1] == 0) ? 2 : 1;
    for (int k = 0; k < steps && g->alive; k++) advance_one(g);
}

/* game speed: a constant tick. Speed deliberately does NOT scale with
   progress — tying it to the old score made the snake feel faster as it
   grew. Keep it constant. */
#define TICK_MS 55
static int tick_delay_ms(const Game *g) {
    (void)g;
    return TICK_MS;
}

/* floating centered menu for the pause / game-over screens: blanks its
   rectangle (hiding the board behind it) and shows a titled box. Game
   state is untouched — this is pure presentation. */
static void draw_panel(const char *title, const char *lines[], int nlines) {
    int w = (int)strlen(title) + 8;
    for (int i = 0; i < nlines; i++) {
        int lw = (int)strlen(lines[i]) + 4;
        if (lw > w) w = lw;
    }
    if (w < 26) w = 26;
    if (w > COLS - 2) w = COLS - 2;
    int h = nlines + 3;   /* border · title · lines · border */
    int y0 = (LINES - h) / 2; if (y0 < 1) y0 = 1;
    int x0 = (COLS - w) / 2;  if (x0 < 1) x0 = 1;

    WINDOW *p = derwin(stdscr, h, w, y0, x0);
    werase(p);   /* derwin shares stdscr's buffer: this hides the board */
    if (has_colors()) wattron(p, COLOR_PAIR(5) | A_BOLD);
    box(p, 0, 0);
    if (has_colors()) wattroff(p, COLOR_PAIR(5) | A_BOLD);
    if (has_colors()) wattron(p, COLOR_PAIR(4) | A_BOLD);
    mvwprintw(p, 1, (w - (int)strlen(title)) / 2, "%s", title);
    if (has_colors()) wattroff(p, COLOR_PAIR(4) | A_BOLD);
    for (int i = 0; i < nlines; i++)
        mvwprintw(p, i + 2, 2, "%-*s", w - 4, lines[i]);
}

/* the head wears an arrow pointing where the snake is heading */
static chtype head_glyph(const int dir[2]) {
    if (dir[1] == -1) return '^';
    if (dir[1] == 1)  return 'v';
    if (dir[0] == -1) return '<';
    return '>';
}

static void draw(Game *g, int highscore) {
    erase();

    /* board box occupies rows 1..BOARD_H+2, cols 1..BOARD_W+2. Border
       priority: a fresh eat flashes green, else auto-hunt burns red-orange */
    WINDOW *board = derwin(stdscr, BOARD_H + 2, BOARD_W + 2, 1, 1);
    int border_pair = 0;   /* 0 = default */
    if (has_colors()) {
        if (g->flash > 0) border_pair = 1;       /* green flash */
        else if (g->hunt) border_pair = 3;       /* red-orange */
        if (border_pair) attron(COLOR_PAIR(border_pair) | A_BOLD);
    }
    box(board, 0, 0);
    if (border_pair && has_colors()) attroff(COLOR_PAIR(border_pair) | A_BOLD);

    mvprintw(0, 2, " tsnake ");
    attron(A_BOLD);
    printw("length %d", g->snake.len);
    attroff(A_BOLD);
    printw("  high %d", highscore);

    /* Food, snake and wounds hide while a menu floats over the board — the
       state is fully preserved underneath, only the pixels go away. They go
       under one `if`, not an early return: the help row, the floating panels
       and the refresh() at the bottom of this function still have to run, and
       bailing out here left the menus unrendered and the screen unflushed. */
    if (!g->paused && g->alive) {
        /* cells sit at CELL_TOP/CELL_LEFT: one for the box's origin, one for its
           border — the same pair the click handler subtracts */
        if (has_colors()) attron(COLOR_PAIR(1));
        for (int i = 0; i < g->food_n; i++)
            mvaddch(CELL_TOP + g->food[i].p.y, CELL_LEFT + g->food[i].p.x, '$');
        if (has_colors()) attroff(COLOR_PAIR(1));

        /* The severed tail lies red where it fell until its own countdown runs
           out. It goes under the live body, so the head moving into the scar it
           just made still reads as a head, and it dims over its last third so
           the chunk fades away rather than blinking out on one tick. */
        if (has_colors()) attron(COLOR_PAIR(3));
        for (int i = 0; i < g->snake.wound_len; i++) {
            int ttl = g->snake.wound[i].ttl;
            if (ttl <= 0) continue;
            Point p = g->snake.wound[i].p;
            if (!in_bounds(p)) continue;
            if (ttl < WOUND_FADE / 3 && has_colors()) attron(A_DIM);
            mvaddch(CELL_TOP + p.y, CELL_LEFT + p.x, 'o');
            if (ttl < WOUND_FADE / 3 && has_colors()) attroff(A_DIM);
        }
        if (has_colors()) attroff(COLOR_PAIR(3));

        if (has_colors()) attron(COLOR_PAIR(2));
        chtype head = head_glyph(g->dir);
        for (int i = 0; i < g->snake.len; i++) {
            int idx = (g->snake.head - i + MAX_SNAKE) % MAX_SNAKE;
            Point p = g->snake.cells[idx];
            mvaddch(CELL_TOP + p.y, CELL_LEFT + p.x, i == 0 ? head : 'o');
        }
        if (has_colors()) attroff(COLOR_PAIR(2));
    }

    int help_row = BOARD_H + 4;
    if (help_row < LINES) {
        mvprintw(help_row, 2, "arrows move · h auto-hunt · x wrap · p pause · r restart · q quit");
        /* the mouse hint rides on its OWN row rather than tags onto the keys:
           the status labels right-align against COLS on this line, and a longer
           left-hand string would run underneath them */
        if (help_row + 1 < LINES) {
            if (has_colors()) attron(A_DIM);
            mvprintw(help_row + 1, 2,
                     "click inside the box to place a $ · click a $ to remove it");
            if (has_colors()) attroff(A_DIM);
        }
        /* right-aligned ALL-CAPS status labels, yellow when armed */
        int right = COLS - 3;
        if (g->wrap) {
            right -= 6;
            if (right >= 2) {
                if (has_colors()) attron(COLOR_PAIR(4) | A_BOLD);
                mvprintw(help_row, right, "WRAP");
                if (has_colors()) attroff(COLOR_PAIR(4) | A_BOLD);
            }
        }
        if (g->hunt) {
            right -= 11;
            if (right >= 2) {
                if (has_colors()) attron(COLOR_PAIR(4) | A_BOLD);
                mvprintw(help_row, right, "AUTO HUNT");
                if (has_colors()) attroff(COLOR_PAIR(4) | A_BOLD);
            }
        }
    }

    if (!g->alive) {
        char info[64];
        snprintf(info, sizeof(info), "length %d    high %d", g->snake.len, highscore);
        const char *lines[] = { info, "", "r   restart", "q   quit" };
        draw_panel("GAME OVER", lines, 4);
    } else if (g->paused) {
        const char *lines[] = { "p   resume", "r   restart", "q   quit" };
        draw_panel("PAUSED", lines, 3);
    }

    refresh();
}

static void setup_colors(void) {
    if (!has_colors()) return;
    start_color();
    use_default_colors();
    init_pair(1, COLOR_GREEN, -1);      /* food '$' + eat flash border */
    init_pair(2, COLOR_WHITE, -1);      /* snake */
    init_pair(3, COLOR_RED, -1);        /* wounds; hunt border (A_BOLD -> red-orange) */
    init_pair(4, COLOR_YELLOW, -1);     /* ALL-CAPS status labels + titles */
    init_pair(5, COLOR_CYAN, -1);       /* floating menu border */
}

/* coil the snake back into the board serpentine-style, preserving its
   length; used when a shrink leaves segments outside the new bounds */
static void relocate_snake(Game *g, int want_len) {
    snake_init(&g->snake);
    int cap = BOARD_W * BOARD_H;
    if (want_len > cap) want_len = cap;
    int x = 0, y = 0, dx = 1;
    for (int i = 0; i < want_len; i++) {
        Point p = { x, y };
        snake_push(&g->snake, p);
        x += dx;
        if (x < 0 || x >= BOARD_W) {
            x -= dx; dx = -dx; y++;
            if (y >= BOARD_H) break;
        }
    }
    g->dir[0] = dx; g->dir[1] = 0;
    g->pending_head = 0; g->pending_count = 0;
}

/* after a resize the board may have shrunk under the game. State is never
   reset here: hunt, wrap, pause and the snake's LENGTH survive — if the
   snake no longer fits it is relocated, not restarted. */
static void sanitize_after_resize(Game *g) {
    int oob = 0;
    for (int i = 0; i < g->snake.len; i++) {
        int idx = (g->snake.head - i + MAX_SNAKE) % MAX_SNAKE;
        Point p = g->snake.cells[idx];
        if (p.x < 0 || p.x >= BOARD_W || p.y < 0 || p.y >= BOARD_H) {
            oob = 1;
            break;
        }
    }
    if (oob) {
        int keep_len = g->snake.len;
        int keep_wrap = g->wrap, keep_hunt = g->hunt;
        int keep_paused = g->paused, keep_alive = g->alive;
        Food keep_food[MAX_FOOD];
        int keep_n = g->food_n;
        memcpy(keep_food, g->food, sizeof(keep_food[0]) * (size_t)keep_n);
        game_init(g);
        relocate_snake(g, keep_len);
        g->wrap = keep_wrap;
        g->hunt = keep_hunt;
        g->paused = keep_paused;
        g->alive = keep_alive;
        /* game_init rolled a fresh set of its own; the player's board wins,
           because resize must never reset game state — including food they
           placed by hand. */
        g->food_n = keep_n;
        memcpy(g->food, keep_food, sizeof(g->food[0]) * (size_t)keep_n);
    }
    /* A token that ended up outside the new board is re-rolled if it's one of
       the game's own, DROPPED if the player clicked it in: teleporting a token
       to somewhere nobody clicked would misreport the player's board. A placed
       token that ends up under a relocated body stays where it is — it reads as
       buried until the body moves off it. */
    int nkeep = 0;
    for (int i = 0; i < g->food_n; i++)
        if (!g->food[i].placed || in_bounds(g->food[i].p))
            g->food[nkeep++] = g->food[i];
    g->food_n = nkeep;
    /* the re-roll is a second pass on purpose: spawn_food judges candidates
       against the live prefix, so it must not run while stale duplicates from
       the compaction are still sitting in it */
    for (int i = 0; i < g->food_n; i++)
        if (!g->food[i].placed &&
            (!in_bounds(g->food[i].p) || snake_contains(&g->snake, g->food[i].p)))
            spawn_food(g, i);
    /* a board that held only clicked-in tokens, and lost every one of them to
       the shrink, would otherwise be left with nothing on it at all */
    ensure_food(g);

    /* a corpse stranded outside the shrunken board just stops bleeding out
       (a relocation wipes the whole corpse, since game_init memsets it) */
    int keep = 0;
    for (int i = 0; i < g->snake.wound_len; i++)
        if (g->snake.wound[i].ttl > 0 && in_bounds(g->snake.wound[i].p))
            g->snake.wound[keep++] = g->snake.wound[i];
    g->snake.wound_len = keep;
}

static long now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
}

/* ---- clicking inside the play field places food ---- */

/* Exactly one actionable event per physical click. main() calls mouseinterval(0),
   which switches OFF ncurses' click synthesis — otherwise a single click can
   arrive as a press AND a synthesised click for the same cell, and since this
   handler toggles, the '$' put down by the press would be lifted by the click
   that trailed it. The usual workaround is a "same cell within N ms counts once"
   timer, but that also eats a deliberate click-twice-in-one-spot, which is
   exactly what placing then un-placing looks like. So: act on the press, ignore
   everything else, keep no state. */
static void handle_click(Game *g, const MEVENT *evp) {
    MEVENT ev = *evp;
    if (!(ev.bstate & BUTTON1_PRESSED)) return;
    if (g->paused || !g->alive) return;  /* a menu is over the board: no blind edits */

    Point cell = { ev.x - CELL_LEFT, ev.y - CELL_TOP };
    if (!in_bounds(cell)) return;        /* border, header, help rows: not the board */

    int i = food_index_at(g, cell);
    if (i >= 0) {                                /* click a $ to take it back */
        remove_food(g, i);
        ensure_food(g);   /* clicking away the last one is not a way to empty
                             the board: a game token rolls back in */
        return;
    }

    if (g->food_n >= MAX_FOOD) return;           /* the pantry is full */
    if (snake_occupied(g, cell)) return;         /* not on top of the snake */

    g->food[g->food_n].p = cell;
    g->food[g->food_n].placed = 1;
    g->food_n++;
}

/* Drain the whole mouse queue per KEY_MOUSE. Input is nodelay and a mouse
   report is a multi-byte escape string, so a burst can leave more than one
   event sitting in the queue while getch hands back a single KEY_MOUSE for it.
   Reading exactly one event per KEY_MOUSE is how a click ends up acting one
   click late — the trailing getmouse calls come back ERR once the queue is
   empty, so the loop can't invent events. */
static void handle_mouse(Game *g) {
    MEVENT ev;
    while (getmouse(&ev) == OK) handle_click(g, &ev);
}

/* returns 0 to quit. Deliberately lowercase-only keys — one key, one job. */
static int handle_key(Game *g, int ch) {
    switch (ch) {
        case 'q':
            return 0;
        case 'p':
            if (g->alive) g->paused = !g->paused;
            break;
        case 'x':
            g->wrap = !g->wrap;
            break;
        case 'h':
            g->hunt = !g->hunt;
            g->pending_count = 0;
            break;
        case 'r':
            save_highscore(g->snake.len);   /* bank the run before wiping it */
            game_init(g);
            break;
        case KEY_UP:
            g->hunt = 0; queue_direction(g, 0, -1); break;
        case KEY_DOWN:
            g->hunt = 0; queue_direction(g, 0, 1); break;
        case KEY_LEFT:
            g->hunt = 0; queue_direction(g, -1, 0); break;
        case KEY_RIGHT:
            g->hunt = 0; queue_direction(g, 1, 0); break;
        case KEY_MOUSE:
            /* steering keys leave auto-hunt, a click does not: placing a token is
               telling the AI where to eat next, not taking the wheel */
            handle_mouse(g);
            break;
        case KEY_RESIZE:
            fit_board();
            sanitize_after_resize(g);
            endwin();     /* force a clean full redraw at the new size */
            refresh();
            break;
        default:
            break;
    }
    return 1;
}

int main(void) {
    srand((unsigned)time(NULL) ^ (unsigned)clock());

    initscr();
    cbreak();
    noecho();
    keypad(stdscr, TRUE);
    curs_set(0);
    nodelay(stdscr, TRUE);
    /* mouseinterval(0): never coalesce press+release into a synthesised "click".
       Button events only, deliberately NOT ALL_MOUSE_EVENTS: that mask includes
       REPORT_MOUSE_POSITION (any-motion tracking), which would pour a stream of
       motion events into the 5ms input drain for no benefit. A return of 0 means
       this terminal/terminfo offers no mouse at all — the game just plays, the
       clicks simply never arrive. */
    mouseinterval(0);
    mousemask(BUTTON1_PRESSED | BUTTON1_RELEASED, NULL);
    setup_colors();
    fit_board();

    Game g;
    game_init(&g);
    int highscore = 0;
    load_highscore(&highscore);

    /* Input is drained every POLL_MS so controls feel instant, while the
       snake only advances on its own tick clock — input latency never
       waits for a tick, and ticks never depend on key mashing. */
    #define POLL_MS 5
    long next_tick = now_ms() + tick_delay_ms(&g);
    int was_alive = 1;

    for (;;) {
        /* drain every buffered key before deciding what to do */
        int ch, input_seen = 0;
        while ((ch = getch()) != ERR) {
            input_seen = 1;
            if (!handle_key(&g, ch)) {
                save_highscore(g.snake.len);
                mousemask((mmask_t)0, NULL);  /* hand the mouse back to the terminal */
                endwin();
                printf("final length: %d\n", g.snake.len);
                return 0;
            }
        }

        long now = now_ms();
        if (now >= next_tick) {
            game_step(&g);
            if (was_alive && !g.alive) {
                save_highscore(g.snake.len);
                load_highscore(&highscore); /* keep the header honest */
            }
            was_alive = g.alive;
            next_tick = now + tick_delay_ms(&g);
            draw(&g, highscore);
        } else if (input_seen) {
            draw(&g, highscore); /* reflect pause/wrap/game-over instantly */
        }

        napms(POLL_MS);
    }
}
