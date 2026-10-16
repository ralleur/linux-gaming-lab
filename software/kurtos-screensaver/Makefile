# SPDX-License-Identifier: GPL-3.0-or-later
PREFIX ?= /usr
CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra
SDL_CFLAGS := $(shell pkg-config --cflags sdl3)
SDL_LIBS := $(shell pkg-config --libs sdl3)

all: kurtos-screensaver kurtos-saver-render

kurtos-screensaver: src/main.c src/engine.c src/engine.h
	$(CC) $(CFLAGS) $(SDL_CFLAGS) -o $@ src/main.c src/engine.c $(SDL_LIBS) -lm

kurtos-saver-render: src/render.c src/engine.c src/engine.h
	$(CC) $(CFLAGS) -o $@ src/render.c src/engine.c -lm

install: all
	install -Dm755 kurtos-screensaver $(DESTDIR)$(PREFIX)/bin/kurtos-screensaver
	install -Dm755 kurtos-saver-render $(DESTDIR)$(PREFIX)/bin/kurtos-saver-render

clean:
	rm -f kurtos-screensaver kurtos-saver-render

.PHONY: all install clean
