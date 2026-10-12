/* tsnake — terminal snake in C + ncurses. Build: make   Run: ./snake   Quit: q.
   Full decision histories live in docs/decisions.md; the stdin/stdout codec
   contract for --protocol is in docs/protocol.md. */

#define _POSIX_C_SOURCE 200809L

#include <curses.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define MAX_SNAKE 4096
#define MIN_BOARD_W 10
#define MIN_BOARD_H 6
#define INPUT_QUEUE_SIZE 4
#define FOOD_COUNT 3      /* tokens the game starts out with */
#define MAX_FOOD 64       /* ... plus however many the player clicks in */
#define FLASH_TICKS 10    /* ticks the border stays green after eating (~0.5s) */
#define WOUND_FADE 55     /* ticks a severed cell stays red before vanishing (~3s) */

/* Speed is constant for a run: 55ms reads as a reaction, anything under 40ms
   reads as a slot machine. NEVER scale it with progress. */
#define TICK_MS 55        /* the DEFAULT only — the setup card's `speed` picks the run's tick */
#define MIN_TICK_MS 20    /* below this the BFS/pipe can't keep up honestly */
#define MAX_TICK_MS 200   /* above this it reads as a frozen game */

/* board size comes from the terminal (COLS/LINES) at startup and on SIGWINCH */
static int BOARD_W = 40;
static int BOARD_H = 20;

/* ---- what the renderer asked for (argv; see main) ----
   The overlay drives this same engine over a pipe, so what a curses terminal
   decided implicitly becomes explicit flags. */
static int protocol_mode = 0;   /* NDJSON over stdin/stdout, no curses at all */
static int square_cells = 0;    /* --square-cells: cells are square, so no 2:1
                                   aspect compensation (see stride_len_for) */
static char state_path[512];    /* --state: the best-length file, engine-owned */
static char setup_path[512];    /* --setup: the saved setup (wrap + tick_ms), engine-owned */
static int best_len;            /* the record AS IT STANDS ON DISK — frames report this one,
                                   so it never runs ahead of the file (see save_highscore) */
static int pending_best;        /* the best THIS run has reached, beaten the file or not. It
                                   is no longer how a save gets written — that happens the
                                   instant the number is beaten — it is what the terminators
                                   still have to hand to the file if they ever run
                                   (see terminate_handler) */

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
    int started;           /* 0 until the setup card's START. A run that has not
                              begun cannot be stepped, steered, or re-tuned: the
                              setup card is the only place settings are editable */
    int tick_ms;           /* THIS run's tick; TICK_MS is only its default */
} Game;

static int rng(int limit) {
    return rand() % limit;
}

/* Either the terminal's $HOME/.tsnake_highscore (cwd if HOME is unset) or whatever
   --state names — the overlay names $XDG_STATE_HOME/tsnake/highscore. NEVER name a file
   inside the watched plugins folder, and never let anything but the engine write these:
   one writer, or the record's meaning forks. Full story: docs/decisions.md. */
static const char *highscore_path(void) {
    static char path[512];
    if (state_path[0]) return state_path;
    const char *home = getenv("HOME");
    if (home && *home)
        snprintf(path, sizeof(path), "%s/.tsnake_highscore", home);
    else
        snprintf(path, sizeof(path), ".tsnake_highscore");
    return path;
}

/* The state dir can be world-writable, so a file counts as state only when lstat says
   plain regular file under 32 bytes — lstat and not stat, so a planted symlink is
   refused, never followed. Guards the read exactly as O_NOFOLLOW guards the write. */
static int state_file_trustworthy(const char *path) {
    struct stat st;
    if (lstat(path, &st) != 0) return 0;
    if (!S_ISREG(st.st_mode)) return 0;
    return st.st_size > 0 && st.st_size <= 32;
}

/* mkdir -p over the state file's parent, so --state can name a folder that
   does not exist yet. */
static int ensure_parent_dir(const char *path) {
    char dir[512];
    size_t n = 0;
    while (path[n] && n + 1 < sizeof(dir)) { dir[n] = path[n]; n++; }
    dir[n] = 0;
    char *slash = strrchr(dir, '/');
    if (!slash) return 1;                 /* a bare filename: nothing to build */
    *slash = 0;
    if (dir[0] == 0) return 1;            /* "/file" — / is already there */
    /* Step the NUL along one component at a time and mkdir each prefix. The `held == 0`
       stop is checked AFTER restoring the byte — checked before, the walk runs off the
       end of the buffer: a segfault on the first ever save, not a cosmetic bug. */
    for (char *p = dir + 1; ; p++) {
        if (*p != '/' && *p != 0) continue;
        char held = *p;
        *p = 0;
        if (mkdir(dir, 0700) != 0 && errno != EEXIST) return 0;
        *p = held;
        if (held == 0) break;
    }
    return 1;
}

