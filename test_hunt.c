/* Headless test harness: #includes snake.c (with its main renamed out of
 * the way) and drives the auto-hunt AI with no terminal. `make test`. */
#define main snake_unused_main
#include "snake.c"
#undef main

int main(void) {
    srand(42);
    BOARD_W = 76;
    BOARD_H = 19;

    Game g;
    game_init(&g);
    g.hunt = 1;
    printf("head=(%d,%d) dir=(%d,%d) food=[%d,%d %d,%d %d,%d]\n",
           g.snake.cells[g.snake.head].x, g.snake.cells[g.snake.head].y,
           g.dir[0], g.dir[1],
           g.food[0].x, g.food[0].y, g.food[1].x, g.food[1].y,
           g.food[2].x, g.food[2].y);

    for (int tick = 0; tick < 200 && g.alive; tick++) {
        int d[2];
        int r = hunt_step(&g, d);
        if (tick < 5)
            printf("tick %d: hunt_step=%d d=(%d,%d) alive=%d score=%d\n",
                   tick, r, d[0], d[1], g.alive, g.score);
        game_step(&g);
    }
    printf("after 200 ticks: alive=%d score=%d len=%d\n",
           g.alive, g.score, g.snake.len);
    return 0;
}
