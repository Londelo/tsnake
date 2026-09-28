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
#define FOOD_COUNT 3

/* board size is derived from the terminal on startup and on SIGWINCH */
static int BOARD_W = 40;
static int BOARD_H = 20;

/* Layout: row 0 = header, rows 1..BOARD_H+2 = bordered play field,
   the cell (x, y) is drawn at screen row y+2, screen col x+2 (the box
   border occupies the outer ring). */
static void fit_board(void) {
    int w = COLS - 4;      /* border (2 cols) + 2 col right margin */
    int h = LINES - 6;     /* header + border + help row + breathing room */
    BOARD_W = w < MIN_BOARD_W ? MIN_BOARD_W : w;
    BOARD_H = h < MIN_BOARD_H ? MIN_BOARD_H : h;
}

typedef struct {
    int x, y;
} Point;

typedef struct {
    Point cells[MAX_SNAKE];
    int head;      /* index of the head */
    int len;
} Snake;

typedef struct {
    Point food[FOOD_COUNT];
    Snake snake;
    int dir[2];            /* current direction: dx, dy */
    int pending[INPUT_QUEUE_SIZE][2]; /* queued direction changes */
    int pending_head, pending_count;
    int score;
    int alive;
    int paused;
    int wrap;
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

static void load_highscore(int *score) {
    *score = 0;
    FILE *f = fopen(highscore_path(), "r");
    if (f) {
        if (fscanf(f, "%d", score) != 1) *score = 0;
        fclose(f);
    }
}

static void save_highscore(int score) {
    int best = 0;
    load_highscore(&best);
    if (score <= best) return;
    FILE *f = fopen(highscore_path(), "w");
    if (f) {
        fprintf(f, "%d\n", score);
        fclose(f);
    }
}

static void snake_init(Snake *s) {
    s->head = 0;
    s->len = 0;
}

static void snake_push(Snake *s, Point p) {
    s->head = (s->head + 1) % MAX_SNAKE;
    s->cells[s->head] = p;
    if (s->len < MAX_SNAKE) s->len++;
}

static void snake_pop_tail(Snake *s) {
    if (s->len > 0) s->len--;
}

static int snake_contains(Snake *s, Point p, int skip_tail) {
    int count = skip_tail ? s->len - 1 : s->len;
    for (int i = 0; i < count; i++) {
        int idx = (s->head - i + MAX_SNAKE) % MAX_SNAKE;
        if (s->cells[idx].x == p.x && s->cells[idx].y == p.y) return 1;
    }
    return 0;
}

static int food_index_at(const Game *g, Point p) {
    for (int i = 0; i < FOOD_COUNT; i++)
        if (g->food[i].x == p.x && g->food[i].y == p.y) return i;
    return -1;
}

static void spawn_food(Game *g, int i) {
    /* keep re-rolling until the token lands off the snake and off any
       other token (food_index_at returning i means it hit its own slot) */
    do {
        g->food[i].x = rng(BOARD_W);
        g->food[i].y = rng(BOARD_H);
    } while (snake_contains(&g->snake, g->food[i], 0) ||
             food_index_at(g, g->food[i]) != i);
}

static void game_init(Game *g) {
    memset(g, 0, sizeof(*g));
    snake_init(&g->snake);
    /* push tail-first so the last cell pushed is the head at `start` */
    Point start = { BOARD_W / 4, BOARD_H / 2 };
    for (int i = 2; i >= 0; i--) {
        Point seg = { start.x - i, start.y };
        snake_push(&g->snake, seg);
    }
    g->dir[0] = 1; g->dir[1] = 0;
    g->alive = 1;
    g->score = 0;

    for (int i = 0; i < FOOD_COUNT; i++) spawn_food(g, i);
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

/* one cell forward: wall wrap/bounce, food, self collision */
static void advance_one(Game *g) {
    Point head = g->snake.cells[g->snake.head];
    Point next = { head.x + g->dir[0], head.y + g->dir[1] };

    if (g->wrap) {
        next.x = (next.x + BOARD_W) % BOARD_W;
        next.y = (next.y + BOARD_H) % BOARD_H;
    } else if (next.x < 0 || next.x >= BOARD_W || next.y < 0 || next.y >= BOARD_H) {
        g->alive = 0;
        return;
    }

    /* self collision: the tail cell is vacated this step, so it's legal
       to move there unless we just ate */
    int fi = food_index_at(g, next);
    int ate = fi >= 0;
    if (snake_contains(&g->snake, next, !ate)) {
        g->alive = 0;
        return;
    }

    snake_push(&g->snake, next);
    if (ate) {
        g->score++;
        spawn_food(g, fi);
    } else {
        snake_pop_tail(&g->snake);
    }
}

static void game_step(Game *g) {
    if (g->paused || !g->alive) return;

    if (g->pending_count > 0) {
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
    for (int s = 0; s < steps && g->alive; s++) advance_one(g);
}

/* game speed: one tick every `delay` ms, speeding up as you score */
static int tick_delay_ms(const Game *g) {
    int d = 80 - g->score * 2;
    return d < 30 ? 30 : d;
}

static void draw(Game *g, int highscore) {
    erase();

    /* board box occupies rows 1..BOARD_H+2, cols 1..BOARD_W+2 */
    WINDOW *board = derwin(stdscr, BOARD_H + 2, BOARD_W + 2, 1, 1);
    box(board, 0, 0);

    mvprintw(0, 2, " tsnake ");
    attron(A_BOLD);
    printw("score %d", g->score);
    attroff(A_BOLD);
    printw("  high %d", highscore);
    printw("  length %d", g->snake.len);
    if (g->wrap) printw("  [x]rap: on");
    if (g->paused) printw("  PAUSED");

    mvprintw(BOARD_H + 4, 2, "arrows/wasd/vim move · x wrap · p pause · r restart · q quit");

    /* cells sit at +2/+2: one for the box's origin, one for its border */
    /* food */
    if (has_colors()) attron(COLOR_PAIR(1));
    for (int i = 0; i < FOOD_COUNT; i++)
        mvaddch(2 + g->food[i].y, 2 + g->food[i].x, '@');
    if (has_colors()) attroff(COLOR_PAIR(1));

    /* snake */
    if (has_colors()) attron(COLOR_PAIR(2));
    for (int i = 0; i < g->snake.len; i++) {
        int idx = (g->snake.head - i + MAX_SNAKE) % MAX_SNAKE;
        Point p = g->snake.cells[idx];
        mvaddch(2 + p.y, 2 + p.x, i == 0 ? 'O' : 'o');
    }
    if (has_colors()) attroff(COLOR_PAIR(2));

    if (!g->alive) {
        attron(A_BOLD | A_STANDOUT);
        mvprintw(2 + BOARD_H / 2, 4, " GAME OVER  score %d ", g->score);
        attroff(A_BOLD | A_STANDOUT);
        mvprintw(3 + BOARD_H / 2, 4, " r to restart, q to quit ");
    }

    refresh();
}

static void setup_colors(void) {
    if (!has_colors()) return;
    start_color();
    use_default_colors();
    init_pair(1, COLOR_RED, -1);      /* food */
    init_pair(2, COLOR_GREEN, -1);    /* snake */
}

/* after a resize the board may have shrunk under the game — move the
   food back inside, and restart if any snake segment no longer fits */
static void sanitize_after_resize(Game *g) {
    for (int i = 0; i < g->snake.len; i++) {
        int idx = (g->snake.head - i + MAX_SNAKE) % MAX_SNAKE;
        Point p = g->snake.cells[idx];
        if (p.x < 0 || p.x >= BOARD_W || p.y < 0 || p.y >= BOARD_H) {
            game_init(g);
            return;
        }
    }
    for (int i = 0; i < FOOD_COUNT; i++)
        if (g->food[i].x >= BOARD_W || g->food[i].y >= BOARD_H)
            spawn_food(g, i);
}

/* returns 0 to quit */
static int handle_key(Game *g, int ch) {
    switch (ch) {
        case 'q': case 'Q':
            return 0;
        case 'p': case 'P': case ' ':
            g->paused = !g->paused;
            break;
        case 'x': case 'X':
            g->wrap = !g->wrap;
            break;
        case 'r': case 'R':
            game_init(g);
            break;
        case KEY_UP: case 'k': case 'K': case 'w': case 'W':
            queue_direction(g, 0, -1); break;
        case KEY_DOWN: case 'j': case 'J': case 's': case 'S':
            queue_direction(g, 0, 1); break;
        case KEY_LEFT: case 'h': case 'H':
            queue_direction(g, -1, 0); break;
        case KEY_RIGHT: case 'l': case 'L':
            queue_direction(g, 1, 0); break;
        case KEY_RESIZE:
            fit_board();
            sanitize_after_resize(g);
            break;
        default:
            break;
    }
    return 1;
}

static long now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
}

int main(void) {
    srand((unsigned)time(NULL) ^ (unsigned)clock());

    initscr();
    cbreak();
    noecho();
    keypad(stdscr, TRUE);
    curs_set(0);
    nodelay(stdscr, TRUE);
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
                endwin();
                printf("final score: %d\n", g.score);
                return 0;
            }
        }

        long now = now_ms();
        if (now >= next_tick) {
            game_step(&g);
            if (was_alive && !g.alive) save_highscore(g.score);
            was_alive = g.alive;
            next_tick = now + tick_delay_ms(&g);
            draw(&g, highscore);
        } else if (input_seen) {
            draw(&g, highscore); /* reflect pause/wrap/game-over instantly */
        }

        napms(POLL_MS);
    }
}