/* the high score IS the best snake length ever reached */
static void load_highscore(int *best) {
    *best = 0;
    const char *path = highscore_path();
    if (!state_file_trustworthy(path)) return;
    FILE *f = fopen(path, "r");
    if (f) {
        if (fscanf(f, "%d", best) != 1) *best = 0;
        fclose(f);
    }
}

static void write_best_file(int length) {
    int best = 0;
    load_highscore(&best);
    if (length <= best) return;
    const char *path = highscore_path();
    if (!ensure_parent_dir(path)) return;
    /* O_NOFOLLOW: the state dir is world-writable; a save must never become a
       write to whatever a planted symlink points at. */
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0600);
    FILE *f = fd < 0 ? NULL : fdopen(fd, "w");
    if (f) {
        fprintf(f, "%d\n", length);
        fclose(f);
    } else if (fd >= 0) {
        close(fd);
    }
}

/* THE ONE RULE ABOUT A RECORD: it hits disk the instant it is beaten, never at
   teardown. A save that depends on being asked is not a save — banking in RAM
   until `flush` was the lost-high-score bug (docs/decisions.md). `flush`/`quit`
   and terminate_handler are redundancy, never the only way a number gets saved. */
static void save_highscore(int length) {
    /* Frames report best_len — the record AS IT STANDS ON DISK — so it rises in the
       same breath as the write; the two are the same instant. */
    if (length > pending_best) pending_best = length;
    if (length > best_len) {
        best_len = length;
        write_best_file(length);
    }
}

/* Redundancy, both faces, every exit path: normally nothing left to write — the
   write-through rule already did it. A client that asks gets a guarantee, not a hope. */
static void flush_setup(void);           /* defined with the setup card below */

static void flush_state(void) {
    if (pending_best > 0) write_best_file(pending_best);
    pending_best = 0;
    flush_setup();                       /* normally a no-op: the write-through rule already wrote */
}

/* ---- the setup card, persisted ----------------------------------------
   `wrap tick_ms`, one line, same directory and same hardening as the record. Loaded
   BEFORE START, so the card paints engine truth on frame one — QML keeps no opinion
   and needs no storage: one source of truth, the engine. Written on every accepted
   change, same write-through rule as the record. `pending_setup_ms` is -1 until
   something was set (0 is a legal tick_ms, so it can't be the sentinel) — pure
   redundancy for the terminators. */
static int pending_setup_ms = -1;        /* -1: nothing waiting; else the ms to write */
static int pending_setup_wrap;
static const char *setup_file_path(void) {
    static char path[512];
    if (setup_path[0]) return setup_path;
    const char *home = getenv("HOME");
    if (home && *home)
        snprintf(path, sizeof(path), "%s/.tsnake_setup", home);
    else
        snprintf(path, sizeof(path), ".tsnake_setup");
    return path;
}

/* Two integers, or nothing at all: junk in the file leaves the defaults standing
   rather than handing the game a frozen tick or a busy-spinning one. No `best` in
   here — one file per fact, and this is not the record's home. */
static void load_setup(int *wrap, int *tick_ms) {
    *wrap = 0;
    *tick_ms = TICK_MS;
    const char *path = setup_file_path();
    if (!state_file_trustworthy(path)) return;
    FILE *f = fopen(path, "r");
    if (!f) return;
    int w = 0, ms = 0;
    if (fscanf(f, "%d %d", &w, &ms) == 2) {
        if (w == 0 || w == 1) *wrap = w;
        if (ms >= MIN_TICK_MS && ms <= MAX_TICK_MS) *tick_ms = ms;
    }
    fclose(f);
}

static void setup_write(int wrap, int tick_ms) {
    const char *path = setup_file_path();
    if (!ensure_parent_dir(path)) return;
    /* O_NOFOLLOW: same reason as the record — never a write into a planted target. */
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0600);
    FILE *f = fd < 0 ? NULL : fdopen(fd, "w");
    if (f) {
        fprintf(f, "%d %d\n", wrap ? 1 : 0, tick_ms);
        fclose(f);
    } else if (fd >= 0) {
        close(fd);
    }
}

static void save_setup(int wrap, int tick_ms) {
    setup_write(wrap, tick_ms);            /* the instant the card changes, not when it closes */
    pending_setup_wrap = wrap;             /* a copy where a terminator can still find it */
    pending_setup_ms = tick_ms;
}

/* Re-entrant on purpose: the bank is never spent, so EVERY ask (mid-run `flush`
   included, and `quit` after a `flush`) re-writes the last accepted pair. A
   spend-once bank was the lost-high-score bug's other half — the file can be
   gone by the time the terminator asks (scratch cleanup, an erased state root),
   and a guarantee that only works the first time is not one. */
static void flush_setup(void) {
    if (pending_setup_ms < 0) return;
    setup_write(pending_setup_wrap, pending_setup_ms);
}

