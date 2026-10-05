/*
 * Unit tests for tsnake's game logic.
 *
 * Same harness as test_hunt.c: pull snake.c in with its main() renamed out of
 * the way, so the tests reach the file-scope globals and the static functions
 * directly, and drive the structs with no terminal anywhere in sight.
 *
 * NOTHING here looks at the screen. There is no draw(), no draw_panel(), no
 * head_glyph(), no handle_key()/handle_mouse(), no fit_board() — the last
 * session that tried to grade a curses screen by asserting on rendered bytes
 * produced nothing but false failures (it swallowed charset designators as
 * text, ignored the insert/delete sequences curses refreshes a line with so
 * cleared cells read as ghost tokens, and "resized" a pty in a way that pins
 * ncurses' idea of the size so nothing resizes). The rule now is to assert on
 * the game's own state; what it looks like stays with human verification.
 * The one exception is the --protocol codec, which is text in / text out and is
 * graded as a text format, not as a screen.
 *
 * Build: make test_game     Run: ./test_game   (or: make unit)
 */

#define _POSIX_C_SOURCE 200809L

#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define main snake_unused_main
#include "snake.c"
#undef main

/* ------------------------------------------------------------------ *
 * a rig that keeps going: one run reports every failure, not just the first
 * ------------------------------------------------------------------ */

static long checks_run, checks_failed, suite_failed;

