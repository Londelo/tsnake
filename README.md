# tsnake

Terminal snake that also plays as an Omarchy window. One engine, two faces.

In the terminal it is a curses game. With `--protocol` the same engine speaks
NDJSON over stdin/stdout instead of drawing, and the Omarchy overlay spawns it as
a child process and paints its frames. The C engine owns every rule and every
saved byte — the overlay is a face, not a second game.

## Playing it in the terminal

```sh
make
./snake
```

Arrows steer. `h` help, `p` pause, `x` wrap, `r` restart, `q` quit. Lowercase
only. The score is the snake's length, so there is no score field — length *is*
the record.

## Playing it in Omarchy

Summon it from the bar widget, or bind a key (no plugin can install one) by
putting this in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + CTRL + ALT + N", "Snake", "omarchy-shell shell toggle io.github.londelo.tsnake '{}'")
```

Check for a clash first with `omarchy menu keybindings --print`. Add
`float = true` for `title = "^tsnake$"` and the window becomes centred and
hand-sizable; do not add `centerwindow`, which is not a field `hl.window_rule`
accepts and which poisons the whole rule line.

The overlay drops `x`: wrap is decided on the setup card, so the key would only
ever be refused.

## Installing

### From the marketplace

Nothing to do — the listing installs it, and the first summon builds the engine
into `$XDG_STATE_HOME/tsnake/build`. Building there rather than in the plugin
folder is deliberate: the shell inotify-watches `~/.config/omarchy/plugins`, so a
`make` in there reloads the panel mid-build.

### From a clone

```sh
git clone https://github.com/Londelo/tsnake
cd tsnake
./install.sh
```

`install.sh` builds the engine, stages the plugin folder outside the watched
tree, and `mv`s it in atomically so the shell never sees a half-written install.
Add `--fresh` when the overlay on screen is not the code in this folder — it
takes the removal path first, which is the one path proven to unload the live
item and clear its cached component.

## Removing

```sh
./uninstall.sh              # code and record
./uninstall.sh --keep-state # code only, record kept for a later reinstall
```

`omarchy plugin remove` deletes the code and leaves the record standing. That is
the host's own convention, not a gap: there is no lifecycle hook anywhere in
`/usr/share/omarchy` and no manifest field by which a plugin could name its data,
so removal cannot delete what it cannot be told about. `./uninstall.sh` is the
half that does know where everything is.

## Where your record lives

| | Overlay | Terminal |
|---|---|---|
| best length | `$XDG_STATE_HOME/tsnake/highscore` | `~/.tsnake_highscore` |
| the setup card | `$XDG_STATE_HOME/tsnake/setup` | `~/.tsnake_setup` |

Both are plain text and written by the engine alone. The two faces keep separate
records — opening one and finding the other's number gone is not a bug, and
merging them is not free.

A record is written the moment it is beaten, never when the panel closes. An
ending that never reaches `flush` — `SIGKILL` included — still keeps it.

## Dependencies

- **Omarchy** with Quickshell 0.3.1 for the overlay. The terminal face needs
  nothing but the items below.
- **gcc** (or any C11 compiler) and **GNU make**.
- **ncurses** — the only library, `-lncurses`.
- **git** and **jq**, used by `install.sh` and `uninstall.sh`.

## Building and checking

```sh
make          # the game; must be warning-free under -Wall -Wextra
make unit     # the real test suite
make run      # play it
```

`make test` runs a legacy print-only rig that asserts nothing. It must keep
compiling, but a clean `make test` is silence, never a pass.

Nothing in this repo is a substitute for playing it. A green suite is a
regression net, not evidence that a feature works.

## Layout

| File | What it is |
|---|---|
| `snake.c` | the whole game, both faces |
| `Overlay.qml` | the Omarchy window |
| `BarWidget.qml` | the bar button |
| `GlyphLab.qml` | a summonable picker for the board's characters |
| `docs/protocol.md` | the NDJSON grammar |
| `docs/decisions.md` | why it is the way it is, and how that was learned |
| `install.sh` / `uninstall.sh` | the install and removal halves |

## License

MIT — see [LICENSE](LICENSE).