/* Backstop only (see save_highscore — never again the only copy). Async-signal-safe
   calls only: open/write/mkdir/close, digits laid out by hand. No stdio, no malloc,
   no load_highscore. Protocol mode only: the terminal build has no pipe to die on. */
/* best-effort parent creation, mkdir() alone: the first save of a dying process must
   still land if the directory is missing. Shared by both saved files. */
static void raw_ensure_parent(const char *path) {
    char dir[512];
    int i = 0;
    while (path[i] && i < (int)sizeof(dir) - 1) { dir[i] = path[i]; i++; }
    dir[i] = 0;
    while (i > 0 && dir[i - 1] != '/') i--;
    if (i <= 1) return;
    dir[i - 1] = 0;                                /* drop the trailing slash */
    for (int j = 1; dir[j]; j++) {
        if (dir[j] != '/') continue;
        char held = dir[j];
        dir[j] = 0;
        mkdir(dir, 0700);
        dir[j] = held;
    }
    mkdir(dir, 0700);
}

static void raw_write(const char *path, const char *text, int len) {
    if (!path || !path[0] || len <= 0) return;
    raw_ensure_parent(path);
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0600);
    if (fd < 0) return;
    ssize_t wrote = write(fd, text, (size_t)len);
    (void)wrote;
    close(fd);
}

/* digits laid out by hand — printf/sprintf are not async-signal-safe */
static int raw_int(char *out, int v) {
    char digits[16];
    int n = 0, m = 0;
    if (v < 0) { out[m++] = '-'; v = -v; }
    do { digits[n++] = (char)('0' + v % 10); v /= 10; } while (v > 0);
    while (n > 0) out[m++] = digits[--n];
    return m;
}

static void terminate_handler(int sig) {
    (void)sig;
    int v = best_len;
    if (pending_best > v) v = pending_best;
    if (v > 0) {
        char buf[24];
        int m = raw_int(buf, v);
        buf[m++] = '\n';
        raw_write(highscore_path(), buf, m);
    }
    /* The card's two answers get the same treatment as the record: a panel the
       shell tore down must not come back forgetting the wall and the dial. By
       arrival they are already on disk — this is the second copy, not the first. */
    if (pending_setup_ms >= 0) {
        char buf[24];
        int m = raw_int(buf, pending_setup_wrap);
        buf[m++] = ' ';
        m += raw_int(buf + m, pending_setup_ms);
        buf[m++] = '\n';
        raw_write(setup_file_path(), buf, m);
    }
    _exit(0);
}

static void snake_init(Snake *s) {
    s->head = 0;
    s->len = 0;
    s->wound_len = 0;
}

/* Ring head + live length, counted in ring cells BEHIND the head; the body never
   rewrites its own cells, so a step reads back straight down the ring. */
static void snake_push(Snake *s, Point p) {
    s->head = (s->head + 1) % MAX_SNAKE;
    s->cells[s->head] = p;
    if (s->len < MAX_SNAKE) s->len++;
}

/* a normal step: the tail tip keeps up with the head */
static void snake_pop_tail(Snake *s) {
    if (s->len > 0) s->len--;
}

/* Chain depth: 0 is the head, len-1 the tail tip. -1 = not live body — which
   includes every cell the body ever shed: the ring no longer holds those. */
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

/* Sever the bitten cell and everything toward the tail tip (len = depth). The
   positions are copied OUT of the ring first — see WoundCell. */
static void snake_bite(Snake *s, int depth) {
    if (depth < 0 || depth >= s->len) return;
    int n = s->len - depth;
    if (n > MAX_SNAKE - s->wound_len) n = MAX_SNAKE - s->wound_len;
    if (n <= 0) return;
    for (int i = 0; i < n; i++) {
        int idx = (s->head - (depth + i) + MAX_SNAKE * 2) % MAX_SNAKE;
        s->wound[s->wound_len].p = s->cells[idx];
        /* Staggered ttl: the bitten cell dies first, the tail tip last, and the
           whole spread stays inside WOUND_FADE. */
        s->wound[s->wound_len].ttl =
            WOUND_FADE / 2 + (WOUND_FADE / 2) * i / (n > 1 ? n - 1 : 1);
        s->wound_len++;
    }
    s->len = depth;
}

/* One tick of bleeding. The queue drains from the front (the oldest bite); a cell
   expiring mid-queue is harmless — every reader checks ttl before trusting a cell. */
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

/* Is a DIFFERENT token on p? Slot i's own cell does not count — it is the one
   being re-rolled. Test THIS, never `food_index_at(...) != i`: an empty cell reads
   -1, which is != i, so that check rejects every legal cell. */
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
    /* Re-roll until clear of the snake and of every other token. A naive
       `food_index_at != i` test rejects EVERY legal cell (empty reads -1) and only
       escapes by re-rolling under the head — an endless loop that reads as a
       frozen game. The 1000-roll cap is for the same reason: a packed board has no
       legal cell, and a bounded spin beats a frozen terminal. */
    for (int guard = 0; guard < 1000; guard++) {
        g->food[i].p.x = rng(BOARD_W);
        g->food[i].p.y = rng(BOARD_H);
        /* `placed` rides along: this moves where a token sits, never what kind it
           is — so a respawn can never stack on one the player clicked in. */
        if (!snake_occupied(g, g->food[i].p) && !other_token_at(g, g->food[i].p, i))
            return;
    }
}