#define CHECK(cond)                                                        \
    do {                                                                   \
        checks_run++;                                                      \
        if (!(cond)) {                                                     \
            checks_failed++; suite_failed++;                               \
            printf("  FAIL %s:%d  CHECK(%s)\n", __FILE__, __LINE__, #cond); \
        }                                                                  \
    } while (0)

#define CHECK_EQ(actual, expected)                                          \
    do {                                                                     \
        long _a = (long) (actual), _e = (long) (expected);                   \
        checks_run++;                                                        \
        if (_a != _e) {                                                      \
            checks_failed++; suite_failed++;                                 \
            printf("  FAIL %s:%d  %s == %s  (actual %ld, expected %ld)\n",   \
                   __FILE__, __LINE__, #actual, #expected, _a, _e);          \
        }                                                                    \
    } while (0)

#define CHECK_STR(actual, expected)                                          \
    do {                                                                     \
        const char *_a = (actual), *_e = (expected);                          \
        checks_run++;                                                        \
        if (strcmp(_a, _e) != 0) {                                            \
            checks_failed++; suite_failed++;                                  \
            printf("  FAIL %s:%d  %s == %s  (actual \"%s\", expected \"%s\")\n", \
                   __FILE__, __LINE__, #actual, #expected, _a, _e);           \
        }                                                                     \
    } while (0)

/* Does `hay` hold `needle`? Used only for whole-substring checks on the frame
   text, where strstr says exactly what we mean. */
static int holds(const char *hay, const char *needle) {
    return hay && strstr(hay, needle) != NULL;
}

static void run_suite(const char *name, void (*fn)(void)) {
    long before = checks_failed;
    suite_failed = 0;
    printf("\n== %s\n", name);
    fn();
    printf("   %s\n", checks_failed == before ? "ok" : "FAILED");
}

/* ------------------------------------------------------------------ *
 * the world each test starts in
 * ------------------------------------------------------------------ */

/* Every scratch file a test creates, so main() can wipe them all on the way
   out — a test suite that litters /tmp is a suite people delete. */
static char run_dir[256];
static char *scratch[64];
static int scratch_n;

static void keep_scratch(const char *p) {
    if (scratch_n < (int) (sizeof scratch / sizeof scratch[0]))
        scratch[scratch_n++] = strdup(p);
}

/* Every call gets ITS OWN string. Callers hold these across later calls — the
   symlink rig keeps `victim` alive while it asks for `link` — so a shared
   static buffer would quietly rewrite the first name under the second: both
   pointers end up reading the last leaf, the symlink is planted on itself, and
   the victim file "disappears" from under the reader that is checking it was
   never clobbered. The precisions are what keep -Wformat-truncation quiet:
   run_dir is a fixed array and every leaf here is short, so the result always
   fits. */
static char *scratch_path(const char *leaf) {
    char path[1024];
    snprintf(path, sizeof path, "%.300s/%.300s", run_dir, leaf);
    char *own = strdup(path);
    if (!own) { fprintf(stderr, "scratch_path: out of memory\n"); exit(1); }
    keep_scratch(own);                          /* the cleanup list keeps a copy */
    return own;
}

/* Remove run_dir for good. The unlink loop in main() can only retire the
   leaves a test registered with keep_scratch(), and that is not everything the
   run creates: flush_state()/write_best_file() mkdir -p their own parent chain,
   so `nested/deeper` and `made/by/ensure` exist once the save-data suite has
   run, and the highscore files the engine writes were never registered (the
   rig unlinks that name BEFORE creating it, to prove it starts absent). So
   rmdir(run_dir) always failed and every single run left a
   /tmp/tsnake_unit_<pid> behind — precisely the litter this file promises not
   to make. lstat, never stat: a planted symlink must be unlinked as the link it
   is, not followed into somebody else's tree. Depth-bounded, and main() calls
   it only on a path this binary built under /tmp. */
static void wipe_dir(const char *path, int depth) {
    if (depth < 0) return;
    DIR *d = opendir(path);
    if (!d) return;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        char child[1024];
        snprintf(child, sizeof child, "%.500s/%.400s", path, e->d_name);
        struct stat st;
        if (lstat(child, &st) == 0 && S_ISDIR(st.st_mode)) wipe_dir(child, depth - 1);
        else unlink(child);
    }
    closedir(d);
    rmdir(path);
}

/* The rules read file-scope globals — BOARD_W/BOARD_H, square_cells,
 * protocol_mode, state_path and the two banked-best ints — that a previous
 * test could have left in any state at all, so every test resets them and
 * nothing inherits anything.
 * state_path always points inside our scratch dir: no test may ever be able to
 * touch the real $HOME/.tsnake_highscore, not even by accident. */
static void world_reset(int w, int h) {
    srand(20261002u);          /* one fixed seed: a passing run is reproducible */
    BOARD_W = w;
    BOARD_H = h;
    square_cells = 0;
    protocol_mode = 0;
    best_len = 0;
    pending_best = 0;
    memset(state_path, 0, sizeof state_path);
    snprintf(state_path, sizeof state_path, "%s/highscore", run_dir);
    unlink(state_path);
}

/* A game with no randomness in it at all: food and body are placed by hand, so
 * "the board says exactly what the test thinks it says". */
static void blank_game(Game *g) {
    memset(g, 0, sizeof *g);
    g->alive = 1;
    g->dir[0] = 1;
    g->dir[1] = 0;
    /* A blank game is a run IN PROGRESS, which is what every test here means.
       started == 0 is the setup card's state — the run has not been given away yet,
       and game_step refuses to advance it — so the rig that stands for "playing"
       must set it, exactly as game_init does. Only the setup-gate tests drop it back
       to 0, and they do that on purpose. */
    g->started = 1;
    g->tick_ms = TICK_MS;
}

/* Lay the live body out exactly as given: tail first, head LAST (snake_push is
 * push-at-tail, so the last cell pushed is the head). Write the literal in that
 * order — {tail, ..., head} — or the rig runs backwards from the one the test
 * thinks it built.
 * snake_init() also zeroes wound_len, so a second set_body DELETES any corpse
 * already in the queue; use set_body_keeping_wounds when the corpse is the
 * subject of the test. */
static void set_body(Game *g, const Point *pts, int n) {
    snake_init(&g->snake);
    for (int i = 0; i < n; i++) snake_push(&g->snake, pts[i]);
}

/* Same layout, same tail-first/head-last order, but the severed queue is left
 * exactly as it was: this is the rig for "a second bite behind a live one",
 * where wiping the corpse would delete the thing being asserted about. Only
 * head/len are reset, which is all snake_push needs to start a fresh body. */
static void set_body_keeping_wounds(Game *g, const Point *pts, int n) {
    g->snake.head = 0;
    g->snake.len = 0;
    for (int i = 0; i < n; i++) snake_push(&g->snake, pts[i]);
}

/* The token array exactly as given, placed flags included. */
static void set_tokens(Game *g, const Point *pts, const int *placed, int n) {
    for (int i = 0; i < n; i++) {
        g->food[i].p = pts[i];
        g->food[i].placed = placed ? placed[i] : 0;
    }
    g->food_n = n;
}

/* tokens parked well clear of the top-left corner where most rigs live */
static void tokens_far(Game *g) {
    Point f[3];
    f[0].x = BOARD_W - 1; f[0].y = BOARD_H - 1;
    f[1].x = BOARD_W - 2; f[1].y = BOARD_H - 1;
    f[2].x = BOARD_W - 1; f[2].y = BOARD_H - 2;
    set_tokens(g, f, NULL, 3);
}

static int file_exists(const char *p) {
    struct stat st;
    return lstat(p, &st) == 0;
}

static int read_file(const char *path, char *buf, size_t bufsz) {
    FILE *f = fopen(path, "r");
    if (!f) { buf[0] = 0; return 0; }
    size_t n = fread(buf, 1, bufsz - 1, f);
    buf[n] = 0;
    fclose(f);
    return 1;
}

/* ------------------------------------------------------------------ *
 * 1. only a wall kills
 * ------------------------------------------------------------------ */

/* The founding rule of this build: walls are lethal, yourself is not. If these
 * flip, every other mechanic here (wounds, severing, the hunt AI's willingness
 * to cut itself loose) stops meaning anything. */
static void test_only_walls_kill(void) {
    world_reset(10, 6);
    Game g;

    /* head on the last column, walking into it */
    blank_game(&g);
    Point hrow[] = {{7, 2}, {8, 2}, {9, 2}};
    set_body(&g, hrow, 3);
    g.dir[0] = 1; g.dir[1] = 0; g.wrap = 0;
    tokens_far(&g);
    advance_one(&g);
    CHECK_EQ(g.alive, 0);
    CHECK_EQ(g.snake.len, 3);        /* the fatal step returns before pushing */

    /* same again vertically, off the top */
    blank_game(&g);
    Point hcol[] = {{4, 2}, {4, 1}, {4, 0}};
    set_body(&g, hcol, 3);
    g.dir[0] = 0; g.dir[1] = -1; g.wrap = 0;
    tokens_far(&g);
    advance_one(&g);
    CHECK_EQ(g.alive, 0);

    /* the seam is a tunnel: the identical move in wrap mode is just a step */
    blank_game(&g);
    set_body(&g, hrow, 3);
    g.dir[0] = 1; g.dir[1] = 0; g.wrap = 1;
    tokens_far(&g);
    advance_one(&g);
    CHECK_EQ(g.alive, 1);
    CHECK_EQ(g.snake.cells[g.snake.head].x, 0);
    CHECK_EQ(g.snake.len, 3);

    /* and a step onto your own body is a wound, not a death */
    Point bite[] = {{2, 0}, {2, 1}, {3, 1}, {3, 2}, {2, 2}};
    blank_game(&g);
    set_body(&g, bite, 5);
    g.dir[0] = 0; g.dir[1] = -1; g.wrap = 0;
    tokens_far(&g);
    advance_one(&g);
    CHECK_EQ(g.alive, 1);
    CHECK(g.snake.wound_len > 0);
}

/* ------------------------------------------------------------------ *
 * 2. the classic vacating-tail rule
 * ------------------------------------------------------------------ */

/* The one body cell the head IS allowed to walk onto: the tail tip, because it
 * lifts off the board by the very act of stepping. Treating it as a bite is the
 * classic snake bug — the snake would bleed out its own tail on every tight
 * turn — and treating it as solid-but-fatal would be a death where the rules
 * allow none. A 2x2 loop is the smallest shape that exercises it. */
static void test_vacating_tail_tip_is_not_a_bite(void) {
    world_reset(10, 6);
    Game g;
    blank_game(&g);
    Point loop[] = {{1, 1}, {1, 2}, {2, 2}, {2, 1}};   /* tail (1,1) ... head (2,1) */
    set_body(&g, loop, 4);
    g.dir[0] = -1; g.dir[1] = 0;                        /* onto (1,1) = the tail tip */
    tokens_far(&g);

    CHECK_EQ(snake_chain_depth(&g.snake, (Point) { 1, 1 }), g.snake.len - 1);

    advance_one(&g);
    CHECK_EQ(g.alive, 1);
    CHECK_EQ(g.snake.wound_len, 0);        /* no wound: it was never a bite */
    CHECK_EQ(g.snake.len, 4);              /* push+pop: length unchanged */
    CHECK_EQ(g.snake.cells[g.snake.head].x, 1);
    CHECK_EQ(g.snake.cells[g.snake.head].y, 1);
    /* The body ROTATED rather than travelled, and that is what a closed loop
     * does: the cell it shed, the old tail tip (1,1), is the very cell the head
     * has just landed on, so all four cells of the 2x2 are still occupied and
     * NONE of them reads free. depth counts from the new head, so the cell the
     * head came from, (2,1), is depth 1 — still part of the snake. Reading -1
     * there (the rig's original mistake) asked for the head's own neck to have
     * vanished; "the tail tip frees up" belongs to an ordinary step, and
     * test_head_flies_over_shed_cells is where that is proved. */
    CHECK_EQ(snake_chain_depth(&g.snake, (Point) { 1, 1 }), 0);
    CHECK_EQ(snake_chain_depth(&g.snake, (Point) { 2, 1 }), 1);
    CHECK_EQ(snake_chain_depth(&g.snake, (Point) { 2, 2 }), 2);
    CHECK_EQ(snake_chain_depth(&g.snake, (Point) { 1, 2 }), 3);
    CHECK(snake_occupied(&g, (Point) { 1, 1 }));
    CHECK(snake_occupied(&g, (Point) { 2, 1 }));
    CHECK(snake_occupied(&g, (Point) { 2, 2 }));
    CHECK(snake_occupied(&g, (Point) { 1, 2 }));
}

/* Food on a body cell is EATEN, not bitten into — the eat test runs first in
 * advance_one ("a step that eats does not bite"). A bite where the player
 * placed a token would silently destroy their food and shorten the snake. */
static void test_eat_wins_over_bite(void) {
    world_reset(10, 6);
    Game g;
    blank_game(&g);
    Point bite[] = {{2, 0}, {2, 1}, {3, 1}, {3, 2}, {2, 2}};
    set_body(&g, bite, 5);
    g.dir[0] = 0; g.dir[1] = -1;
    Point f[1] = { { 2, 1 } };             /* sitting on the neck, depth 3 */
    int placed[1] = { 1 };
    set_tokens(&g, f, placed, 1);

    advance_one(&g);
    CHECK_EQ(g.alive, 1);
    CHECK_EQ(g.snake.wound_len, 0);        /* not a bite */
    CHECK_EQ(g.snake.len, 6);              /* and it grew: push without pop */
    CHECK_EQ(g.flash, FLASH_TICKS);        /* celebrated on the border */
}

/* ------------------------------------------------------------------ *
 * 3. a bite severs correctly
 * ------------------------------------------------------------------ */

/* The bite rig: tail->head (2,0),(2,1),(3,1),(3,2),(2,2). The head (2,2)
 * travels up onto (2,1), which sits at chain depth 3 while len-1 is 4 — so it
 * is a genuine mid-body bite and not the vacating tail tip. */
static void build_bite_rig(Game *g) {
    blank_game(g);
    Point bite[] = {{2, 0}, {2, 1}, {3, 1}, {3, 2}, {2, 2}};
    set_body(g, bite, 5);
    g->dir[0] = 0; g->dir[1] = -1;
    g->wrap = 1;                            /* so follow-on steps cannot die */
    tokens_far(g);
}

/* Bite mid-body: the live body stops AT the bite, the severed cells are the
 * bitten one plus everything toward the tail tip, they lie where they fell, and
 * their countdowns are staggered so the chunk drains from the bitten end. */
static void test_bite_severs_to_the_chain_depth(void) {
    world_reset(10, 6);
    Game g;
    build_bite_rig(&g);

    advance_one(&g);                        /* the bite at depth 3 */

    CHECK_EQ(g.alive, 1);
    CHECK_EQ(g.snake.len, 4);               /* len was cut to 3, then the head pushed */
    CHECK_EQ(g.snake.wound_len, 2);         /* (2,1) and (2,0) came off */
    /* positions they fell at, in severing order: bitten cell first */
    CHECK_EQ(g.snake.wound[0].p.x, 2);
    CHECK_EQ(g.snake.wound[0].p.y, 1);
    CHECK_EQ(g.snake.wound[1].p.x, 2);
    CHECK_EQ(g.snake.wound[1].p.y, 0);
    /* staggered so the bitten end expires before the tail tip, inside a fade */
    CHECK(g.snake.wound[0].ttl > 0);
    CHECK(g.snake.wound[0].ttl < g.snake.wound[1].ttl);
    CHECK_EQ(g.snake.wound[0].ttl, WOUND_FADE / 2);
    CHECK_EQ(g.snake.wound[1].ttl, WOUND_FADE - 1);
    CHECK(g.snake.wound[1].ttl <= WOUND_FADE);
    /* the head flew into the scar the bite just opened */
    CHECK_EQ(g.snake.cells[g.snake.head].x, 2);
    CHECK_EQ(g.snake.cells[g.snake.head].y, 1);
    /* the severed cells left the LIVE body — only the corpse holds them now */
    CHECK_EQ(snake_chain_depth(&g.snake, (Point) { 2, 1 }), 0);   /* head sits on it */
    CHECK_EQ(snake_chain_depth(&g.snake, (Point) { 2, 0 }), -1);
    /* and the untouched front of the body survived intact */
    CHECK(snake_contains(&g.snake, (Point) { 3, 2 }));
    CHECK(snake_contains(&g.snake, (Point) { 3, 1 }));
}

/* ------------------------------------------------------------------ *
 * 4. a corpse lies where it fell
 * ------------------------------------------------------------------ */

/* The invariant that forces snake_bite to COPY points out of the ring: the ring
 * belongs to the live body, so a cell that dropped out of it no longer holds
 * the position it fell at. An implementation that remembered corpse positions as
 * RING INDICES reads back whatever the live body has since written there — the
 * corpse drifts along behind the head instead of lying where it fell, which is
 * both wrong on screen and wrong to the hunt AI's occupancy grid.
 * So: poison the very ring cells the corpse used to occupy, then prove the
 * corpse has not moved. A ring-index implementation fails this immediately. */
static void test_corpse_stays_where_it_fell(void) {
    world_reset(10, 6);
    Game g;
    build_bite_rig(&g);
    int ring_head = g.snake.head;                  /* where the head sat pre-bite */
    int slot_bitten = (ring_head - 3 + MAX_SNAKE * 2) % MAX_SNAKE;
    int slot_tip = (ring_head - 4 + MAX_SNAKE * 2) % MAX_SNAKE;

    advance_one(&g);
    CHECK_EQ(g.snake.wound_len, 2);

    /* travel a while: the head marches up column 2, over its own shed cells */
    for (int i = 0; i < 6; i++) game_step(&g);

    CHECK_EQ(g.snake.wound[0].p.x, 2);
    CHECK_EQ(g.snake.wound[0].p.y, 1);
    CHECK_EQ(g.snake.wound[1].p.x, 2);
    CHECK_EQ(g.snake.wound[1].p.y, 0);

    /* now poison the ring cells those positions used to live in */
    g.snake.cells[slot_bitten].x = -7; g.snake.cells[slot_bitten].y = -7;
    g.snake.cells[slot_tip].x = -8;    g.snake.cells[slot_tip].y = -8;
    CHECK(snake_wound_contains(&g.snake, (Point) { 2, 1 }));
    CHECK(snake_wound_contains(&g.snake, (Point) { 2, 0 }));
    CHECK(snake_occupied(&g, (Point) { 2, 1 }));
    CHECK(snake_occupied(&g, (Point) { 2, 0 }));
    CHECK_EQ(g.snake.wound[0].p.x, 2);
    CHECK_EQ(g.snake.wound[0].p.y, 1);

    /* and keep travelling with the poisoned slots behind us */
    for (int i = 0; i < 4; i++) game_step(&g);
    CHECK_EQ(g.snake.wound[0].p.x, 2);
    CHECK_EQ(g.snake.wound[0].p.y, 1);
    CHECK_EQ(g.snake.wound[1].p.x, 2);
    CHECK_EQ(g.snake.wound[1].p.y, 0);
    CHECK_EQ(g.alive, 1);
}

/* ------------------------------------------------------------------ *
 * 5. the head flies over its own shed cells
 * ------------------------------------------------------------------ */

/* "Its own past is not in the way": a cell the body has already SHED (it is not
 * in the live body any more, corpse or not) must read free to snake_chain_depth
 * and must not start a second wound. Otherwise a snake that bit itself once
 * could never cross the cells it lost and would shred itself to nothing. */
static void test_head_flies_over_shed_cells(void) {
    world_reset(10, 6);
    Game g;
    build_bite_rig(&g);
    advance_one(&g);                               /* bite, corpse at (2,1),(2,0) */
    CHECK_EQ(g.snake.wound_len, 2);

    /* (2,0) is shed — gone from the live body, still lying there as a corpse */
    CHECK_EQ(snake_chain_depth(&g.snake, (Point) { 2, 0 }), -1);
    CHECK(snake_occupied(&g, (Point) { 2, 0 }));    /* solid to the AI, not to the head */

    g.dir[0] = 0; g.dir[1] = -1;                    /* head (2,1) -> (2,0) */
    advance_one(&g);
    CHECK_EQ(g.alive, 1);
    CHECK_EQ(g.snake.wound_len, 2);                 /* no new wound from a shed cell */
    CHECK_EQ(g.snake.cells[g.snake.head].x, 2);
    CHECK_EQ(g.snake.cells[g.snake.head].y, 0);
    CHECK_EQ(g.snake.len, 4);                       /* ordinary push+pop */
}

/* ------------------------------------------------------------------ *
 * 6. corpses are solid, then they are not
 * ------------------------------------------------------------------ */

/* A severed cell blocks the hunt AI and refuses clicks until its own countdown
 * runs out, and the whole board is clean again inside WOUND_FADE ticks. This is
 * also the only thing that makes a bite visible at all, so the fade has to run
 * to completion — a corpse that never expires is a permanent wall the player
 * cannot explain. */
static void test_corpse_fades_after_wound_fade(void) {
    world_reset(10, 6);
    Game g;
    build_bite_rig(&g);
    advance_one(&g);

    /* Both chunks are solid — and note WHICH reader proves it. This rig bites
     * upward, so advance_one flew the head into the scar: (2,1) is the live HEAD
     * cell as well as a corpse, and snake_occupied can never go false there
     * while the snake is standing on it. snake_wound_contains is the reader that
     * means "still bleeding"; (2,0) is corpse-only, so it carries the occupancy
     * half of the invariant. */
    CHECK(snake_occupied(&g, (Point) { 2, 1 }));
    CHECK(snake_wound_contains(&g.snake, (Point) { 2, 1 }));
    CHECK(snake_occupied(&g, (Point) { 2, 0 }));
    CHECK(snake_wound_contains(&g.snake, (Point) { 2, 0 }));

    /* the bitten end (ttl WOUND_FADE/2) goes first, the tip (WOUND_FADE-1) last */
    for (int i = 0; i < WOUND_FADE / 2; i++) wound_tick(&g.snake);
    CHECK_EQ(g.snake.wound_len, 1);                 /* front drained */
    CHECK(!snake_wound_contains(&g.snake, (Point) { 2, 1 }));
    CHECK(snake_contains(&g.snake, (Point) { 2, 1 }));   /* only the head holds it now */
    CHECK(snake_occupied(&g, (Point) { 2, 0 }));    /* the tip is still bleeding */

    for (int i = 0; i < WOUND_FADE / 2; i++) wound_tick(&g.snake);
    CHECK_EQ(g.snake.wound_len, 0);                 /* board clean again */
    CHECK(!snake_wound_contains(&g.snake, (Point) { 2, 1 }));
    CHECK(!snake_occupied(&g, (Point) { 2, 0 }));   /* corpse-only cell: truly free */

    /* five cells up the column and the head has vacated the bitten cell as
     * well — only now does "not occupied" mean what it has to mean for (2,1),
     * and five (not six: the column is 6 tall and the seam would hand the head
     * straight back to it) leaves the whole 4-cell body clear of both. */
    for (int i = 0; i < 5; i++) advance_one(&g);
    CHECK(!snake_occupied(&g, (Point) { 2, 1 }));
    CHECK(!snake_occupied(&g, (Point) { 2, 0 }));

    /* ticking an empty queue is a no-op, not an underflow */
    wound_tick(&g.snake);
    CHECK_EQ(g.snake.wound_len, 0);
}

/* wound_tick drains from the FRONT and stops at the first cell still counting,
 * so once a second bite lands behind a still-counting first one, an expired
 * cell can be stuck in the MIDDLE of the queue. The comment in snake.c claims
 * that is harmless "since every reader checks ttl before trusting a cell" —
 * this proves it, because a reader that only scanned by index would report a
 * faded corpse as solid forever. */
static void test_expired_cell_midqueue_is_ignored(void) {
    world_reset(10, 6);
    Game g;
    blank_game(&g);
    Point head_only[] = {{0, 0}};
    set_body(&g, head_only, 1);
    tokens_far(&g);

    /* hand-built queue: live, ALREADY EXPIRED, live — the front is not the
     * problem, the middle is */
    g.snake.wound[0].p = (Point) { 1, 1 }; g.snake.wound[0].ttl = 5;
    g.snake.wound[1].p = (Point) { 2, 2 }; g.snake.wound[1].ttl = 0;
    g.snake.wound[2].p = (Point) { 3, 3 }; g.snake.wound[2].ttl = 9;
    g.snake.wound_len = 3;

    CHECK(snake_wound_contains(&g.snake, (Point) { 1, 1 }));
    CHECK(!snake_wound_contains(&g.snake, (Point) { 2, 2 }));   /* the whole point */
    CHECK(snake_wound_contains(&g.snake, (Point) { 3, 3 }));
    CHECK(!snake_occupied(&g, (Point) { 2, 2 }));

    /* The front expires and the drain takes the whole LEADING RUN of expired
     * cells with it: once the head of the queue is gone there is nothing left to
     * read the dead middle cell as, so compacting it out is the engine being
     * tidy, not losing a live cell. It stops at the first ttl > 0, so nothing
     * still bleeding is ever dropped — the survivor here is (3,3) and it is the
     * only entry left, still at the front of the queue where readers look. */
    for (int i = 0; i < 6; i++) wound_tick(&g.snake);
    CHECK_EQ(g.snake.wound_len, 1);
    CHECK(!snake_occupied(&g, (Point) { 1, 1 }));
    CHECK(!snake_occupied(&g, (Point) { 2, 2 }));
    CHECK(snake_occupied(&g, (Point) { 3, 3 }));
    CHECK_EQ(g.snake.wound[0].p.x, 3);
    CHECK_EQ(g.snake.wound[0].p.y, 3);

    /* and once it catches up, the queue empties from the front as usual */
    for (int i = 0; i < 5; i++) wound_tick(&g.snake);
    CHECK_EQ(g.snake.wound_len, 0);
    CHECK(!snake_occupied(&g, (Point) { 3, 3 }));

    /* The genuinely stuck case — the one the front drain cannot reach: the cell
     * behind an expired middle is still COUNTING, so the drain stops before it
     * and the dead entry sits in the middle of the queue indefinitely. This is
     * where a reader that scanned by index instead of checking ttl would call a
     * faded corpse solid forever. */
    g.snake.wound[0].p = (Point) { 4, 4 }; g.snake.wound[0].ttl = 9;
    g.snake.wound[1].p = (Point) { 5, 5 }; g.snake.wound[1].ttl = 0;
    g.snake.wound[2].p = (Point) { 6, 3 }; g.snake.wound[2].ttl = 9;
    g.snake.wound_len = 3;
    for (int i = 0; i < 5; i++) wound_tick(&g.snake);   /* front still has 4 left */
    CHECK_EQ(g.snake.wound_len, 3);                     /* drained nothing: correct */
    CHECK(snake_occupied(&g, (Point) { 4, 4 }));        /* the live front holds */
    CHECK(!snake_occupied(&g, (Point) { 5, 5 }));       /* stuck middle: unread */
    CHECK(!snake_wound_contains(&g.snake, (Point) { 5, 5 }));
    CHECK(snake_occupied(&g, (Point) { 6, 3 }));        /* and the live back holds */
}

/* A second bite while the first chunk is still bleeding out must add to the
 * queue, not clobber it — the player sees both chunks fade. */
static void test_second_bite_behind_a_live_one(void) {
    world_reset(10, 6);
    Game g;
    build_bite_rig(&g);
    advance_one(&g);                                   /* first: (2,1),(2,0) */
    CHECK_EQ(g.snake.wound_len, 2);

    /* Build a second body elsewhere and bite it while the first corpse is still
     * counting. set_body() runs snake_init, which zeroes wound_len — that would
     * quietly delete the first chunk, the very thing under test — so the rig uses
     * set_body_keeping_wounds. Same shape as the bite rig (a 2x2 loop with the
     * head sticking out) shifted onto clear ground: tail->head
     * (6,3),(6,4),(7,4),(7,5),(6,5), head (6,5) walking UP onto (6,4), which sits
     * at chain depth 3 while len-1 is 4 — a mid-body bite that severs exactly the
     * bitten cell and the tail tip, so the queue goes 2 -> 4 and the live body
     * keeps depths 0..2 and then gains the head: len 4. */
    Point body[] = {{6, 3}, {6, 4}, {7, 4}, {7, 5}, {6, 5}};
    set_body_keeping_wounds(&g, body, 5);
    CHECK_EQ(g.snake.wound_len, 2);                    /* the rig must not drop it */
    g.dir[0] = 0; g.dir[1] = -1;
    advance_one(&g);                                   /* onto (6,4): depth 3 */
    CHECK_EQ(g.snake.wound_len, 4);                    /* ADDED, not clobbered */
    /* appended behind the first chunk, in severing order, where they fell */
    CHECK_EQ(g.snake.wound[2].p.x, 6);
    CHECK_EQ(g.snake.wound[2].p.y, 4);
    CHECK_EQ(g.snake.wound[3].p.x, 6);
    CHECK_EQ(g.snake.wound[3].p.y, 3);
    /* the first chunk survived: by now the head has left column 2 entirely, so
       those two cells are held by NOTHING but the first corpse */
    CHECK(snake_wound_contains(&g.snake, (Point) { 2, 1 }));
    CHECK(snake_wound_contains(&g.snake, (Point) { 2, 0 }));
    CHECK(snake_occupied(&g, (Point) { 2, 1 }));
    CHECK(snake_occupied(&g, (Point) { 2, 0 }));
    /* and the second chunk is solid on its own account: (6,3) is pure corpse,
       (6,4) is the scar the head flew into */
    CHECK(snake_occupied(&g, (Point) { 6, 3 }));
    CHECK(snake_wound_contains(&g.snake, (Point) { 6, 4 }));
    CHECK_EQ(g.snake.cells[g.snake.head].x, 6);
    CHECK_EQ(g.snake.cells[g.snake.head].y, 4);
    CHECK_EQ(g.snake.len, 4);
    /* both chunks still fade independently */
    for (int i = 0; i < WOUND_FADE; i++) wound_tick(&g.snake);
    CHECK_EQ(g.snake.wound_len, 0);
}

/* ------------------------------------------------------------------ *
 * 7. auto-hunt plans on a TORUS
 * ------------------------------------------------------------------ */

/* A body wall running edge to edge is just what a long snake looks like, and on
 * a WRAPPED board it is a false cage: crossing the perpendicular seam gets you
 * around it. The BFS used to clip its neighbours at the board edges instead of
 * wrapping them through hunt_next_cell, so the wave stopped at the wall while
 * the real board had an opening at the seam — every legal neighbour of the head
 * then read dist == -1 ("no food reachable"), no direction scored, the boxed-in
 * fallback fell through to marching straight, and in wrap mode straight is
 * ALWAYS legal: the snake walked one horizontal line across the screen and
 * through the seam forever, never turning, never eating. This is the highest
 * value test in the file. */
static void build_wall(Game *g) {
    blank_game(g);
    /* tail->head: the whole column x=5, then three cells back to the head at
     * (4,3) — a contiguous snake of 9 on a 10x6 board, head left of the wall */
    Point body[] = {
        {5, 0}, {5, 1}, {5, 2}, {5, 3}, {5, 4}, {5, 5},
        {4, 5}, {4, 4}, {4, 3}
    };
    set_body(g, body, 9);
    g->dir[0] = 0; g->dir[1] = -1;          /* straight up: not toward the wall */
    Point f[1] = { { 7, 3 } };               /* food on the FAR side of the wall */
    int placed[1] = { 0 };
    set_tokens(g, f, placed, 1);
}

static void test_hunt_plans_on_a_torus(void) {
    world_reset(10, 6);
    Game g;
    int d[2] = { 9, 9 };

    /* --- wrap mode: the wall does NOT seal the wave off --- */
    build_wall(&g);
    g.wrap = 1;
    int found = hunt_step(&g, d);
    CHECK_EQ(found, 1);                       /* the bug: nothing scored at all */
    /* the min-distance neighbour is LEFT (toward the seam at x=0), not the wall
     * and not "up", which is the direction with no food behind it */
    CHECK_EQ(d[0], -1);
    CHECK_EQ(d[1], 0);
    /* sanity: the wall direction really is refused, and no reversal */
    CHECK(!(d[0] == -g.dir[0] && d[1] == -g.dir[1]));

    /* end to end: the AI has to actually get there. Under the plane-topology bug
     * this never happens — no path, so straight forever, no food ever. */
    g.hunt = 1;
    int start_len = g.snake.len;
    int turned = 0;
    int first_dx = g.dir[0], first_dy = g.dir[1];
    for (int tick = 0; tick < 400 && g.snake.len == start_len; tick++) {
        game_step(&g);
        if (g.dir[0] != first_dx || g.dir[1] != first_dy) turned = 1;
    }
    CHECK_EQ(g.alive, 1);
    CHECK(g.snake.len > start_len);           /* it ate across the seam */
    CHECK_EQ(turned, 1);                      /* and it turned, unlike the bug */
}

/* The negative control: the SAME board without wrap really does seal the wave
 * off — a full-height wall is a wall — so there is genuinely nothing to plan,
 * and hunt_step must report "keep going straight" (0) rather than inventing a
 * direction toward unreachable food. Without this pair the torus test could
 * pass for the wrong reason. */
static void test_hunt_wall_seals_a_plane(void) {
    world_reset(10, 6);
    Game g;
    build_wall(&g);
    g.wrap = 0;
    int d[2] = { 9, 9 };
    int found = hunt_step(&g, d);
    CHECK_EQ(found, 0);                        /* no reachable food, keep straight */
    CHECK_EQ(d[0], 9);                         /* out untouched when it declines */
    CHECK_EQ(d[1], 9);
    /* the straight-ahead stride really is free, so 0 means "legally straight" */
    CHECK(hunt_stride_free(&g, g.snake.cells[g.snake.head], 0, -1, NULL));
}

/* And proof the decline is about reachability, not about being boxed in: with
 * the same sealed-off plane, block straight ahead and the AI must still move —
 * the fallback takes the first direction whose WHOLE stride is free. */
static void test_hunt_boxed_in_still_moves(void) {
    world_reset(10, 6);
    Game g;
    build_wall(&g);
    g.wrap = 0;
    g.dir[0] = 0; g.dir[1] = -1;
    /* wall the head up: it is at (4,3), so put a corpse at (4,2) */
    g.snake.wound[0].p = (Point) { 4, 2 };
    g.snake.wound[0].ttl = WOUND_FADE;
    g.snake.wound_len = 1;
    int d[2] = { 9, 9 };
    int found = hunt_step(&g, d);
    CHECK_EQ(found, 1);                        /* boxed in, but not frozen */
    CHECK(hunt_stride_free(&g, g.snake.cells[g.snake.head], d[0], d[1], NULL));
    CHECK(!(d[0] == 0 && d[1] == 1));           /* (4,4) is body: not that way */
}

/* ------------------------------------------------------------------ *
 * 8. the boxed-in fallback checks the WHOLE stride
 * ------------------------------------------------------------------ */

/* hunt_stride_free is the AI's idea of what the snake may do, and a horizontal
 * move covers TWO cells a tick in a terminal. Checking one cell made "legal" a
 * lie — the stride's second cell then ran into the wall (a death) or its own
 * body — and since the straight case wins whenever it is allowed at all, one
 * half-checked cell was enough to pin the AI to that direction forever.
 * So: first cell free, second cell taken => NOT free. Both free => free. A
 * vertical move covers one cell, so it must not be second-cell-blocked. */
static void test_stride_checks_both_cells(void) {
    world_reset(10, 6);
    Game g;
    int w = BOARD_W;

    /* Case 1 — the head is at (w-2,2), so the stride's SECOND cell is off the
     * board. The first cell, (w-1,2), is perfectly legal, and that is exactly
     * what a one-cell check called "free": the tick ends in the wall, a death.
     * (w-1,2) is the last COLUMN, not the wall — the wall is one further out —
     * so the rig has to park the head right up against the edge to reach it.) */
    blank_game(&g);
    Point b_wall[] = {{w - 5, 2}, {w - 4, 2}, {w - 3, 2}, {w - 2, 2}};
    set_body(&g, b_wall, 4);                            /* head (w-2,2) = (8,2) */
    tokens_far(&g);
    CHECK_EQ(g.snake.cells[g.snake.head].x, w - 2);
    CHECK(!hunt_stride_free(&g, g.snake.cells[g.snake.head], 1, 0, NULL));

    /* Case 2 — one cell further from the wall: the same direction is free,
     * because both cells of the stride are on the board and clear of the body. */
    blank_game(&g);
    Point b[] = {{w - 6, 2}, {w - 5, 2}, {w - 4, 2}};   /* head (w-4,2) = (6,2) */
    set_body(&g, b, 3);
    tokens_far(&g);
    Point head = g.snake.cells[g.snake.head];
    CHECK_EQ(head.x, w - 4);
    CHECK(hunt_stride_free(&g, head, 1, 0, NULL));
    /* Left from the same head is a TWO-cell stride too — and both of its cells
     * are the body, so it is not free either. "Horizontal" is two cells in BOTH
     * directions, not just the one the snake is travelling. */
    CHECK(!hunt_stride_free(&g, head, -1, 0, NULL));
    /* and left with clear ground ahead of it IS free (body to the RIGHT here) */
    blank_game(&g);
    Point b_left[] = {{7, 2}, {6, 2}, {5, 2}};           /* tail (7,2) ... head (5,2) */
    set_body(&g, b_left, 3);
    tokens_far(&g);
    CHECK(hunt_stride_free(&g, g.snake.cells[g.snake.head], -1, 0, NULL));
    /* up: vertical is one cell, so the off-board cell two up is irrelevant */
    blank_game(&g);
    Point b2[] = {{4, 3}, {4, 2}, {4, 1}};
    set_body(&g, b2, 3);
    tokens_far(&g);
    CHECK(hunt_stride_free(&g, g.snake.cells[g.snake.head], 0, -1, NULL));
    /* and up from row 0 really is not free */
    CHECK(!hunt_stride_free(&g, (Point) { 4, 0 }, 0, -1, NULL));

    /* own body as the stride's second cell — a corpse counts as much as a live
     * segment does, since it is still a wall in the middle of the board */
    /* The head sits at (4,2) with its body running DOWN from it, so the whole
     * rightward stride (5,2),(6,2) is ground the snake does not occupy and the
     * only thing that can block it is a corpse. That separation is the point:
     * with the body laid along the stride, as this rig used to be, the live
     * segments answered for the block and the corpse proved nothing. */
    blank_game(&g);
    Point b3[] = {{4, 4}, {4, 3}, {4, 2}};           /* tail (4,4) ... head (4,2) */
    set_body(&g, b3, 3);
    tokens_far(&g);
    g.snake.wound[0].p = (Point) { 6, 2 };            /* ONLY the far cell */
    g.snake.wound[0].ttl = WOUND_FADE;
    g.snake.wound_len = 1;
    /* the near cell is free and the far one is a corpse: still not free. This is
     * the exact case a one-cell check used to call legal. */
    CHECK(!hunt_stride_free(&g, (Point) { 4, 2 }, 1, 0, NULL));
    g.snake.wound[1].p = (Point) { 5, 2 };            /* now the whole stride */
    g.snake.wound[1].ttl = WOUND_FADE;
    g.snake.wound_len = 2;
    CHECK(!hunt_stride_free(&g, (Point) { 4, 2 }, 1, 0, NULL));  /* (5,2),(6,2)=corpse */
    CHECK(hunt_stride_free(&g, (Point) { 4, 2 }, 0, -1, NULL));   /* (4,1): fine */
    g.snake.wound[0].ttl = 0;                                       /* both faded */
    g.snake.wound[1].ttl = 0;
    CHECK(hunt_stride_free(&g, (Point) { 4, 2 }, 1, 0, NULL));     /* both free now */
    /* a ttl-0 corpse must not be a wall: it is still in the queue, unread */
    CHECK_EQ(g.snake.wound_len, 2);
    CHECK(!snake_occupied(&g, (Point) { 6, 2 }));

    /* the seam is part of the stride too: from the last column heading right the
     * two cells are (0,y) and (1,y), so blocking (1,y) blocks the stride */
    blank_game(&g);
    Point b4[] = {{BOARD_W - 3, 2}, {BOARD_W - 2, 2}, {BOARD_W - 1, 2}};
    set_body(&g, b4, 3);
    tokens_far(&g);
    g.wrap = 1;
    CHECK(hunt_stride_free(&g, g.snake.cells[g.snake.head], 1, 0, NULL));
    g.snake.wound[0].p = (Point) { 1, 2 };
    g.snake.wound[0].ttl = WOUND_FADE;
    g.snake.wound_len = 1;
    CHECK(!hunt_stride_free(&g, g.snake.cells[g.snake.head], 1, 0, NULL));

    /* `first`, when asked for, is the NEAR cell — where the distance field is
     * read — not the cell the head ends the tick on */
    g.snake.wound_len = 0;
    Point near_cell = { -1, -1 };
    CHECK(hunt_stride_free(&g, g.snake.cells[g.snake.head], 1, 0, &near_cell));
    CHECK_EQ(near_cell.x, 0);
    CHECK_EQ(near_cell.y, 2);
}

/* ------------------------------------------------------------------ *
 * 9. stride length, and speed that never scales with progress
 * ------------------------------------------------------------------ */

/* One place decides how many cells a tick covers, and game_step and
 * hunt_stride_free have to agree absolutely about it: a terminal cell is ~2x
 * taller than wide, so horizontal moves cover two cells; a QML grid has square
 * cells and needs no compensation (--square-cells). An AI that validates a
 * different stride from the one the snake travels is the bug that pinned
 * auto-hunt to a straight line forever. */
static void test_stride_len_and_square_cells(void) {
    world_reset(10, 6);
    Game g;
    blank_game(&g);
    Point b[] = {{2, 2}};
    set_body(&g, b, 1);
    tokens_far(&g);

    square_cells = 0;                                  /* terminal */
    CHECK_EQ(stride_len_for(&g, 1, 0), 2);
    CHECK_EQ(stride_len_for(&g, -1, 0), 2);
    CHECK_EQ(stride_len_for(&g, 0, 1), 1);
    CHECK_EQ(stride_len_for(&g, 0, -1), 1);

    square_cells = 1;                                  /* every direction one cell */
    CHECK_EQ(stride_len_for(&g, 1, 0), 1);
    CHECK_EQ(stride_len_for(&g, -1, 0), 1);
    CHECK_EQ(stride_len_for(&g, 0, 1), 1);
    CHECK_EQ(stride_len_for(&g, 0, -1), 1);
    square_cells = 0;
}

/* Behavioural half of the same invariant, and the half that catches a mismatch
 * between the two places that use it: a token TWO cells ahead is eaten in ONE
 * tick horizontally in a terminal (two-cell stride) and needs TWO ticks with
 * square cells. */
static void test_stride_is_what_the_snake_actually_travels(void) {
    Game g;
    Point b[] = {{2, 2}};
    Point tok[1] = { { 4, 2 } };

    world_reset(10, 6);
    blank_game(&g);
    set_body(&g, b, 1);
    int placed[1] = { 1 };
    set_tokens(&g, tok, placed, 1);
    g.dir[0] = 1; g.dir[1] = 0;
    game_step(&g);                                     /* one tick, two cells */
    CHECK_EQ(g.snake.cells[g.snake.head].x, 4);
    /* Eaten — and the player's token really is spent (no respawn in place), but
     * food_n does NOT read 0: ensure_food immediately tops the board back up with
     * one of the GAME's own tokens, because a board with no tokens is a dead game
     * twice over (nothing to grow on, and no seeds for the hunt AI's field). So
     * "it was the player's" is proved by WHICH token is on the board now. */
    CHECK_EQ(g.food_n, 1);
    CHECK_EQ(g.food[0].placed, 0);                     /* the game's, not theirs */
    CHECK(!(g.food[0].p.x == 4 && g.food[0].p.y == 2)); /* never under the head */
    CHECK_EQ(g.snake.len, 2);

    world_reset(10, 6);
    square_cells = 1;
    blank_game(&g);
    set_body(&g, b, 1);
    set_tokens(&g, tok, placed, 1);
    g.dir[0] = 1; g.dir[1] = 0;
    game_step(&g);                                     /* one tick, one cell */
    CHECK_EQ(g.snake.cells[g.snake.head].x, 3);
    CHECK_EQ(g.food_n, 1);                             /* still there */
    game_step(&g);
    CHECK_EQ(g.snake.cells[g.snake.head].x, 4);
    CHECK_EQ(g.food_n, 1);                             /* spent, then topped back up */
    CHECK_EQ(g.food[0].placed, 0);
    square_cells = 0;

    /* and legality has to agree with the stride the snake travels: a direction
     * that is legal one cell at a time must NOT be claimed legal two cells at a
     * time, and vice versa. (5,2) is a corpse one cell ahead of the head. */
    world_reset(10, 6);
    blank_game(&g);
    Point b2[] = {{3, 2}};
    set_body(&g, b2, 1);
    tokens_far(&g);
    g.snake.wound[0].p = (Point) { 5, 2 };
    g.snake.wound[0].ttl = WOUND_FADE;
    g.snake.wound_len = 1;
    Point head_pos = g.snake.cells[g.snake.head];
    square_cells = 1;
    CHECK(hunt_stride_free(&g, head_pos, 1, 0, NULL));       /* only (4,2) matters */
    square_cells = 0;
    CHECK(!hunt_stride_free(&g, head_pos, 1, 0, NULL));      /* (5,2) blocks it */
}

/* Speed is constant, on purpose: tying tick_delay_ms to the old score made the
 * snake feel faster as it grew, and it was removed. Any dependence on length,
 * wrap, hunt or flash is a regression, so it is asserted away here. */
static void test_speed_is_constant(void) {
    world_reset(10, 6);
    Game g;
    blank_game(&g);
    Point b[64];
    for (int i = 0; i < 64; i++) { b[i].x = i % BOARD_W; b[i].y = i / BOARD_W; }

    CHECK_EQ(tick_delay_ms(&g), TICK_MS);
    g.wrap = 1;    CHECK_EQ(tick_delay_ms(&g), TICK_MS);
    g.hunt = 1;    CHECK_EQ(tick_delay_ms(&g), TICK_MS);
    g.flash = FLASH_TICKS; CHECK_EQ(tick_delay_ms(&g), TICK_MS);
    set_body(&g, b, 3);  CHECK_EQ(tick_delay_ms(&g), TICK_MS);
    set_body(&g, b, 64); CHECK_EQ(tick_delay_ms(&g), TICK_MS);
    g.paused = 1;        CHECK_EQ(tick_delay_ms(&g), TICK_MS);
    g.alive = 0;         CHECK_EQ(tick_delay_ms(&g), TICK_MS);
    CHECK_EQ(TICK_MS, 55);            /* the documented constant */
}

/* ------------------------------------------------------------------ *
 * 10. the board is never empty of tokens
 * ------------------------------------------------------------------ */

/* An empty board is a dead game TWICE over: food is the only way to grow, and
 * the hunt AI's whole plan is a distance field seeded FROM the tokens, so with
 * no seeds every cell reads "no path" and it marches straight forever. Tokens
 * leave play in exactly two ways — a click, or the snake eating the player's
 * own — and both must top the board back up with a GAME token (placed = 0), so
 * what comes back respawns in turn instead of being spent. */
static void test_board_is_never_empty(void) {
    Game g;

    /* route 1: click the LAST token away */
    world_reset(10, 6);
    blank_game(&g);
    Point b[] = {{2, 2}};
    set_body(&g, b, 1);
    Point one[1] = { { 7, 4 } };
    int one_placed[1] = { 1 };
    set_tokens(&g, one, one_placed, 1);
    place_or_remove(&g, (Point) { 7, 4 });
    CHECK_EQ(g.food_n, 1);
    CHECK_EQ(g.food[0].placed, 0);                     /* the GAME'S token came back */
    CHECK(in_bounds(g.food[0].p));
    CHECK(!snake_occupied(&g, g.food[0].p));

    /* route 2: eat the last clicked-in token */
    world_reset(10, 6);
    blank_game(&g);
    set_body(&g, b, 1);
    Point ahead[1] = { { 3, 2 } };
    int ahead_placed[1] = { 1 };
    set_tokens(&g, ahead, ahead_placed, 1);
    g.dir[0] = 1; g.dir[1] = 0;
    advance_one(&g);
    CHECK_EQ(g.snake.len, 2);                           /* the snake grew */
    CHECK_EQ(g.food_n, 1);                              /* and was replaced */
    CHECK_EQ(g.food[0].placed, 0);
    CHECK(in_bounds(g.food[0].p));

    /* and the seed the AI steers by really is there once that happens */
    g.hunt = 1;
    int d[2] = { 9, 9 };
    CHECK_EQ(hunt_step(&g, d), 1);

    /* eating one of the GAME's tokens re-rolls that slot in place, so the count
     * never moves at all */
    world_reset(10, 6);
    blank_game(&g);
    set_body(&g, b, 1);
    Point mine[2] = { { 3, 2 }, { 8, 5 } };
    int mine_placed[2] = { 0, 1 };
    set_tokens(&g, mine, mine_placed, 2);
    g.dir[0] = 1; g.dir[1] = 0;
    advance_one(&g);
    CHECK_EQ(g.food_n, 2);                              /* re-rolled, not removed */
    CHECK(!snake_occupied(&g, g.food[0].p));
    CHECK(!other_token_at(&g, g.food[0].p, 0));
}

/* spawn_food's two guards exist because of two ways to lose: testing
 * "food_index_at != i" instead of "is something else here" rejects every legal
 * cell and escapes only by re-rolling onto the token's own old cell — which
 * after an eat is under the head — an infinite loop that looks like a frozen
 * game; and a packed board has no legal cell at all, so the 1000-roll cap is
 * what keeps a full terminal from hanging. Both are exercised here: a board
 * with exactly one free cell (the guard spins hundreds of times and must still
 * find it), and a board with none (must return, not hang). */
static void test_spawn_food_guards(void) {
    world_reset(10, 6);
    Game g;
    blank_game(&g);

    /* every cell but (9,5) is body: exactly one legal landing */
    static Point all[MAX_SNAKE];
    int n = 0;
    for (int y = 0; y < BOARD_H; y++)
        for (int x = 0; x < BOARD_W; x++)
            if (!(x == 9 && y == 5)) { all[n].x = x; all[n].y = y; n++; }
    CHECK_EQ(n, BOARD_W * BOARD_H - 1);
    set_body(&g, all, n);
    Point t[1] = { { 0, 0 } };
    set_tokens(&g, t, NULL, 1);

    for (int trial = 0; trial < 200; trial++) {          /* the guard spins, hard */
        spawn_food(&g, 0);
        CHECK_EQ(g.food[0].p.x, 9);                      /* the ONE free cell, found */
        CHECK_EQ(g.food[0].p.y, 5);
    }

    /* no free cell anywhere: bounded spin, returns, no hang, no crash */
    all[n].x = 9; all[n].y = 5;
    set_body(&g, all, n + 1);
    CHECK_EQ(n + 1, BOARD_W * BOARD_H);
    spawn_food(&g, 0);                                   /* would hang without the cap */
    CHECK_EQ(g.food_n, 1);

    /* never on the snake, never on another token — repeated over a sparse board,
     * because these are random rolls and one sample proves nothing */
    for (int trial = 0; trial < 300; trial++) {
        world_reset(10, 6);
        blank_game(&g);
        Point body[6];
        for (int i = 0; i < 6; i++) { body[i].x = i; body[i].y = 0; }
        set_body(&g, body, 6);
        Point toks[3] = { { 8, 5 }, { 0, 5 }, { 4, 3 } };
        set_tokens(&g, toks, NULL, 3);
        int slot = trial % 3;
        spawn_food(&g, slot);
        CHECK(!snake_occupied(&g, g.food[slot].p));
        CHECK(!other_token_at(&g, g.food[slot].p, slot));
        CHECK(in_bounds(g.food[slot].p));
    }
}

/* ------------------------------------------------------------------ *
 * 11. click-to-place semantics
 * ------------------------------------------------------------------ */

/* A click means ONE thing: toggle the token on that board cell. Both front-ends
 * come through place_or_remove, so the overlay's grid and the terminal's mouse
 * cannot drift apart, and the never-empty board cannot be sidestepped by
 * whichever renderer is holding the mouse. The refusals matter as much as the
 * toggle: no blind edits under a menu, no token under the snake, no token off
 * the board, and the pantry has a door. */
static void test_place_or_remove(void) {
    Game g;
    world_reset(10, 6);
    blank_game(&g);
    Point b[] = {{2, 2}};
    set_body(&g, b, 1);
    tokens_far(&g);
    int n0 = g.food_n;

    /* an empty cell gains a token that belongs to the PLAYER */
    place_or_remove(&g, (Point) { 5, 4 });
    CHECK_EQ(g.food_n, n0 + 1);
    CHECK_EQ(g.food[n0].p.x, 5);
    CHECK_EQ(g.food[n0].p.y, 4);
    CHECK_EQ(g.food[n0].placed, 1);
    /* the game's own tokens keep their flag — it travels with the token */
    for (int i = 0; i < n0; i++) CHECK_EQ(g.food[i].placed, 0);

    /* same cell again takes it back: press-then-press is place-then-un-place,
     * which is why there is no "same cell within N ms counts once" timer */
    place_or_remove(&g, (Point) { 5, 4 });
    CHECK_EQ(g.food_n, n0);
    place_or_remove(&g, (Point) { 5, 4 });
    CHECK_EQ(g.food_n, n0 + 1);

    /* refused: the cell the snake occupies */
    place_or_remove(&g, (Point) { 2, 2 });
    CHECK_EQ(g.food_n, n0 + 1);
    CHECK_EQ(food_index_at(&g, (Point) { 2, 2 }), -1);
    /* refused: a corpse still bleeding out is solid too */
    g.snake.wound[0].p = (Point) { 6, 3 };
    g.snake.wound[0].ttl = WOUND_FADE;
    g.snake.wound_len = 1;
    place_or_remove(&g, (Point) { 6, 3 });
    CHECK_EQ(g.food_n, n0 + 1);
    g.snake.wound_len = 0;

    /* refused: off the play field (border, header, help rows) */
    place_or_remove(&g, (Point) { -1, 0 });
    place_or_remove(&g, (Point) { BOARD_W, 0 });
    place_or_remove(&g, (Point) { 0, BOARD_H });
    place_or_remove(&g, (Point) { 0, -1 });
    CHECK_EQ(g.food_n, n0 + 1);

    /* refused while a menu is up: no blind edits under the panel */
    g.paused = 1;
    place_or_remove(&g, (Point) { 1, 4 });
    CHECK_EQ(food_index_at(&g, (Point) { 1, 4 }), -1);
    g.paused = 0;
    place_or_remove(&g, (Point) { 1, 4 });             /* and works again once gone */
    CHECK(food_index_at(&g, (Point) { 1, 4 }) >= 0);
    CHECK_EQ(g.food_n, n0 + 2);

    g.alive = 0;
    place_or_remove(&g, (Point) { 0, 5 });
    CHECK_EQ(food_index_at(&g, (Point) { 0, 5 }), -1);
    g.alive = 1;

    /* clicking one of the GAME's tokens removes it and the top-up hands back a
     * game token, so the compaction cannot quietly empty the board */
    int gi = food_index_at(&g, g.food[0].p);
    CHECK_EQ(gi, 0);
    place_or_remove(&g, g.food[0].p);
    CHECK(g.food_n >= 1);
    int any_game = 0;
    for (int i = 0; i < g.food_n; i++) if (!g.food[i].placed) any_game = 1;
    CHECK_EQ(any_game, 1);

    /* the pantry is full: MAX_FOOD tokens and not one more. MAX_FOOD is 64, so
     * this rig needs a board that can actually hold 64 distinct cells plus the
     * head — 10x6 is 60 cells and made the old collision-retry spin forever. */
    world_reset(12, 8);                            /* 96 cells: the pantry fits */
    blank_game(&g);
    set_body(&g, b, 1);
    static Point packed[MAX_FOOD];
    static int packed_placed[MAX_FOOD];
    int made = 0;
    for (int y = 0; y < BOARD_H && made < MAX_FOOD; y++)
        for (int x = 0; x < BOARD_W && made < MAX_FOOD; x++) {
            if (x == 2 && y == 2) continue;        /* the head lives there */
            if (x == 11 && y == 7) continue;       /* left empty: the probe cell */
            packed[made].x = x;
            packed[made].y = y;
            packed_placed[made] = 1;
            made++;
        }
    CHECK_EQ(made, MAX_FOOD);                      /* the rig itself must be sane */
    set_tokens(&g, packed, packed_placed, MAX_FOOD);
    CHECK_EQ(g.food_n, MAX_FOOD);
    place_or_remove(&g, (Point) { 11, 7 });        /* empty cell, but the pantry is full */
    CHECK_EQ(g.food_n, MAX_FOOD);                  /* no growth, no overwrite */
    CHECK_EQ(g.food[MAX_FOOD - 1].placed, 1);
}

/* ------------------------------------------------------------------ *
 * 12. resize preserves state
 * ------------------------------------------------------------------ */

/* Resize must never reset the game. A shrink that silently calls game_init on
 * the whole Game throws the player's run away because they nudged a window —
 * hunt/wrap/paused/alive and the snake's LENGTH survive (relocated, not
 * restarted), the player's clicked-in tokens that fell off the board are DROPPED
 * rather than teleported to somewhere nobody clicked, the game's own off-board
 * tokens are re-rolled back on, and the board is not left empty. */
static void test_shrink_preserves_state(void) {
    world_reset(20, 12);
    Game g;
    blank_game(&g);

    /* a body that runs off the board we are about to shrink to */
    static Point body[40];
    int n = 0;
    for (int i = 0; i < 9; i++) { body[n].x = i; body[n].y = 0; n++; }
    for (int i = 0; i < 9; i++) { body[n].x = 0; body[n].y = i; n++; }
    body[n].x = 3; body[n].y = 9; n++;               /* y=9: off the 6-tall board */
    body[n].x = 4; body[n].y = 10; n++;              /* and this one too */
    set_body(&g, body, n);
    g.dir[0] = 1; g.dir[1] = 0;
    g.wrap = 1; g.hunt = 1; g.paused = 1; g.alive = 1;

    /* food: one game token already off-board, one game token that will end up
     * under the relocated coil, one of the PLAYER'S off-board (dropped), one of
     * the player's on-board (must not move by so much as a cell) */
    Point f[4];
    int fp[4];
    f[0].x = 5;  f[0].y = 9;  fp[0] = 0;             /* game, off-board -> re-rolled */
    f[1].x = 3;  f[1].y = 0;  fp[1] = 0;             /* game, under the coil -> re-rolled */
    f[2].x = 11; f[2].y = 9;  fp[2] = 1;             /* player's, off-board -> DROPPED */
    f[3].x = 10; f[3].y = 4;  fp[3] = 1;             /* player's, on-board -> stays */
    set_tokens(&g, f, fp, 4);

    BOARD_W = 12;                                    /* the new, smaller board */
    BOARD_H = 6;
    sanitize_after_resize(&g);

    CHECK_EQ(g.alive, 1);
    CHECK_EQ(g.paused, 1);
    CHECK_EQ(g.wrap, 1);
    CHECK_EQ(g.hunt, 1);
    CHECK_EQ(g.started, 1);                           /* blank_game's run is still a run */
    CHECK_EQ(g.tick_ms, TICK_MS);                     /* and still at the speed it was dialled */
    CHECK_EQ(g.snake.len, n);                        /* length survived: relocated */
    for (int i = 0; i < g.snake.len; i++) {
        int idx = (g.snake.head - i + MAX_SNAKE * 2) % MAX_SNAKE;
        CHECK(in_bounds(g.snake.cells[idx]));
    }

    /* the player's surviving token is EXACTLY where they put it */
    int found_mine = 0, dropped = 0;
    for (int i = 0; i < g.food_n; i++) {
        if (g.food[i].placed) {
            CHECK_EQ(g.food[i].p.x, 10);
            CHECK_EQ(g.food[i].p.y, 4);
            found_mine++;
        }
    }
    CHECK_EQ(found_mine, 1);
    CHECK_EQ(dropped, 0);
    CHECK_EQ(food_index_at(&g, (Point) { 11, 9 }), -1);   /* teleported? no: gone */

    /* the game's own tokens are all legal again */
    for (int i = 0; i < g.food_n; i++) {
        CHECK(in_bounds(g.food[i].p));
        if (!g.food[i].placed)
            CHECK(!snake_contains(&g.snake, g.food[i].p));
    }
    CHECK(g.food_n >= 1);
}

/* The extreme shrink: a snake longer than the new board holds is capped to the
 * board rather than restarted at three cells, and a board that only ever held
 * clicked-in tokens (all of them lost to the shrink) still ends up with a game
 * token on it — otherwise the hunt AI has no seed and walks straight forever. */
static void test_shrink_caps_and_never_leaves_empty(void) {
    world_reset(20, 12);
    Game g;
    blank_game(&g);
    static Point body[120];
    int n = 0;
    for (int y = 0; y < 6 && n < 100; y++)
        for (int x = 0; x < 20 && n < 100; x++) { body[n].x = x; body[n].y = y; n++; }
    set_body(&g, body, n);                            /* off-board rows after the shrink */
    g.wrap = 1; g.hunt = 1; g.paused = 0; g.alive = 1;

    Point mine[2];
    int mp[2];
    mine[0].x = 19; mine[0].y = 11; mp[0] = 1;         /* both fall off the new board */
    mine[1].x = 18; mine[1].y = 10; mp[1] = 1;
    set_tokens(&g, mine, mp, 2);                       /* ALL of them the player's */

    BOARD_W = 10;                                       /* MIN_BOARD_W */
    BOARD_H = 6;
    sanitize_after_resize(&g);

    CHECK_EQ(g.wrap, 1);
    CHECK_EQ(g.hunt, 1);
    CHECK_EQ(g.alive, 1);
    CHECK_EQ(g.snake.len, BOARD_W * BOARD_H);           /* capped, not restarted */
    CHECK(g.snake.len > 3);
    /* the player's lost tokens are gone and a GAME token took their place */
    CHECK(g.food_n >= 1);
    int any_placed = 0, any_game = 0;
    for (int i = 0; i < g.food_n; i++) {
        CHECK(in_bounds(g.food[i].p));
        if (g.food[i].placed) any_placed++; else any_game = 1;
    }
    CHECK_EQ(any_placed, 0);
    CHECK_EQ(any_game, 1);

    /* the relocated coil must not fold over itself */
    for (int i = 0; i < g.snake.len; i++) {
        int idx = (g.snake.head - i + MAX_SNAKE * 2) % MAX_SNAKE;
        for (int j = i + 1; j < g.snake.len; j++) {
            int jdx = (g.snake.head - j + MAX_SNAKE * 2) % MAX_SNAKE;
            if (g.snake.cells[idx].x == g.snake.cells[jdx].x &&
                g.snake.cells[idx].y == g.snake.cells[jdx].y) {
                CHECK_EQ(0, 1);                          /* duplicate coil cell */
                j = g.snake.len;
            }
        }
    }
}

/* A corpse stranded outside the shrunken board just stops bleeding out. This is
 * the non-relocating branch (the snake still fits, so game_init never wipes the
 * queue), which is the only branch where the corpse-pruning loop can be seen to
 * do anything at all. */
static void test_shrink_drops_stranded_corpse(void) {
    world_reset(20, 12);
    Game g;
    blank_game(&g);
    Point b[] = {{3, 0}, {2, 0}, {1, 0}, {0, 0}};      /* all inside the new board */
    set_body(&g, b, 4);
    g.dir[0] = -1; g.dir[1] = 0;
    g.wrap = 0; g.hunt = 0; g.alive = 1;

    g.snake.wound[0].p = (Point) { 5, 1 }; g.snake.wound[0].ttl = 40;   /* stays */
    g.snake.wound[1].p = (Point) { 9, 9 }; g.snake.wound[1].ttl = 44;   /* off-board */
    g.snake.wound[2].p = (Point) { 6, 1 }; g.snake.wound[2].ttl = 0;    /* already faded */
    g.snake.wound_len = 3;

    Point f[2] = { { 8, 1 }, { 4, 5 } };
    int fp[2] = { 0, 0 };
    set_tokens(&g, f, fp, 2);

    BOARD_W = 10;
    BOARD_H = 6;
    sanitize_after_resize(&g);

    CHECK_EQ(g.snake.wound_len, 1);
    CHECK_EQ(g.snake.wound[0].p.x, 5);
    CHECK_EQ(g.snake.wound[0].p.y, 1);
    CHECK_EQ(g.snake.wound[0].ttl, 40);                 /* ttl untouched by a resize */
    CHECK(snake_occupied(&g, (Point) { 5, 1 }));
    CHECK(!snake_occupied(&g, (Point) { 9, 9 }));
    /* the snake did not move at all: it fit, so nothing was relocated */
    CHECK_EQ(g.snake.len, 4);
    CHECK_EQ(g.snake.cells[g.snake.head].x, 0);
    CHECK_EQ(g.snake.cells[g.snake.head].y, 0);
}

/* Growing the board has nothing to sanitize, so this is the "prove it does NOT
 * disturb anything" half of the resize invariant. */
static void test_grow_disturbs_nothing(void) {
    world_reset(10, 6);
    Game g;
    blank_game(&g);
    Point b[] = {{4, 3}, {3, 3}, {2, 3}};
    set_body(&g, b, 3);
    g.dir[0] = 1; g.dir[1] = 0;
    g.wrap = 1; g.hunt = 1; g.paused = 1; g.alive = 1;
    g.flash = 4;
    queue_direction(&g, 0, -1);
    queue_direction(&g, -1, 0);

    Point f[3] = { { 8, 5 }, { 0, 0 }, { 7, 1 } };
    int fp[3] = { 0, 1, 0 };
    set_tokens(&g, f, fp, 3);
    g.snake.wound[0].p = (Point) { 6, 4 }; g.snake.wound[0].ttl = 12;
    g.snake.wound_len = 1;

    Point before[MAX_SNAKE];                        /* snapshots, to diff against */
    int nbefore = g.snake.len, foodbefore = g.food_n;
    for (int i = 0; i < nbefore; i++)
        before[i] = g.snake.cells[(g.snake.head - i + MAX_SNAKE * 2) % MAX_SNAKE];
    Point fbefore[MAX_FOOD]; int fpbefore[MAX_FOOD];
    for (int i = 0; i < foodbefore; i++) { fbefore[i] = g.food[i].p; fpbefore[i] = g.food[i].placed; }
    Point wbefore = g.snake.wound[0].p; int ttlbefore = g.snake.wound[0].ttl;

    BOARD_W = 30;                                   /* grow: plenty of room */
    BOARD_H = 15;
    sanitize_after_resize(&g);

    CHECK_EQ(g.snake.len, nbefore);
    for (int i = 0; i < nbefore; i++) {
        Point now = g.snake.cells[(g.snake.head - i + MAX_SNAKE * 2) % MAX_SNAKE];
        CHECK_EQ(now.x, before[i].x);
        CHECK_EQ(now.y, before[i].y);
    }
    CHECK_EQ(g.food_n, foodbefore);
    for (int i = 0; i < foodbefore; i++) {
        CHECK_EQ(g.food[i].p.x, fbefore[i].x);
        CHECK_EQ(g.food[i].p.y, fbefore[i].y);
        CHECK_EQ(g.food[i].placed, fpbefore[i]);
    }
    CHECK_EQ(g.snake.wound_len, 1);
    CHECK_EQ(g.snake.wound[0].p.x, wbefore.x);
    CHECK_EQ(g.snake.wound[0].p.y, wbefore.y);
    CHECK_EQ(g.snake.wound[0].ttl, ttlbefore);
    CHECK_EQ(g.wrap, 1); CHECK_EQ(g.hunt, 1); CHECK_EQ(g.paused, 1);
    CHECK_EQ(g.alive, 1); CHECK_EQ(g.flash, 4);
    CHECK_EQ(g.dir[0], 1); CHECK_EQ(g.dir[1], 0);
    CHECK_EQ(g.pending_count, 2);                   /* queued turns are not thrown away */
}

/* The bug this pins cost the setup card entirely. The overlay's FIRST act is to
 * report the size it was given — {"cmd":"size"} — and when the snake did not fit
 * that board, sanitize_after_resize reached for game_init, which sets started = 1.
 * So the card's own size report pressed START for the player: the run launched at
 * the default tick rather than the dialled one and ran into a wall before a hand
 * ever touched the card, and all the QML could do was paint GAME OVER.
 * A resize is a MOVE, not a new run: the gate stays shut and the speed stays dialled. */
static void test_resize_cannot_press_start(void) {
    world_reset(30, 16);
    Game g;
    blank_game(&g);
    g.started = 0;                                  /* on the card, as --protocol leaves it */
    g.tick_ms = 100;                                /* the player dialled slow */

    /* a body long enough that it cannot fit the board the overlay is about to ask for */
    static Point body[40];
    int n = 0;
    for (int i = 0; i < 14; i++) { body[n].x = i; body[n].y = 0; n++; }
    for (int i = 1; i < 13; i++) { body[n].x = 0; body[n].y = i; n++; }
    set_body(&g, body, n);
    g.dir[0] = 1; g.dir[1] = 0;
    tokens_far(&g);

    CHECK_EQ(handle_command(&g, "{\"cmd\":\"size\",\"w\":10,\"h\":6}"), 1);
    CHECK_EQ(BOARD_W, 10);
    CHECK_EQ(BOARD_H, 6);
    CHECK_EQ(g.started, 0);                         /* the card was never cancelled */
    CHECK_EQ(g.tick_ms, 100);                       /* slow is still slow */
    CHECK_EQ(g.alive, 1);
    CHECK_EQ(g.snake.len, n);                       /* relocated, not restarted */
    for (int i = 0; i < g.snake.len; i++) {
        int idx = (g.snake.head - i + MAX_SNAKE * 2) % MAX_SNAKE;
        CHECK(in_bounds(g.snake.cells[idx]));
    }

    /* and the gate still holds after the relocation — the snake stays put on the card */
    Point still = g.snake.cells[g.snake.head];
    for (int i = 0; i < 5; i++) game_step(&g);
    CHECK_EQ(g.snake.cells[g.snake.head].x, still.x);
    CHECK_EQ(g.snake.cells[g.snake.head].y, still.y);
    CHECK_EQ(g.alive, 1);

    /* START still starts it, at the speed the player dialled and not TICK_MS */
    CHECK_EQ(handle_command(&g, "{\"cmd\":\"start\"}"), 1);
    CHECK_EQ(g.started, 1);
    CHECK_EQ(g.tick_ms, 100);
    CHECK_EQ(tick_delay_ms(&g), 100);
}

/* ------------------------------------------------------------------ *
 * 13a. the JSON codec (text in, text out — no terminal involved)
 * ------------------------------------------------------------------ */

/* Deliberately forgiving: a key that cannot be parsed is simply not a command,
 * because a half-written line from the shell must never hang or kill a live
 * game. What it must still do is REFUSE the shapes that are not the key we asked
 * for, and never run off the end of a caller's buffer. */
static void test_json_codec(void) {
    char buf[16];

    /* the happy path */
    CHECK_EQ(json_string("{\"cmd\":\"dir\"}", "cmd", buf, sizeof buf), 1);
    CHECK_STR(buf, "dir");
    CHECK_EQ(json_int("{\"dx\":1,\"dy\":-1}", "dx", &(int){ 0 }), 1);

    int v = 0;
    CHECK_EQ(json_int("{\"w\":40}", "w", &v), 1);  CHECK_EQ(v, 40);
    CHECK_EQ(json_int("{\"w\":-5}", "w", &v), 1);  CHECK_EQ(v, -5);      /* negative */
    CHECK_EQ(json_int("{\"w\":-0}", "w", &v), 1);  CHECK_EQ(v, 0);

    /* whitespace, and tabs, on either side of the colon */
    CHECK_EQ(json_string("{ \"cmd\" : \"dir\" }", "cmd", buf, sizeof buf), 1);
    CHECK_STR(buf, "dir");
    CHECK_EQ(json_string("{\t\"cmd\"\t:\t\"pause\"\t}", "cmd", buf, sizeof buf), 1);
    CHECK_STR(buf, "pause");
    CHECK_EQ(json_int("{ \"w\" : 12 }", "w", &v), 1); CHECK_EQ(v, 12);

    /* missing key */
    CHECK_EQ(json_string("{\"cmd\":\"dir\"}", "nope", buf, sizeof buf), 0);
    CHECK_EQ(json_int("{\"w\":40}", "h", &v), 0);
    /* no colon */
    CHECK_EQ(json_string("{\"cmd\" \"dir\"}", "cmd", buf, sizeof buf), 0);
    CHECK_EQ(json_int("{\"w\" 40}", "w", &v), 0);
    /* wrong type both ways */
    CHECK_EQ(json_string("{\"cmd\":5}", "cmd", buf, sizeof buf), 0);
    CHECK_EQ(json_int("{\"cmd\":\"dir\"}", "cmd", &v), 0);
    CHECK_EQ(json_int("{\"w\":\"40\"}", "w", &v), 0);
    /* nothing but junk where the number should be */
    CHECK_EQ(json_int("{\"w\":}", "w", &v), 0);
    CHECK_EQ(json_int("{\"w\":null}", "w", &v), 0);
    /* empty value is not a value */
    CHECK_EQ(json_string("{\"cmd\":\"\"}", "cmd", buf, sizeof buf), 0);

    /* trailing junk is tolerated, before AND after the value */
    CHECK_EQ(json_string("{\"cmd\":\"hunt\"}garbage", "cmd", buf, sizeof buf), 1);
    CHECK_STR(buf, "hunt");
    CHECK_EQ(json_int("{\"h\":9}junk", "h", &v), 1); CHECK_EQ(v, 9);
    CHECK_EQ(json_int("{\"h\":9abc}", "h", &v), 1); CHECK_EQ(v, 9);

    /* a short key must not be satisfied by a LONGER key that merely starts the
     * same way — the quotes are part of the needle for exactly this reason, and
     * without them `w` would read `width` and every `size` command would lie */
    CHECK_EQ(json_int("{\"cmd\":\"size\",\"width\":999,\"w\":7}", "w", &v), 1);
    CHECK_EQ(v, 7);
    CHECK_EQ(json_int("{\"cmd\":\"size\",\"w\":7,\"width\":999}", "w", &v), 1);
    CHECK_EQ(v, 7);
    CHECK_EQ(json_int("{\"cmd\":\"hunt2\",\"hunt\":1}", "hunt", &v), 1);
    CHECK_EQ(v, 1);
    CHECK_EQ(json_int("{\"cmd\":\"size\",\"wrap\":1}", "w", &v), 0);

    /* a value longer than the caller's buffer truncates instead of writing past
     * the end of it */
    char tiny[4];
    memset(tiny, 0x5a, sizeof tiny);
    CHECK_EQ(json_string("{\"cmd\":\"directionness\"}", "cmd", tiny, sizeof tiny), 1);
    CHECK_STR(tiny, "dir");
}

/* ------------------------------------------------------------------ *
 * 13b. handle_command
 * ------------------------------------------------------------------ */

/* Every branch mirrors the terminal's own key handler, so the two front-ends
 * cannot quietly grow into two different games — and every rejection has to be a
 * genuine no-op, because the overlay is a stranger typing on a pipe. */
static void test_handle_command(void) {
    Game g;

    /* dir: queues, and TAKES THE WHEEL — steering cancels auto-hunt */
    world_reset(10, 6);
    game_init(&g);
    g.hunt = 1;
    CHECK_EQ(handle_command(&g, "{\"cmd\":\"dir\",\"dx\":0,\"dy\":-1}"), 1);
    CHECK_EQ(g.hunt, 0);
    CHECK_EQ(g.pending_count, 1);
    CHECK_EQ(g.pending[0][0], 0);
    CHECK_EQ(g.pending[0][1], -1);

    /* dir: a diagonal and a zero vector are nothing — and note that they are
     * refused BEFORE hunt is cleared, so a malformed line cannot switch the AI
     * off behind the player's back */
    world_reset(10, 6);
    game_init(&g);
    g.hunt = 1;
    CHECK_EQ(handle_command(&g, "{\"cmd\":\"dir\",\"dx\":1,\"dy\":1}"), 1);
    CHECK_EQ(g.hunt, 1);
    CHECK_EQ(g.pending_count, 0);
    CHECK_EQ(handle_command(&g, "{\"cmd\":\"dir\",\"dx\":0,\"dy\":0}"), 1);
    CHECK_EQ(g.hunt, 1);
    CHECK_EQ(g.pending_count, 0);
    CHECK_EQ(handle_command(&g, "{\"cmd\":\"dir\",\"dx\":2,\"dy\":0}"), 1);
    CHECK_EQ(g.pending_count, 0);
    CHECK_EQ(handle_command(&g, "{\"cmd\":\"dir\",\"dx\":1}"), 1);   /* dy missing */
    CHECK_EQ(g.hunt, 1);
    CHECK_EQ(g.pending_count, 0);
    CHECK_EQ(handle_command(&g, "{\"cmd\":\"dir\"}"), 1);            /* both missing */
    CHECK_EQ(g.pending_count, 0);

    /* click: toggles a token and does NOT cancel hunt — a click AIMS the AI, it
     * does not take the wheel */
    world_reset(10, 6);
    game_init(&g);
    g.hunt = 1;
    int n0 = g.food_n;
    CHECK_EQ(handle_command(&g, "{\"cmd\":\"click\",\"x\":0,\"y\":0}"), 1);
    CHECK_EQ(g.food_n, n0 + 1);
    CHECK_EQ(g.food[n0].placed, 1);
    CHECK_EQ(g.hunt, 1);                                              /* still armed */
    CHECK_EQ(handle_command(&g, "{\"cmd\":\"click\",\"x\":0,\"y\":0}"), 1);
    CHECK_EQ(g.food_n, n0);                                           /* toggled back */
    CHECK_EQ(g.hunt, 1);
    /* BOARD coordinates: the overlay's grid has no border ring to subtract, so
     * the corner cell is (0,0) and the last cell is (BOARD_W-1,BOARD_H-1) */
    CHECK_EQ(handle_command(&g, "{\"cmd\":\"click\",\"x\":9,\"y\":5}"), 1);
    CHECK(food_index_at(&g, (Point) { 9, 5 }) >= 0);
    CHECK_EQ(handle_command(&g, "{\"cmd\":\"click\",\"x\":10,\"y\":5}"), 1);
    CHECK_EQ(food_index_at(&g, (Point) { 10, 5 }), -1);                /* off board */
    CHECK_EQ(handle_command(&g, "{\"cmd\":\"click\",\"x\":1}"), 1);     /* y missing */
    CHECK_EQ(food_index_at(&g, (Point) { 1, 0 }), -1);

    /* toggles, mirroring p / h (wrap moved off this block: it is a setup choice, see
     * below — an in-game `wrap` command is now refused, and asserting it toggled here
     * would be asserting the card's control back into the run) */
    world_reset(10, 6);
    game_init(&g);
    CHECK_EQ(handle_command(&g, "{\"cmd\":\"pause\"}"), 1); CHECK_EQ(g.paused, 1);
    CHECK_EQ(handle_command(&g, "{\"cmd\":\"pause\"}"), 1); CHECK_EQ(g.paused, 0);
    /* wrap BEFORE the run begins: bare form toggles, `on` is absolute */
    world_reset(10, 6);
    game_init(&g);
    g.started = 0;
    CHECK_EQ(handle_command(&g, "{\"cmd\":\"wrap\"}"), 1);  CHECK_EQ(g.wrap, 1);
    CHECK_EQ(handle_command(&g, "{\"cmd\":\"wrap\"}"), 1);  CHECK_EQ(g.wrap, 0);
    CHECK_EQ(handle_command(&g, "{\"cmd\":\"wrap\",\"on\":1}"), 1); CHECK_EQ(g.wrap, 1);
    CHECK_EQ(handle_command(&g, "{\"cmd\":\"wrap\",\"on\":1}"), 1); CHECK_EQ(g.wrap, 1);
    CHECK_EQ(handle_command(&g, "{\"cmd\":\"wrap\",\"on\":0}"), 1); CHECK_EQ(g.wrap, 0);
    /* a nonsense `on` falls back to toggling rather than silently doing nothing */
    CHECK_EQ(handle_command(&g, "{\"cmd\":\"wrap\",\"on\":7}"), 1); CHECK_EQ(g.wrap, 1);
    /* and once started, wrap is locked — the engine, not the QML, is the guard */
    g.started = 1;
    CHECK_EQ(handle_command(&g, "{\"cmd\":\"wrap\"}"), 1);  CHECK_EQ(g.wrap, 1);
    CHECK_EQ(handle_command(&g, "{\"cmd\":\"wrap\",\"on\":0}"), 1); CHECK_EQ(g.wrap, 1);
    queue_direction(&g, 0, -1);
    CHECK_EQ(handle_command(&g, "{\"cmd\":\"hunt\"}"), 1);  CHECK_EQ(g.hunt, 1);
    CHECK_EQ(g.pending_count, 0);                          /* h drops the queue, like 'h' */
    CHECK_EQ(handle_command(&g, "{\"cmd\":\"hunt\"}"), 1); CHECK_EQ(g.hunt, 0);

    /* pause is refused when dead: no pause menu underneath the game-over one */
    world_reset(10, 6);
    game_init(&g);
    g.alive = 0;
    handle_command(&g, "{\"cmd\":\"pause\"}");
    CHECK_EQ(g.paused, 0);

    /* restart wipes the board AND banks the run before doing it */
    world_reset(10, 6);
    game_init(&g);
    protocol_mode = 1;                                     /* banks, never writes */
    static Point long_body[30];
    for (int i = 0; i < 30; i++) { long_body[i].x = i % BOARD_W; long_body[i].y = (i / BOARD_W); }
    set_body(&g, long_body, 30);
    CHECK_EQ(handle_command(&g, "{\"cmd\":\"restart\"}"), 1);
    CHECK_EQ(best_len, 30);                                /* the run is banked */
    CHECK_EQ(pending_best, 30);
    CHECK_EQ(g.snake.len, 3);                              /* a fresh game */
    CHECK_EQ(g.food_n, FOOD_COUNT);
    CHECK_EQ(g.alive, 1);
    CHECK_EQ(g.pending_count, 0);
    protocol_mode = 0;

    /* size: clamped at both ends, and it sanitizes rather than resets */
    world_reset(10, 6);
    game_init(&g);
    g.hunt = 1; g.wrap = 1;
    CHECK_EQ(handle_command(&g, "{\"cmd\":\"size\",\"w\":1,\"h\":1}"), 1);
    CHECK_EQ(BOARD_W, MIN_BOARD_W);
    CHECK_EQ(BOARD_H, MIN_BOARD_H);
    CHECK_EQ(g.hunt, 1);                                   /* preserved, not reset */
    CHECK_EQ(g.wrap, 1);
    CHECK_EQ(g.alive, 1);
    CHECK_EQ(g.snake.len, 3);
    CHECK_EQ(handle_command(&g, "{\"cmd\":\"size\",\"w\":99999,\"h\":99999}"), 1);
    CHECK_EQ(BOARD_W, MAX_BOARD_W);                         /* the BFS caps ARE the cap */
    CHECK_EQ(BOARD_H, MAX_BOARD_H);
    CHECK_EQ(handle_command(&g, "{\"cmd\":\"size\",\"w\":-300,\"h\":-300}"), 1);
    CHECK_EQ(BOARD_W, MIN_BOARD_W);
    CHECK_EQ(BOARD_H, MIN_BOARD_H);
    CHECK_EQ(handle_command(&g, "{\"cmd\":\"size\",\"w\":24,\"h\":12}"), 1);
    CHECK_EQ(BOARD_W, 24);
    CHECK_EQ(BOARD_H, 12);
    CHECK_EQ(handle_command(&g, "{\"cmd\":\"size\",\"w\":24}"), 1);   /* h missing */
    CHECK_EQ(BOARD_W, 24);
    CHECK_EQ(BOARD_H, 12);

    /* unknown cmd, no cmd at all, and junk: ignored, state untouched, still alive */
    world_reset(10, 6);
    game_init(&g);
    g.hunt = 1; g.wrap = 1; g.paused = 0; g.dir[0] = 1; g.dir[1] = 0;
    int keep_len = g.snake.len, keep_food = g.food_n;
    Point keep_head = g.snake.cells[g.snake.head];
    CHECK_EQ(handle_command(&g, "{\"cmd\":\"selfdestruct\"}"), 1);
    CHECK_EQ(g.hunt, 1); CHECK_EQ(g.wrap, 1); CHECK_EQ(g.paused, 0);
    CHECK_EQ(g.alive, 1); CHECK_EQ(g.snake.len, keep_len); CHECK_EQ(g.food_n, keep_food);
    CHECK_EQ(g.snake.cells[g.snake.head].x, keep_head.x);
    CHECK_EQ(handle_command(&g, "{\"tick\":1,\"w\":2}"), 1);          /* no cmd key */
    CHECK_EQ(g.hunt, 1); CHECK_EQ(BOARD_W, 10); CHECK_EQ(BOARD_H, 6);
    CHECK_EQ(g.snake.len, keep_len); CHECK_EQ(g.food_n, keep_food);
    CHECK_EQ(handle_command(&g, ""), 1);                              /* blank line */
    CHECK_EQ(handle_command(&g, "total garbage {{{"), 1);
    CHECK_EQ(handle_command(&g, "{\"cmd\":\"\"}"), 1);                /* empty cmd */
    CHECK_EQ(g.alive, 1); CHECK_EQ(g.snake.len, keep_len);
    CHECK_EQ(g.hunt, 1); CHECK_EQ(g.wrap, 1);
    CHECK_EQ(handle_command(&g, "{\"cmd\":\"dir\",\"dx\":\"up\"}"), 1);
    CHECK_EQ(g.hunt, 1);                                                /* not refused-parse */
    CHECK_EQ(g.pending_count, 0);

    /* quit stops the engine and banks, flush writes nothing of its own accord */
    world_reset(10, 6);
    game_init(&g);
    protocol_mode = 1;
    static Point q[12];
    for (int i = 0; i < 12; i++) { q[i].x = i; q[i].y = 0; }
    set_body(&g, q, 12);
    CHECK_EQ(handle_command(&g, "{\"cmd\":\"quit\"}"), 0);
    CHECK_EQ(best_len, 12);
    CHECK_EQ(pending_best, 0);                                   /* flush_state consumed it */
    protocol_mode = 0;
}

/* ------------------------------------------------------------------ *
 * 13c. emit_frame — one JSON object per line, read back with the engine's own
 *      reader. This grades a text format, not a screen.
 * ------------------------------------------------------------------ */

static long frame_no;

/* Point stdout at a scratch file, emit, hand the bytes back. Nothing here
 * interprets escape sequences or pretends to be a terminal: the frame is the
 * engine's own output and it is parsed with the engine's own json_int/json_string. */
static int capture_frame(const Game *g, long tick, char *out, size_t outsz) {
    char *path = scratch_path("frame.json");
    fflush(stdout);
    int keep_fd = dup(fileno(stdout));
    if (keep_fd < 0) return 0;
    if (!freopen(path, "w", stdout)) { dup2(keep_fd, fileno(stdout)); close(keep_fd); return 0; }
    int ok = emit_frame(g, tick);
    fflush(stdout);
    dup2(keep_fd, fileno(stdout));                                /* put the terminal back */
    close(keep_fd);
    (void) frame_no;
    return ok && read_file(path, out, outsz);
}

/* Pull one array field out of a frame: "wound":[...] -> the text between brackets. */
static int json_array(const char *hay, const char *key, char *out, size_t outsz) {
    char pat[32];
    snprintf(pat, sizeof pat, "\"%s\":[", key);
    const char *p = strstr(hay, pat);
    if (!p) { out[0] = 0; return 0; }
    p += strlen(pat);
    const char *end = strchr(p, ']');
    if (!end) { out[0] = 0; return 0; }
    size_t n = (size_t) (end - p);
    if (n + 1 > outsz) n = outsz - 1;
    memcpy(out, p, n);
    out[n] = 0;
    return 1;
}

/* How many {"x":... objects sit in an array body. */
static int count_cells(const char *arr) {
    int n = 0;
    for (const char *q = arr; *q; q++)
        if (strncmp(q, "{\"x\":", 5) == 0) n++;
    return n;
}

static void test_emit_frame(void) {
    world_reset(12, 8);
    Game g;
    blank_game(&g);
    /* set_body wants the literal TAIL FIRST, head last — written the other way
     * round the rig runs backwards and the frame reports head (3,4). */
    Point b[] = {{3, 4}, {4, 4}, {5, 4}, {6, 4}};                  /* head (6,4) */
    set_body(&g, b, 4);
    g.dir[0] = 1; g.dir[1] = 0;
    g.wrap = 1; g.hunt = 1; g.paused = 0; g.alive = 1; g.flash = 7;
    /* a run the player tuned: 33 ms and begun. Both must reach the card, or the
     * slider thumb and the START button are painting from numbers that do not exist */
    g.tick_ms = 33; g.started = 1;
    best_len = 23;
    Point f[3] = { { 1, 1 }, { 10, 6 }, { 2, 5 } };
    int fp[3] = { 0, 1, 0 };
    set_tokens(&g, f, fp, 3);
    /* a live corpse and an already-expired one: only the live one may be sent */
    g.snake.wound[0].p = (Point) { 8, 2 }; g.snake.wound[0].ttl = 9;
    g.snake.wound[1].p = (Point) { 9, 3 }; g.snake.wound[1].ttl = 0;
    g.snake.wound_len = 2;

    char frame[8192];
    CHECK_EQ(capture_frame(&g, 17, frame, sizeof frame), 1);

    /* ONE line, ending in \n — NDJSON means the reader can take a line at a time */
    long newlines = 0;
    for (char *p = frame; *p; p++) if (*p == '\n') newlines++;
    CHECK_EQ(newlines, 1);
    size_t flen = strlen(frame);
    CHECK_EQ(frame[flen - 1], '\n');

    /* every scalar the overlay paints from, parsed back with the engine's reader */
    int v = -1;
    CHECK_EQ(json_int(frame, "tick", &v), 1);  CHECK_EQ(v, 17);
    CHECK_EQ(json_int(frame, "w", &v), 1);     CHECK_EQ(v, BOARD_W);
    CHECK_EQ(json_int(frame, "h", &v), 1);     CHECK_EQ(v, BOARD_H);
    CHECK_EQ(json_int(frame, "alive", &v), 1); CHECK_EQ(v, g.alive);
    CHECK_EQ(json_int(frame, "paused", &v), 1); CHECK_EQ(v, g.paused);
    CHECK_EQ(json_int(frame, "wrap", &v), 1);  CHECK_EQ(v, g.wrap);
    CHECK_EQ(json_int(frame, "hunt", &v), 1);  CHECK_EQ(v, g.hunt);
    CHECK_EQ(json_int(frame, "started", &v), 1); CHECK_EQ(v, 1);
    CHECK_EQ(json_int(frame, "speed", &v), 1);  CHECK_EQ(v, 33);
    CHECK_EQ(json_int(frame, "flash", &v), 1); CHECK_EQ(v, 7);
    CHECK_EQ(json_int(frame, "best", &v), 1);  CHECK_EQ(v, 23);
    char ev[16];
    CHECK_EQ(json_string(frame, "event", ev, sizeof ev), 1);
    CHECK_STR(ev, "frame");
    /* the head, first — and the first "x" in the line is head's, so the reader
     * agrees with the writer about where the body starts */
    CHECK_EQ(json_int(frame, "x", &v), 1);     CHECK_EQ(v, 6);
    CHECK_EQ(json_int(frame, "y", &v), 1);     CHECK_EQ(v, 4);

    /* the body: live length, head FIRST, matching the order draw() walks the ring */
    char arr[4096];
    CHECK_EQ(json_array(frame, "body", arr, sizeof arr), 1);
    CHECK_EQ(count_cells(arr), g.snake.len);
    CHECK(holds(frame, "\"body\":[{\"x\":6,\"y\":4},{\"x\":5,\"y\":4},"
                       "{\"x\":4,\"y\":4},{\"x\":3,\"y\":4}]"));

    /* the corpse array: expired one left OUT, not sent as ttl 0 — a ttl-0 wall
     * would have the AI steering around a cell that is not there any more */
    CHECK_EQ(json_array(frame, "wound", arr, sizeof arr), 1);
    CHECK_EQ(count_cells(arr), 1);
    CHECK(holds(arr, "{\"x\":8,\"y\":2,\"ttl\":9}"));
    CHECK(!holds(arr, "{\"x\":9,\"y\":3"));
    CHECK(!holds(arr, "\"ttl\":0"));

    /* food: the player's token round-trips its `placed` flag — that flag is what
     * decides whether eating it spends it or respawns it */
    CHECK_EQ(json_array(frame, "food", arr, sizeof arr), 1);
    CHECK_EQ(count_cells(arr), 3);
    CHECK(holds(arr, "{\"x\":1,\"y\":1,\"placed\":0}"));
    CHECK(holds(arr, "{\"x\":10,\"y\":6,\"placed\":1}"));
    CHECK(holds(arr, "{\"x\":2,\"y\":5,\"placed\":0}"));

    /* a dead run still emits: the overlay has to be able to show game-over */
    g.alive = 0;
    CHECK_EQ(capture_frame(&g, 18, frame, sizeof frame), 1);
    CHECK_EQ(json_int(frame, "alive", &v), 1); CHECK_EQ(v, 0);
    CHECK(holds(frame, "{\"event\":\"frame\""));
}

/* ------------------------------------------------------------------ *
 * 13d. save-data discipline
 * ------------------------------------------------------------------ */

/* Under --protocol the engine is the ONLY writer of the best-length file, and it
 * writes the moment the record is BEATEN. That is the rule that replaced "bank it in
 * RAM and let flush_state() write it when the panel closes", and the reason is the bug
 * Brodie reported: an engine the shell never told to stop — SIGKILL, a shell crash, an
 * orphan left by a plugin reload — died holding a record that existed nowhere else, and
 * the next summon read the old file. The old fear (a write during play reloads the
 * overlay) died with the plugin-folder path: the watcher is `inotifywait -r` over
 * ~/.config/omarchy/plugins ONLY (services/PluginRegistry.qml:663), and the state file
 * lives under ~/.local/state. flush_state() still exists, and still has a job. */
static void test_save_data_discipline(void) {
    Game g;
    char content[64];

    /* protocol mode: forty grows, and the record is on disk while the game is LIVE —
     * this is the assertion that failed before the fix, and it is the whole bug */
    world_reset(10, 6);
    protocol_mode = 1;
    snprintf(state_path, sizeof state_path, "%s/nested/deeper/highscore", run_dir);
    CHECK(!file_exists(state_path));
    blank_game(&g);
    Point b[40];
    for (int i = 0; i < 40; i++) { b[i].x = i % BOARD_W; b[i].y = i / BOARD_W; }
    for (int len = 1; len <= 40; len++) {
        set_body(&g, b, len);
        save_highscore(len);                       /* beats the record: goes to disk */
    }
    CHECK(file_exists(state_path));
    CHECK(read_file(state_path, content, sizeof content));
    CHECK_STR(content, "40\n");
    /* ensure_parent_dir built the whole chain — the point of naming a folder a fresh
     * checkout does not have yet. (It cannot mean run_dir itself: main() mkdir's that
     * before the first suite runs, so asking about it reports the harness, not the code.) */
    char nested[512];
    snprintf(nested, sizeof nested, "%s/nested", run_dir);
    CHECK(file_exists(nested));
    snprintf(nested, sizeof nested, "%s/nested/deeper", run_dir);
    CHECK(file_exists(nested));
    CHECK_EQ(best_len, 40);                        /* and it is in memory too, for frames */
    CHECK_EQ(pending_best, 40);

    /* one write per new record, not one per tick: the saves that DO NOT beat the record
     * must not touch the file at all, or every 55 ms would be an open()/write() */
    for (int i = 0; i < 200; i++) save_highscore(40);       /* equal is not better */
    CHECK(read_file(state_path, content, sizeof content));
    CHECK_STR(content, "40\n");

    /* flush_state still clears the bank, and still has the last word */
    flush_state();
    CHECK(file_exists(state_path));
    CHECK(read_file(state_path, content, sizeof content));
    CHECK_STR(content, "40\n");
    CHECK_EQ(pending_best, 0);

    /* a smaller later run must not shrink or rewrite the file */
    set_body(&g, b, 5);
    save_highscore(5);
    flush_state();
    CHECK(read_file(state_path, content, sizeof content));
    CHECK_STR(content, "40\n");
    /* nor may a flush of nothing rewrite it */
    flush_state();
    CHECK(read_file(state_path, content, sizeof content));
    CHECK_STR(content, "40\n");
    /* a bigger one does */
    set_body(&g, b, 41);
    save_highscore(41);
    flush_state();
    CHECK(read_file(state_path, content, sizeof content));
    CHECK_STR(content, "41\n");
    CHECK_EQ(best_len, 41);

    /* the contrast that makes the above mean something: outside protocol mode a
     * save writes immediately, on death / restart / quit */
    protocol_mode = 0;
    snprintf(state_path, sizeof state_path, "%s/term_highscore", run_dir);
    unlink(state_path);
    save_highscore(17);
    CHECK(file_exists(state_path));
    CHECK(read_file(state_path, content, sizeof content));
    CHECK_STR(content, "17\n");
    /* and it only ever writes UP */
    save_highscore(3);
    CHECK(read_file(state_path, content, sizeof content));
    CHECK_STR(content, "17\n");
    save_highscore(25);
    CHECK(read_file(state_path, content, sizeof content));
    CHECK_STR(content, "25\n");

    /* the state file only counts as state when it is a plain regular file of a
     * sane size: lstat, not stat, so a symlink is refused rather than followed */
    char *victim = scratch_path("victim");
    FILE *vf = fopen(victim, "w");
    if (vf) { fprintf(vf, "999\n"); fclose(vf); }
    char *link = scratch_path("link_to_victim");
    unlink(link);
    CHECK_EQ(symlink(victim, link), 0);
    snprintf(state_path, sizeof state_path, "%s", link);
    int best = 12345;
    load_highscore(&best);
    CHECK_EQ(best, 0);                             /* refused: not a regular file */
    write_best_file(500);                          /* O_NOFOLLOW: must not go through */
    CHECK(read_file(victim, content, sizeof content));
    CHECK_STR(content, "999\n");                   /* the target was not clobbered */
    struct stat st;
    CHECK_EQ(lstat(link, &st), 0);
    CHECK(S_ISLNK(st.st_mode));                    /* and the link is still a link */
    CHECK_EQ(atoi(content), 999);

    /* a planted or corrupted file is refused too: empty, or bigger than a number */
    char *bogus = scratch_path("bogus_highscore");
    FILE *bf = fopen(bogus, "w");
    if (bf) { fclose(bf); }
    snprintf(state_path, sizeof state_path, "%s", bogus);
    best = 7;
    load_highscore(&best);
    CHECK_EQ(best, 0);                             /* empty file: size must be > 0 */
    bf = fopen(bogus, "w");
    if (bf) { for (int i = 0; i < 40; i++) fprintf(bf, "1234567890"); fclose(bf); }
    best = 7;
    load_highscore(&best);
    CHECK_EQ(best, 0);                             /* 400 bytes is not a high score */
    bf = fopen(bogus, "w");
    if (bf) { fprintf(bf, "not a number\n"); fclose(bf); }
    best = 7;
    load_highscore(&best);
    CHECK_EQ(best, 0);

    /* a readable file round-trips, and a missing one reads as zero rather than
     * leaving whatever the caller passed in */
    bf = fopen(bogus, "w");
    if (bf) { fprintf(bf, "13\n"); fclose(bf); }
    best = 7;
    load_highscore(&best);
    CHECK_EQ(best, 13);
    unlink(bogus);
    best = 7;
    load_highscore(&best);
    CHECK_EQ(best, 0);

    /* --state may name a folder the plugin checkout does not have yet */
    protocol_mode = 0;
    snprintf(state_path, sizeof state_path, "%s/made/by/ensure/parent", run_dir);
    write_best_file(9);
    CHECK(file_exists(state_path));
    CHECK(read_file(state_path, content, sizeof content));
    CHECK_STR(content, "9\n");
}

/* ------------------------------------------------------------------ *
 * 13e. the setup card persists
 * ------------------------------------------------------------------ */

/* WRAP and SPEED are two integers in a file beside the high score, written the moment
 * the player changes one and read back before the first frame — so a re-summon shows
 * the card as they left it, with no storage in QML and no second opinion anywhere. The
 * cases that matter are the ones where the file is wrong: a settings file must never be
 * able to hand the game a busy-spinning tick, a frozen one, or a target for a planted
 * symlink. */
static void test_setup_persists(void) {
    char content[64];
    int wrap = 9, ms = 9;

    /* round trip, in a directory that does not exist yet (a fresh checkout), and the
     * format is exactly two integers plus a newline */
    world_reset(20, 12);
    setup_path[0] = 0;
    snprintf(setup_path, sizeof setup_path, "%s/made/by/save/setup", run_dir);
    save_setup(1, 30);
    CHECK(file_exists(setup_path));
    CHECK(read_file(setup_path, content, sizeof content));
    CHECK_STR(content, "1 30\n");
    load_setup(&wrap, &ms);
    CHECK_EQ(wrap, 1);
    CHECK_EQ(ms, 30);

    /* absent: not an error, and the caller's garbage in-outs are replaced by the card's
     * real defaults rather than trusted */
    unlink(setup_path);
    load_setup(&wrap, &ms);
    CHECK_EQ(wrap, 0);
    CHECK_EQ(ms, TICK_MS);

    /* each guard stands on its own: a legal wrap with an absurd tick keeps the wrap and
     * refuses the tick, and vice versa */
    char *bad = scratch_path("setup_bad");
    FILE *f = fopen(bad, "w");
    if (f) { fprintf(f, "1 400000\n"); fclose(f); }
    snprintf(setup_path, sizeof setup_path, "%s", bad);
    load_setup(&wrap, &ms);
    CHECK_EQ(wrap, 1);
    CHECK_EQ(ms, TICK_MS);                          /* frozen tick refused */
    f = fopen(bad, "w");
    if (f) { fprintf(f, "7 25\n"); fclose(f); }
    load_setup(&wrap, &ms);
    CHECK_EQ(wrap, 0);                              /* nonsense wrap refused */
    CHECK_EQ(ms, 25);
    /* too fast is as unbuildable as too slow: MIN_TICK_MS is a guard, not a suggestion */
    f = fopen(bad, "w");
    if (f) { fprintf(f, "1 1\n"); fclose(f); }
    load_setup(&wrap, &ms);
    CHECK_EQ(ms, TICK_MS);
    /* junk, empty, and a planted 400-byte file all read as defaults */
    f = fopen(bad, "w");
    if (f) { fprintf(f, "not a setup\n"); fclose(f); }
    load_setup(&wrap, &ms);
    CHECK_EQ(wrap, 0); CHECK_EQ(ms, TICK_MS);
    f = fopen(bad, "w");
    if (f) { fclose(f); }
    load_setup(&wrap, &ms);
    CHECK_EQ(wrap, 0); CHECK_EQ(ms, TICK_MS);
    f = fopen(bad, "w");
    if (f) { for (int i = 0; i < 40; i++) fprintf(f, "1111111111"); fclose(f); }
    load_setup(&wrap, &ms);
    CHECK_EQ(ms, TICK_MS);                          /* 400 bytes is not a setup */

    /* symlink: lstat refuses it, the target is untouched, and the link stays a link */
    char *victim = scratch_path("setup_victim");
    FILE *vf = fopen(victim, "w");
    if (vf) { fprintf(vf, "keep me\n"); fclose(vf); }
    char *link = scratch_path("setup_link");
    unlink(link);
    CHECK_EQ(symlink(victim, link), 0);
    snprintf(setup_path, sizeof setup_path, "%s", link);
    load_setup(&wrap, &ms);
    CHECK_EQ(wrap, 0); CHECK_EQ(ms, TICK_MS);
    save_setup(1, 40);                              /* O_NOFOLLOW: must not go through */
    CHECK(read_file(victim, content, sizeof content));
    CHECK_STR(content, "keep me\n");
    struct stat st;
    CHECK_EQ(lstat(link, &st), 0);
    CHECK(S_ISLNK(st.st_mode));

    /* the commands write it — with the value the ENGINE settled on, not the one the
     * client asked for, so a poisoned pipe cannot write tomorrow's card */
    Game g;
    world_reset(20, 12);
    blank_game(&g);
    g.started = 0;
    snprintf(setup_path, sizeof setup_path, "%s/setup_cmds", run_dir);
    unlink(setup_path);
    CHECK_EQ(handle_command(&g, "{\"cmd\":\"wrap\",\"on\":1}"), 1);
    CHECK_EQ(handle_command(&g, "{\"cmd\":\"speed\",\"ms\":99999}"), 1);
    CHECK(read_file(setup_path, content, sizeof content));
    CHECK_STR(content, "1 200\n");                  /* 200 == MAX_TICK_MS, the clamp */
    load_setup(&wrap, &ms);
    CHECK_EQ(wrap, 1);
    CHECK_EQ(ms, MAX_TICK_MS);

    /* after START both are refused, and a refused edit must NOT rewrite the file with
     * the setting the player did not get — that would be a card that lies next time */
    CHECK_EQ(handle_command(&g, "{\"cmd\":\"start\"}"), 1);
    CHECK_EQ(handle_command(&g, "{\"cmd\":\"wrap\",\"on\":0}"), 1);
    CHECK_EQ(handle_command(&g, "{\"cmd\":\"speed\",\"ms\":20}"), 1);
    CHECK_EQ(g.wrap, 1);
    CHECK_EQ(g.tick_ms, MAX_TICK_MS);
    CHECK(read_file(setup_path, content, sizeof content));
    CHECK_STR(content, "1 200\n");

    /* and a game_init cannot wipe them: restart keeps the setup, so the file the card
     * was built from still matches the run being replayed */
    CHECK_EQ(handle_command(&g, "{\"cmd\":\"restart\"}"), 1);
    CHECK_EQ(g.wrap, 1);
    CHECK_EQ(g.tick_ms, MAX_TICK_MS);
    setup_path[0] = 0;
}

/* ------------------------------------------------------------------ *
 * 14. the input queue
 * ------------------------------------------------------------------ */

/* The 4-deep pending queue is what makes a key mash feel right: two arrows
 * pressed inside one tick both land, in order, and neither can reverse the snake
 * into itself. The filtering is relative to the LAST QUEUED move, not to the
 * direction the snake happens to be travelling — otherwise a queued-up turn would
 * cancel a legal turn behind it and a mash would silently lose commands. */
static void test_input_queue(void) {
    Game g;
    world_reset(10, 6);
    blank_game(&g);
    Point b[] = {{2, 2}};
    set_body(&g, b, 1);
    tokens_far(&g);
    g.dir[0] = 1; g.dir[1] = 0;
    g.wrap = 1;

    /* four turns fit and a fifth does not */
    queue_direction(&g, 0, -1);
    queue_direction(&g, 1, 0);          /* a repeat of dir is fine: it is not a
                                           repeat of the last QUEUED move */
    queue_direction(&g, 0, 1);
    queue_direction(&g, -1, 0);
    CHECK_EQ(g.pending_count, INPUT_QUEUE_SIZE);
    queue_direction(&g, 0, -1);         /* legal in itself, but the queue is full */
    CHECK_EQ(g.pending_count, INPUT_QUEUE_SIZE);
    CHECK_EQ(g.pending_count, 4);
    /* FIFO order, read as the ring the game drains it from */
    static const int want_dx[4] = { 0, 1, 0, -1 };
    static const int want_dy[4] = { -1, 0, 1, 0 };
    for (int i = 0; i < 4; i++) {
        int idx = (g.pending_head + i) % INPUT_QUEUE_SIZE;
        CHECK_EQ(g.pending[idx][0], want_dx[i]);
        CHECK_EQ(g.pending[idx][1], want_dy[i]);
    }

    /* exact repeats and exact reversals are dropped against the LAST QUEUED
     * move — not against the current direction */
    world_reset(10, 6);
    blank_game(&g);
    set_body(&g, b, 1);
    tokens_far(&g);
    g.dir[0] = 1; g.dir[1] = 0; g.wrap = 1;
    queue_direction(&g, 0, -1);
    queue_direction(&g, 0, -1);                       /* exact repeat: dropped */
    CHECK_EQ(g.pending_count, 1);
    queue_direction(&g, 0, 1);                        /* reversal of the queued turn */
    CHECK_EQ(g.pending_count, 1);
    queue_direction(&g, -1, 0);                       /* reversal of CURRENT dir, but
                                                         legal behind a queued turn */
    CHECK_EQ(g.pending_count, 2);
    CHECK_EQ(g.pending[(g.pending_head + 1) % INPUT_QUEUE_SIZE][0], -1);
    CHECK_EQ(g.pending[(g.pending_head + 1) % INPUT_QUEUE_SIZE][1], 0);
    /* Right now the queue holds (0,-1),(-1,0) and dir is still (1,0). Queueing
     * (1,0) HERE would be a straight self-reversal — it is the exact reverse of
     * the LAST QUEUED move, (-1,0), one tick behind it — and queue_direction
     * drops it. That rejection is the rule, not a bug, so assert it first. */
    queue_direction(&g, 1, 0);
    CHECK_EQ(g.pending_count, 2);                     /* reversal of the queued move */
    /* Now the same current direction, with a different move behind it: (0,1) is
     * neither a repeat nor a reversal of (-1,0), it goes in, and with (0,1) the
     * last queued move, (1,0) is neither a repeat nor a reversal of THAT either.
     * Pressing the direction the snake is already travelling is therefore not a
     * no-op when the last queued move was something else. */
    queue_direction(&g, 0, 1);
    CHECK_EQ(g.pending_count, 3);
    queue_direction(&g, 1, 0);
    CHECK_EQ(g.pending_count, 4);
    CHECK_EQ(g.pending[(g.pending_head + 3) % INPUT_QUEUE_SIZE][0], 1);
    CHECK_EQ(g.pending[(g.pending_head + 3) % INPUT_QUEUE_SIZE][1], 0);

    /* it drains FIFO, one command per tick, and the snake follows */
    world_reset(10, 6);
    blank_game(&g);
    Point straight[] = {{0, 2}, {1, 2}, {2, 2}};
    set_body(&g, straight, 3);
    tokens_far(&g);
    g.dir[0] = 1; g.dir[1] = 0; g.wrap = 1;
    queue_direction(&g, 0, -1);
    queue_direction(&g, -1, 0);
    CHECK_EQ(g.pending_count, 2);
    game_step(&g);
    CHECK_EQ(g.dir[0], 0); CHECK_EQ(g.dir[1], -1);     /* first command applied */
    CHECK_EQ(g.pending_count, 1);
    game_step(&g);
    CHECK_EQ(g.dir[0], -1); CHECK_EQ(g.dir[1], 0);     /* second one, in order */
    CHECK_EQ(g.pending_count, 0);
    game_step(&g);
    CHECK_EQ(g.pending_count, 0);                       /* draining empty is inert */
    CHECK_EQ(g.alive, 1);

    /* hunt takes the wheel: a tick with hunt armed throws the queued turns away */
    g.hunt = 1;
    queue_direction(&g, 0, 1);
    CHECK_EQ(g.pending_count, 1);
    game_step(&g);
    CHECK_EQ(g.pending_count, 0);
}

/* ------------------------------------------------------------------ *
 * 16. the run begins when the card says so
 * ------------------------------------------------------------------ */

/* The setup card is a GATE, and a gate is only real if the engine holds it shut:
 * before START the snake cannot be stepped, steered, paused, hunted, or re-tuned,
 * and after START wrap and speed are frozen. Both halves are asserted through the
 * same handle_command / game_step pair the overlay drives down a pipe — the card in
 * QML is decoration until this is true. */
static void test_the_run_begins_when_told(void) {
    Game g;

    /* game_init hands over a run that is READY to play: the curses face never sees
     * started == 0, only --protocol puts it back on the card */
    world_reset(10, 6);
    game_init(&g);
    CHECK_EQ(g.started, 1);
    CHECK_EQ(g.tick_ms, TICK_MS);
    CHECK_EQ(tick_delay_ms(&g), TICK_MS);

    /* an unstarted run does not move — five ticks and the head has not stirred */
    world_reset(10, 6);
    blank_game(&g);
    Point row[] = { { 2, 2 }, { 1, 2 }, { 0, 2 } };
    set_body(&g, row, 3);
    g.started = 0;
    g.dir[0] = 1; g.dir[1] = 0;
    tokens_far(&g);
    Point still = g.snake.cells[g.snake.head];
    for (int i = 0; i < 5; i++) game_step(&g);
    CHECK_EQ(g.snake.cells[g.snake.head].x, still.x);
    CHECK_EQ(g.snake.cells[g.snake.head].y, still.y);
    CHECK_EQ(g.snake.len, 3);
    CHECK_EQ(g.alive, 1);

    /* the commands that steer a run are refused while it has not begun: the ENGINE
     * refuses them, so a QML bug — or a hand-written line on the pipe — cannot get
     * the snake moving early */
    CHECK_EQ(handle_command(&g, "{\"cmd\":\"dir\",\"dx\":0,\"dy\":1}"), 1);
    CHECK_EQ(g.pending_count, 0);
    CHECK_EQ(handle_command(&g, "{\"cmd\":\"hunt\"}"), 1);
    CHECK_EQ(g.hunt, 0);
    CHECK_EQ(handle_command(&g, "{\"cmd\":\"pause\"}"), 1);
    CHECK_EQ(g.paused, 0);

    /* the setup itself IS editable here, and clamped at both ends: 0 ms would be a
     * busy-spinning loop, 100000 ms would read as a frozen game */
    CHECK_EQ(handle_command(&g, "{\"cmd\":\"speed\",\"ms\":0}"), 1);
    CHECK_EQ(g.tick_ms, MIN_TICK_MS);
    CHECK_EQ(handle_command(&g, "{\"cmd\":\"speed\",\"ms\":100000}"), 1);
    CHECK_EQ(g.tick_ms, MAX_TICK_MS);
    CHECK_EQ(handle_command(&g, "{\"cmd\":\"speed\",\"ms\":40}"), 1);
    CHECK_EQ(g.tick_ms, 40);
    CHECK_EQ(tick_delay_ms(&g), 40);
    CHECK_EQ(handle_command(&g, "{\"cmd\":\"speed\"}"), 1);          /* no ms at all */
    CHECK_EQ(g.tick_ms, 40);

    /* clicks ARE allowed before START: placing a token aims the AI, it does not steer */
    int n0 = g.food_n;
    CHECK_EQ(handle_command(&g, "{\"cmd\":\"click\",\"x\":9,\"y\":5}"), 1);
    CHECK_EQ(g.food_n, n0 + 1);

    /* START means go — never "go, but paused" — and it arrives with a clean queue, so
     * a direction leaned before the run began cannot launch it sideways */
    queue_direction(&g, 0, -1);
    g.paused = 1;
    CHECK_EQ(handle_command(&g, "{\"cmd\":\"start\"}"), 1);
    CHECK_EQ(g.started, 1);
    CHECK_EQ(g.paused, 0);
    CHECK_EQ(g.pending_count, 0);

    /* and now the same step that did nothing moves the snake */
    world_reset(10, 6);
    blank_game(&g);
    set_body(&g, row, 3);
    g.started = 0;
    g.dir[0] = 1; g.dir[1] = 0;
    tokens_far(&g);
    still = g.snake.cells[g.snake.head];
    handle_command(&g, "{\"cmd\":\"start\"}");
    game_step(&g);
    CHECK(g.snake.cells[g.snake.head].x != still.x);

    /* in-game the speed and the walls are DECIDED: the card's controls are gone for a
     * reason, and this is what makes "you cannot change wrap or speed mid-run" true
     * even of a client that keeps sending the commands */
    CHECK_EQ(handle_command(&g, "{\"cmd\":\"speed\",\"ms\":100}"), 1);
    CHECK_EQ(g.tick_ms, TICK_MS);
    CHECK_EQ(handle_command(&g, "{\"cmd\":\"wrap\",\"on\":1}"), 1);
    CHECK_EQ(g.wrap, 0);

    /* restart replays under the SAME setup the player chose */
    protocol_mode = 1;                                   /* banks, never writes */
    g.tick_ms = 30;
    g.wrap = 1;
    static Point long_body[20];
    for (int i = 0; i < 20; i++) { long_body[i].x = i % 10; long_body[i].y = (i / 10); }
    set_body(&g, long_body, 20);
    CHECK_EQ(handle_command(&g, "{\"cmd\":\"restart\"}"), 1);
    CHECK_EQ(g.snake.len, 3);                            /* a fresh run */
    CHECK_EQ(g.tick_ms, 30);
    CHECK_EQ(g.wrap, 1);
    CHECK_EQ(g.started, 1);
    /* ...and a restart while STILL on the card stays on the card: `r` is not START */
    g.started = 0;
    g.tick_ms = 45;
    CHECK_EQ(handle_command(&g, "{\"cmd\":\"restart\"}"), 1);
    CHECK_EQ(g.started, 0);
    CHECK_EQ(g.tick_ms, 45);
    CHECK_EQ(g.wrap, 1);
    protocol_mode = 0;
}

/* ------------------------------------------------------------------ */

int main(void) {
    snprintf(run_dir, sizeof run_dir, "/tmp/tsnake_unit_%ld", (long) getpid());
    mkdir(run_dir, 0700);

    run_suite("only a wall kills", test_only_walls_kill);
    run_suite("the vacating tail tip is not a bite", test_vacating_tail_tip_is_not_a_bite);
    run_suite("a step that eats does not bite", test_eat_wins_over_bite);
    run_suite("a bite severs to the chain depth", test_bite_severs_to_the_chain_depth);
    run_suite("a corpse lies where it fell", test_corpse_stays_where_it_fell);
    run_suite("the head flies over its own shed cells", test_head_flies_over_shed_cells);
    run_suite("corpses are solid, then they are not", test_corpse_fades_after_wound_fade);
    run_suite("an expired cell mid-queue is ignored", test_expired_cell_midqueue_is_ignored);
    run_suite("a second bite behind a live one", test_second_bite_behind_a_live_one);
    run_suite("auto-hunt plans on a torus", test_hunt_plans_on_a_torus);
    run_suite("a wall really does seal a plane", test_hunt_wall_seals_a_plane);
    run_suite("boxed in, still moves", test_hunt_boxed_in_still_moves);
    run_suite("the stride check covers BOTH cells", test_stride_checks_both_cells);
    run_suite("stride length, terminal vs square cells", test_stride_len_and_square_cells);
    run_suite("the stride is what the snake travels", test_stride_is_what_the_snake_actually_travels);
    run_suite("speed is constant", test_speed_is_constant);
    run_suite("the board is never empty of tokens", test_board_is_never_empty);
    run_suite("spawn_food's guards", test_spawn_food_guards);
    run_suite("click to place, click to remove", test_place_or_remove);
    run_suite("a shrink preserves state", test_shrink_preserves_state);
    run_suite("a shrink caps length, never empties", test_shrink_caps_and_never_leaves_empty);
    run_suite("a shrink drops a stranded corpse", test_shrink_drops_stranded_corpse);
    run_suite("growing disturbs nothing", test_grow_disturbs_nothing);
    run_suite("a resize cannot press START", test_resize_cannot_press_start);
    run_suite("the JSON codec", test_json_codec);
    run_suite("handle_command", test_handle_command);
    run_suite("emit_frame", test_emit_frame);
    run_suite("save-data discipline", test_save_data_discipline);
    run_suite("the setup card persists", test_setup_persists);
    run_suite("the input queue", test_input_queue);
    run_suite("the run begins when the card says so", test_the_run_begins_when_told);

    printf("\n%ld checks, %ld failure%s\n", checks_run, checks_failed,
           checks_failed == 1 ? "" : "s");

    for (int i = 0; i < scratch_n; i++) { unlink(scratch[i]); free(scratch[i]); }
    /* the guard is load-bearing: this wipes a tree, so it may only ever be
       pointed at the directory main() itself made, never at anything a test
       could have written into state_path */
    if (!strncmp(run_dir, "/tmp/tsnake_unit_", 17)) wipe_dir(run_dir, 4);
    return checks_failed != 0;
}
