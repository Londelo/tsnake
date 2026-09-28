CC      ?= gcc
CFLAGS  ?= -O2 -Wall -Wextra -std=c11
LDLIBS  := -lncurses

snake: snake.c
	$(CC) $(CFLAGS) -o $@ $< $(LDLIBS)

test_hunt: test_hunt.c snake.c
	$(CC) $(CFLAGS) -o $@ $< $(LDLIBS)

clean:
	rm -f snake test_hunt

.PHONY: clean run test
run: snake
	./snake

test: test_hunt
	./test_hunt