/* THE BOARD IS NEVER EMPTY OF TOKENS. Food is the only way to grow, and the hunt
   AI's whole plan is a distance field seeded FROM the tokens — an empty board is a
   dead game twice over. Every token-removing path (click-remove, eat-the-last,
   shrink-drop) calls this right after, and what comes back is a GAME token
   (placed = 0), so it respawns in turn. */
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
    /* A game is startable the moment it exists — EXCEPT under --protocol, where
       protocol_run() drops started to 0 so the setup card gets its frame. */
    g->started = 1;
    g->tick_ms = TICK_MS;

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

/* One cell forward; game_step calls it once per stride cell (see stride_len_for),
   each landing checked on its own. Wrap makes the seam a tunnel; otherwise a wall is
   the ONLY killer. A body landing is a bite, not a death — EXCEPT the vacating
   tail-tip (depth len-1) and any shed cell, which are legal landings (see
   snake_chain_depth). */
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

/* Guard rails for the BFS scratch arrays. Beyond these the AI declines to plan
   and the snake steers straight, so they must cover any terminal a person can
   actually open — a maximized window on a wide monitor passes 200 cols easily. */
#define MAX_BOARD_W 400
#define MAX_BOARD_H 250

/* Occupancy grid for hunt mode, O(1) per cell: live body + unexpired corpses
   (a corpse is a wall until it fades). Walks the live prefix, never the ring,
   and hunt mode calls it every tick. */
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

/* Where one step from p along d lands — and IT WRAPS, exactly like advance_one.
   Every step the AI reasons about (BFS included) goes through here: if the two
   topologies ever disagree the AI starves on a board the snake could cross. */
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

/* Cells covered per tick: terminal cells are ~2x taller than wide, so a
   horizontal move takes TWO cells to match vertical speed; --square-cells makes
   every stride one. THE single place that number is decided — game_step and
   hunt_stride_free must agree or the AI plans a different stride than it drives. */
static int stride_len_for(const Game *g, int dx, int dy) {
    (void)g;
    if (square_cells) return 1;
    if (dy != 0) return 1;         /* vertical: one tall cell is already enough */
    (void)dx;
    return 2;                      /* horizontal in a terminal: two cells */
}

/* The WHOLE stride, every cell of it, or the answer is not "free": a direction
   whose second cell is taken only postpones the crash by a tick. `first` (may be
   NULL) gets the near cell — where the distance field is read. */
static int hunt_stride_free(Game *g, Point from, int dx, int dy, Point *first) {
    Point c;
    if (!hunt_next_cell(g, from, dx, dy, &c)) return 0;
    Point near = c;                        /* the cell the distance field is read at */
    if (snake_occupied(g, near)) return 0;
    for (int k = 1; k < stride_len_for(g, dx, dy); k++) {
        if (!hunt_next_cell(g, c, dx, dy, &c)) return 0;
        if (snake_occupied(g, c)) return 0;
    }
    if (first) *first = near;
    return 1;
}

/* Best direction toward the nearest food; 0 means "keep going straight". */
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

    /* Seed the queue with every token: BFS then yields distance-to-nearest-token. */
    int qh = 0, qt = 0;
    for (int i = 0; i < g->food_n; i++) {
        Point f = g->food[i].p;
        if (f.x < 0 || f.x >= w || f.y < 0 || f.y >= h) continue;
        if (dist[f.y][f.x] == 0) continue;      /* duplicate token */
        dist[f.y][f.x] = 0;
        qx[qt] = f.x; qy[qt] = f.y; qt++;
    }

    /* The wave spreads through hunt_next_cell, so in wrap mode the wave crosses
       the seam exactly like the snake does. Clipping the wave at the board edges
       instead — a plane for the planner, a torus for the driver — is what ended
       auto-hunt once: an edge-to-edge body wall seals the wave in the PLANE while
       the real board stays open, every neighbour reads dist -1, and the snake
       marches straight forever. */
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

    /* Nothing reachable: stay alive and mobile instead of starving in place.
       Straight counts ONLY as a whole free stride — checking one cell makes
       "legal" a lie for horizontal moves (see hunt_stride_free). */
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

    if (g->paused || !g->alive || !g->started) return;
    if (g->flash > 0) g->flash--;

    /* Corpses stay solid until their countdown expires (see wound_tick). */
    wound_tick(s);

    if (g->hunt) {
        int d[2];
        /* hunt_step returning 0 means "keep going straight" */
        if (hunt_step(g, d)) { g->dir[0] = d[0]; g->dir[1] = d[1]; }
        g->pending_count = 0;
    }

    if (g->pending_count > 0) {
        /* A lean onto the snake's own body is a bite, not a death (advance_one). */
        g->dir[0] = g->pending[g->pending_head][0];
        g->dir[1] = g->pending[g->pending_head][1];
        g->pending_head = (g->pending_head + 1) % INPUT_QUEUE_SIZE;
        g->pending_count--;
    }

    /* Each stride cell lands and is checked on its own; stride_len_for is shared
       with the AI's legality check so planner and driver cannot drift. */
    int steps = stride_len_for(g, g->dir[0], g->dir[1]);
    for (int k = 0; k < steps && g->alive; k++) advance_one(g);
}

