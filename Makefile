CC      ?= gcc
CFLAGS  ?= -O2 -Wall -Wextra -std=c11
LDLIBS  := -lncurses

snake: snake.c
	$(CC) $(CFLAGS) -o $@ $< $(LDLIBS)

# Both harnesses #define main snake_unused_main and #include "snake.c" (that is how
# they reach the statics), so snake.c must NOT also be compiled as a second
# translation unit — doing so links two mains and fails with "multiple definition of
# `main'". They depend on snake.c only to know when to rebuild.

# test_hunt is a LEGACY print-only rig: no CHECK macros, no verdict — a clean run
# is silence, not a pass. It exists to keep compiling against the current Game.
# The real suite is `make unit` (test_game.c).

.PHONY: clean run test unit
clean:
	rm -f snake test_game test_hunt

run: snake
	./snake

# legacy print-only rig; use `make unit` to actually check anything
test: test_hunt
	./test_hunt

unit: test_game
	./test_game
