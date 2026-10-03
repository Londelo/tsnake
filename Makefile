CC      ?= gcc
CFLAGS  ?= -O2 -Wall -Wextra -std=c11
LDLIBS  := -lncurses

snake: snake.c
	$(CC) $(CFLAGS) -o $@ $< $(LDLIBS)

# Both harnesses #define main snake_unused_main and #include "snake.c" (that is how
# they reach the statics), so snake.c must NOT also be compiled as a second
# translation unit — doing so links two mains and fails with "multiple definition of
# `main'". They depend on snake.c only to know when to rebuild.
test_hunt: test_hunt.c snake.c
	$(CC) $(CFLAGS) -o $@ test_hunt.c $(LDLIBS)

test_game: test_game.c snake.c
	$(CC) $(CFLAGS) -o $@ test_game.c $(LDLIBS)

clean:
	rm -f snake test_hunt test_game

.PHONY: clean run test unit
run: snake
	./snake

test: test_hunt
	./test_hunt

unit: test_game
	./test_game