/* The run's tick, chosen on the card and frozen for the run — never length-scaled. */
static int tick_delay_ms(const Game *g) {
    return g->tick_ms;
}

/* Floating centered menu for pause / game-over: blanks its rect (erasing the
   board UNDER it is safe — state is untouched) and paints a titled box. */
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

    /* Border colour priority: a fresh eat flashes green, else armed hunt burns
       red-orange. */
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

    /* Under ONE if, never an early return: the help row, both panels and the
       trailing refresh() live below — an early return renders no menu and
       flushes nothing (the screen just freezes). */
    if (!g->paused && g->alive) {
        /* cells sit at CELL_TOP/CELL_LEFT — the same pair the click handler
           subtracts; change one, change both. */
        if (has_colors()) attron(COLOR_PAIR(1));
        for (int i = 0; i < g->food_n; i++)
            mvaddch(CELL_TOP + g->food[i].p.y, CELL_LEFT + g->food[i].p.x, '$');
        if (has_colors()) attroff(COLOR_PAIR(1));

        /* Corpses draw under the live body (a head in its own scar reads as a
           head) and dim over their last third. */
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
        /* Its own row: the right-aligned status labels on the key row would be
           overrun by a longer left-hand string. */
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

/* Coil the snake serpentine-style from (0,0) into the shrunken board, keeping its
   length — used when a resize leaves segments outside the new bounds. */
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

/* A resize is a MOVE, never a new run: hunt, wrap, paused, started, tick_ms and
   length all survive a shrink; a snake too long to fit is relocated, not reset. */
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
        /* game_init resets started/tick_ms; a resize is NOT a new run. The
           overlay's first act is a {"cmd":"size"} — without this carry, the
           oob branch silently pressed START at the default speed and the card
           was gone in one frame. */
        int keep_started = g->started, keep_ms = g->tick_ms;
        Food keep_food[MAX_FOOD];
        int keep_n = g->food_n;
        memcpy(keep_food, g->food, sizeof(keep_food[0]) * (size_t)keep_n);
        game_init(g);
        relocate_snake(g, keep_len);
        g->wrap = keep_wrap;
        g->hunt = keep_hunt;
        g->paused = keep_paused;
        g->alive = keep_alive;
        g->started = keep_started;
        g->tick_ms = keep_ms;
        /* The player's food wins over game_init's fresh roll — resize is not a reset. */
        g->food_n = keep_n;
        memcpy(g->food, keep_food, sizeof(g->food[0]) * (size_t)keep_n);
    }
    /* Off-board tokens: the game's own re-roll, the player's are DROPPED (a
       teleport to where nobody clicked misreports their board). */
    int nkeep = 0;
    for (int i = 0; i < g->food_n; i++)
        if (!g->food[i].placed || in_bounds(g->food[i].p))
            g->food[nkeep++] = g->food[i];
    g->food_n = nkeep;
    /* The re-roll is a SECOND pass on purpose: spawn_food judges candidates against
       the live prefix, which the compaction above has to finish first. */
    for (int i = 0; i < g->food_n; i++)
        if (!g->food[i].placed &&
            (!in_bounds(g->food[i].p) || snake_contains(&g->snake, g->food[i].p)))
            spawn_food(g, i);
    /* A shrink that dropped every token would leave an empty board (see ensure_food). */
    ensure_food(g);

    /* A corpse stranded off the new board simply stops bleeding out. */
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

/* ONE actionable event per physical click: mouseinterval(0) kills ncurses' click
   synthesis, so a press is never doubled by a synthesised click — the handler
   toggles, and a double-fire un-places what it placed. (No "same cell within N
   ms" timer either: it eats a deliberate click-then-un-click.)
   Toggle the token on a BOARD cell; both front-ends come HERE, so the never-empty
   board cannot be sidestepped by whichever renderer holds the mouse. */
