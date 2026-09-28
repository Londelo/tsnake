CC      ?= gcc
CFLAGS  ?= -O2 -Wall -Wextra -std=c11
LDLIBS  := -lncurses

snake: snake.c
	$(CC) $(CFLAGS) -o $@ $< $(LDLIBS)

clean:
	rm -f snake

.PHONY: clean run
run: snake
	./snake