static void place_or_remove(Game *g, Point cell) {
    if (g->paused || !g->alive) return;  /* a menu is over the board: no blind edits */
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

static void handle_click(Game *g, const MEVENT *evp) {
    MEVENT ev = *evp;
    if (!(ev.bstate & BUTTON1_PRESSED)) return;

    /* Screen coords through the SAME pair draw() writes with — pointing and
       painting cannot drift apart. */
    place_or_remove(g, (Point){ ev.x - CELL_LEFT, ev.y - CELL_TOP });
}

/* Drain the WHOLE mouse queue per KEY_MOUSE: under nodelay a burst queues
   several reports, and reading one per KEY_MOUSE makes a click act one late.
   Trailing getmouse returns ERR on an empty queue, so the loop cannot invent. */
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
            save_setup(g->wrap, g->tick_ms);   /* the terminal's own card: it persists too */
            break;
        case 'h':
            g->hunt = !g->hunt;
            g->pending_count = 0;
            break;
        case 'r':
            save_highscore(g->snake.len);   /* the run's number is on disk before the board is wiped */
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

/* ---- the overlay's engine: NDJSON over stdin/stdout, no curses ----
 * `snake --protocol` is the same game with a different face — one source of
 * truth for the rules, no second implementation to drift. QML NEVER drives the
 * clock (a stutter would read as lag); the engine ticks on its own monotonic
 * clock and polls stdin, so input lands between ticks.
 * Full grammar and frame shapes: docs/protocol.md. */

/* Flat-object JSON, read without a library: locate "key", read past the colon.
   Deliberately forgiving — an unparseable key or an unknown cmd is not a command,
   never an error: a half-written line from the shell must never hang the game.
   Grammar and frame shapes: docs/protocol.md. */
static int json_string(const char *s, const char *key, char *out, size_t outsz) {
    char needle[40];
    snprintf(needle, sizeof(needle), "\"%s\"", key);
    const char *v = strstr(s, needle);
    if (!v) return 0;
    v += strlen(needle);
    while (*v == ' ' || *v == '\t') v++;
    if (*v != ':') return 0;
    v++;
    while (*v == ' ' || *v == '\t') v++;
    if (*v != '"') return 0;
    v++;
    size_t n = 0;
    while (*v && *v != '"' && n + 1 < outsz) out[n++] = *v++;
    out[n] = 0;
    return n > 0;
}

static int json_int(const char *s, const char *key, int *out) {
    char needle[40];
    snprintf(needle, sizeof(needle), "\"%s\"", key);
    const char *v = strstr(s, needle);
    if (!v) return 0;
    v += strlen(needle);
    while (*v == ' ' || *v == '\t') v++;
    if (*v != ':') return 0;
    v++;
    while (*v == ' ' || *v == '\t') v++;
    char *end = NULL;
    long n = strtol(v, &end, 10);
    if (end == v) return 0;
    *out = (int)n;
    return 1;
}

/* One frame = the WHOLE board, never a diff: a dropped frame is a skipped paint,
   never a lost state. Returns 0 when the reader has gone — the loop treats that
   as death, because an engine emitting into a closed pipe would run invisibly
   for the rest of the session. */
static int emit_frame(const Game *g, long tick) {
    Point head = g->snake.cells[g->snake.head];
    printf("{\"event\":\"frame\",\"tick\":%ld,\"w\":%d,\"h\":%d,"
           "\"alive\":%d,\"paused\":%d,\"wrap\":%d,\"hunt\":%d,"
           "\"started\":%d,\"speed\":%d,"
           "\"flash\":%d,\"len\":%d,\"best\":%d,"
           "\"dir\":[%d,%d],\"head\":{\"x\":%d,\"y\":%d},\"body\":[",
           tick, BOARD_W, BOARD_H, g->alive, g->paused, g->wrap, g->hunt,
           g->started, g->tick_ms,
           g->flash, g->snake.len, best_len, g->dir[0], g->dir[1], head.x, head.y);

    for (int i = 0; i < g->snake.len; i++) {
        int idx = (g->snake.head - i + MAX_SNAKE * 2) % MAX_SNAKE;
        printf("%s{\"x\":%d,\"y\":%d}", i ? "," : "",
               g->snake.cells[idx].x, g->snake.cells[idx].y);
    }

    printf("],\"wound\":[");
    int n = 0;
    for (int i = 0; i < g->snake.wound_len; i++) {
        if (g->snake.wound[i].ttl <= 0) continue;
        printf("%s{\"x\":%d,\"y\":%d,\"ttl\":%d}", n++ ? "," : "",
               g->snake.wound[i].p.x, g->snake.wound[i].p.y, g->snake.wound[i].ttl);
    }

    printf("],\"food\":[");
    for (int i = 0; i < g->food_n; i++)
        printf("%s{\"x\":%d,\"y\":%d,\"placed\":%d}", i ? "," : "",
               g->food[i].p.x, g->food[i].p.y, g->food[i].placed);

    printf("]}\n");
    if (fflush(stdout) != 0 || ferror(stdout)) return 0;
    return 1;
}

/* One command from the overlay; returns 0 when the engine should stop. Every
   branch mirrors the terminal's key handler — one game, two faces. */
static int handle_command(Game *g, const char *line) {
    char cmd[32];
    if (!json_string(line, "cmd", cmd, sizeof(cmd))) return 1;

    if (strcmp(cmd, "dir") == 0) {
        if (!g->started) return 1;               /* before START, nothing steers */
        int dx = 0, dy = 0;
        if (!json_int(line, "dx", &dx) || !json_int(line, "dy", &dy)) return 1;
        int axis_ok = (dy == 0 && (dx == 1 || dx == -1)) ||
                      (dx == 0 && (dy == 1 || dy == -1));
        if (!axis_ok) return 1;                  /* diagonals and zeros are nothing */
        g->hunt = 0;                             /* steering takes the wheel */
        queue_direction(g, dx, dy);              /* reversal/no-op filtering stays here */
        return 1;
    }
    if (strcmp(cmd, "click") == 0) {
        int x = 0, y = 0;
        if (!json_int(line, "x", &x) || !json_int(line, "y", &y)) return 1;
        /* BOARD coordinates: the overlay's grid has no border ring to subtract,
           and unlike `dir` a click does NOT cancel hunt — placing a token is
           telling the AI where to eat next, not taking the wheel. */
        place_or_remove(g, (Point){ x, y });
        return 1;
    }
    if (strcmp(cmd, "pause") == 0) {
        if (g->started && g->alive) g->paused = !g->paused;
        return 1;
    }
    /* wrap/speed are CARD-ONLY: refused once the run began (g->started), and the
       `on` form is absolute while bare `wrap` toggles. */
    if (strcmp(cmd, "wrap") == 0) {
        if (g->started) return 1;
        int on = -1;
        if (json_int(line, "on", &on) && (on == 0 || on == 1)) g->wrap = on;
        else g->wrap = !g->wrap;
        save_setup(g->wrap, g->tick_ms);         /* the card remembers it for next time */
        return 1;
    }
    if (strcmp(cmd, "speed") == 0) {
        if (g->started) return 1;                /* in-game: the speed is decided */
        int ms = 0;
        if (!json_int(line, "ms", &ms)) return 1;
        /* The clamp lives HERE, not in the UI, and the CLAMPED value is what gets
           saved — no client can poison tomorrow's card through today's pipe. */
        if (ms < MIN_TICK_MS) ms = MIN_TICK_MS;
        if (ms > MAX_TICK_MS) ms = MAX_TICK_MS;
        g->tick_ms = ms;
        save_setup(g->wrap, g->tick_ms);
        return 1;
    }
    if (strcmp(cmd, "start") == 0) {
        g->started = 1;
        g->paused = 0;                           /* START means go, never "go paused" */
        g->pending_count = 0;                    /* no lean queued before the run began */
        return 1;
    }
    if (strcmp(cmd, "hunt") == 0) {
        if (!g->started) return 1;
        g->hunt = !g->hunt;
        g->pending_count = 0;
        return 1;
    }
    if (strcmp(cmd, "restart") == 0) {
        save_highscore(g->snake.len);            /* the run's number goes to the file first —
                                                    an instant replay must not eat the record */
        /* game_init memsets the whole Game, so the setup has to be carried across on
           purpose: a restart replays under the wrap and speed the player chose, and
           a restart while still on the setup card stays on the setup card. */
        int keep_started = g->started, keep_wrap = g->wrap, keep_ms = g->tick_ms;
        game_init(g);
        g->started = keep_started;
        g->wrap = keep_wrap;
        g->tick_ms = keep_ms;
        return 1;
    }
    if (strcmp(cmd, "size") == 0) {
        int w = 0, h = 0;
        if (!json_int(line, "w", &w) || !json_int(line, "h", &h)) return 1;
        if (w < MIN_BOARD_W) w = MIN_BOARD_W;
        if (h < MIN_BOARD_H) h = MIN_BOARD_H;
        /* the BFS caps are also the protocol cap: past them hunt_step declines to
           plan at all, so a board bigger than this would look like a broken AI */
        if (w > MAX_BOARD_W) w = MAX_BOARD_W;
        if (h > MAX_BOARD_H) h = MAX_BOARD_H;
        BOARD_W = w;
        BOARD_H = h;
        sanitize_after_resize(g);                /* shrinks preserve state, never reset */
        return 1;
    }
    if (strcmp(cmd, "flush") == 0) {
        save_highscore(g->snake.len);
        /* A guarantee, not a necessity: the write-through rule already banked the
           number when it changed. Mid-run `flush` is legal for the same reason. */
        flush_state();
        return 1;
    }
    if (strcmp(cmd, "quit") == 0) {
        save_highscore(g->snake.len);
        flush_state();
        return 0;
    }
    return 1;                                    /* unknown: ignore it, keep playing */
}

static int protocol_run(void) {
    /* A closed pipe must reach us as a write error, not as a mid-frame SIGPIPE. */
    signal(SIGPIPE, SIG_IGN);
    /* Redundancy for the endings that never ask (see save_highscore's one rule). */
    signal(SIGTERM, terminate_handler);
    signal(SIGHUP, terminate_handler);
    signal(SIGINT, terminate_handler);
    setvbuf(stdout, NULL, _IOLBF, 0);
    Game g;
    game_init(&g);
    /* THE GATE: nothing moves and nothing steers until `start` lands; the frames
       keep flowing so the card paints from real state. */
    g.started = 0;
    load_highscore(&best_len);
    /* The card comes back as the player left it. Loaded here, BEFORE the tick clock is
       armed a few lines below, so the very first frame already carries the saved wrap
       and speed and the card never has to paint a hope of its own. */
    load_setup(&g.wrap, &g.tick_ms);

    char line[256];
    size_t line_len = 0;
    long tick_no = 0;
    int dirty = 1;                    /* emit the opening frame before the first tick */
    long next_tick = now_ms() + tick_delay_ms(&g);

    for (;;) {
        struct pollfd pfd = { .fd = STDIN_FILENO, .events = POLLIN, .revents = 0 };
        long now = now_ms();
        int wait = (int)(next_tick - now);
        if (wait < 0) wait = 0;
        if (wait > 20) wait = 20;     /* short cap: input stays instant between ticks */
        if (poll(&pfd, 1, wait) > 0) {
            char buf[1024];
            ssize_t n = read(STDIN_FILENO, buf, sizeof(buf));
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) {              /* the overlay is gone (pipe closed): prove both files
                                          current and go, or a shell reload leaves a process
                                          grinding BFS invisibly for the rest of the session */
                flush_state();
                return 0;
            }
            for (ssize_t i = 0; i < n; i++) {
                if (buf[i] != '\n') {
                    /* commands are short; an over-long line is dropped whole, which
                       is the same "ignore it and keep playing" as an unknown cmd */
                    if (line_len + 1 < sizeof(line)) line[line_len++] = buf[i];
                    continue;
                }
                line[line_len] = 0;
                line_len = 0;
                if (!handle_command(&g, line)) { flush_state(); return 0; }
                dirty = 1;             /* reflect pause/wrap/hunt/placement at once */
            }
        }

        now = now_ms();
        if (now >= next_tick) {
            game_step(&g);
            save_highscore(g.snake.len);   /* cheap unless this tick beat the record, which writes */
            tick_no++;
            next_tick = now + tick_delay_ms(&g);
            dirty = 1;
        }
        if (dirty) {
            if (!emit_frame(&g, tick_no)) { flush_state(); return 0; }
            dirty = 0;
        }
    }
}

int main(int argc, char **argv) {
    srand((unsigned)time(NULL) ^ (unsigned)clock());

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--protocol") == 0) { protocol_mode = 1; continue; }
        if (strcmp(argv[i], "--square-cells") == 0) { square_cells = 1; continue; }
        if (strcmp(argv[i], "--state") == 0 && i + 1 < argc) {
            snprintf(state_path, sizeof(state_path), "%s", argv[++i]);
            continue;
        }
        if (strcmp(argv[i], "--setup") == 0 && i + 1 < argc) {
            snprintf(setup_path, sizeof(setup_path), "%s", argv[++i]);
            continue;
        }
        if (strcmp(argv[i], "--size") == 0 && i + 1 < argc) {
            int w = 0, h = 0;
            if (sscanf(argv[++i], "%dx%d", &w, &h) == 2 &&
                w >= MIN_BOARD_W && h >= MIN_BOARD_H) {
                /* the terminal build recomputes this from COLS/LINES anyway; the
                   overlay owns its own grid and is the only caller that cares */
                BOARD_W = w > MAX_BOARD_W ? MAX_BOARD_W : w;
                BOARD_H = h > MAX_BOARD_H ? MAX_BOARD_H : h;
            }
            continue;
        }
        fprintf(stderr,
                "usage: snake                     play in the terminal\n"
                "       snake --protocol [--state PATH] [--setup PATH]\n"
                "                        [--square-cells] [--size WxH]\n"
                "                               speak NDJSON to the Omarchy overlay\n");
        return 2;
    }

    if (protocol_mode) return protocol_run();

    initscr();
    cbreak();
    noecho();
    keypad(stdscr, TRUE);
    curs_set(0);
    nodelay(stdscr, TRUE);
    /* Button events only, deliberately NOT ALL_MOUSE_EVENTS: that mask adds
       motion tracking, a stream of events into the 5ms drain for no benefit. */
    mouseinterval(0);
    mousemask(BUTTON1_PRESSED | BUTTON1_RELEASED, NULL);
    setup_colors();
    fit_board();

    Game g;
    game_init(&g);
    int highscore = 0;
    load_highscore(&highscore);
    /* The terminal has no card, but `x` and the default tick honour the same file. */
    load_setup(&g.wrap, &g.tick_ms);

    /* Input drains every POLL_MS; the snake moves on its own tick clock — input
       never waits for a tick. */
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
