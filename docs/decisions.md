# tsnake — decisions and how they were learned

One place for the "how I came to learn this" stories. Code keeps a one-line
pointer; the full story lives here and nowhere else (the one-place rule — do not
re-duplicate these into `snake.c`, `Overlay.qml` or `.claude/CLAUDE.md`).

## The record is written the instant it is beaten

The protocol face used to BANK the best length in RAM and write it only at the
end of a run — `flush`, `quit`, stdin EOF, SIGTERM. In the real overlay none of
those endings ever arrives: `omarchy-shell shell hide` tears the panel's `Loader`
down and Quickshell 0.3.1's `Process` destructor SIGKILLs the child with the
`flush`+`quit` write still buffered inside QProcess (the API offers only
exec/signal/write — no flush, no closeStdin, no terminatedType to wait on).
Measured against the installed engine, five ways: quit/SIGTERM/EOF wrote the
file; `kill -9` and abandonment wrote nothing. Every hidden window therefore
"lost" a high score. `save_highscore()` now writes on every beat — that is the
engine's one rule; `flush`/`quit`/`terminate_handler` survive as redundancy. The
daemonize-era `EPIPE` handling died with that design, but its lesson did not: the
pipeline must stay honest in both directions — `SIGPIPE` is `SIG_IGN`ored so a
dead reader surfaces as a write error the loop can act on, `emit_frame` answers
0, and `protocol_run` exits — an engine grinding BFS into a closed pipe would
outlive its own game.

## Why nothing lives in the watched plugins folder

`~/.config/omarchy/plugins` is watched by `inotifywait -m -r -q -e
close_write,create,delete,move` (`PluginRegistry.qml:663`, `pluginsDir` at `:11`)
and every event reloads the panel (`shell.qml:1476-1478`); `localPluginIdForPath`
(`:728-740`) skips only a *leading* dot on a top-level entry, so even a nested
dot-file still triggers reloads. A save file inside the plugin folder is there
"state living in a hot-reload zone": the `Loader` rebuilds, and `Process`
SIGKILLs the child with its last frame and last flush still buffered inside
QProcess (no way to wait for either before the kill — the API offers only
exec/signal/write). A panel reload taken out from under the player mid-run is
exactly what "the high score vanished" turned out to be, twice over — it both
interrupted the run and tore down the process that owed it money. Hence the
state root: `$XDG_STATE_HOME` (else `~/.local/state`)/`tsnake`, identical in
`Overlay.qml:stateDir` and `install.sh`.

## Removing tsnake

`omarchy-plugin-remove` has no lifecycle hook and the manifest has no field to
name data in, so it can never take the record with the code — and if the folder
is not a git checkout, it does not even delete it: it renames it to
`plugins/.$ID.bak.<timestamp>` (`:106-114`). Three such backups sat in the
watched tree, two still holding a stale `highscore: 4` — that is what
in-folder state degenerates into: litter, with the authoritative number
living elsewhere. Ten first-party plugins keep persistent state under
`~/.local/state/omarchy/` (the eleventh is the one that declares this rule in its
own source — see the next section) and none inside the plugin folder, and each one
deletes that state only behind its own confirm dialog (`clipboard/Clipboard.qml:104`
← `:416`, `notifications/Service.qml:588` ← `:887`), the same split `pacman
-R`/`-Rns` and `apt remove`/`--purge` make. `./uninstall.sh` is our half of that
pair: hide → `omarchy-plugin-remove --yes` → sweep our own `.$ID.bak.*` → erase
the two named files, then `rmdir` (no recursive delete; `--keep-state` spares the
record for a later reinstall).

## State lives outside the plugin folder — the host's own convention

This is the host's convention, not our invention: **11 first-party plugins keep
their persistent files under `~/.local/state/omarchy/` and none in their plugin
folder** (`clipboard/Clipboard.qml:20`, `panels/weather/Panel.qml:98`,
`bar/Bar.qml:1175`, `services/idle/Service.qml:15`, `agents/Main.qml:16`), and
`notifications/Service.qml:22-24` states the rule out loud — "persistent user
state … not regeneratable cache." That directory is what `XDG_STATE_HOME` exists
for: per-user state that should survive a reinstall but vanish on an uninstall.
In-folder state fails even without the watcher — `omarchy-plugin-update` runs
`merge --ff-only` with a `reset --hard` fallback (`:67`, `:73`) and
`omarchy-plugin-remove` `rm -rf`s a git checkout (`:103`), so in-folder state
dies on a routine update. So: **code lives in the plugin folder, state lives in
`$XDG_STATE_HOME`**, and marketplace installs (git checkouts) deliver
git-tracked files and run nothing — which is also why `snake` must already be
built and on PATH for a stranger's install.

## The setup card's settings persist, engine-owned

`load_setup()` runs *before* the first frame; `save_setup()` fires on every
accepted `wrap`/`speed` (and the terminal's `x`), writing the already-clamped
value — a client that sends `ms:100000` cannot poison tomorrow's card through
today's pipe. Hunt is deliberately NOT persisted: an auto-piloting snake the
instant a window appears reads as the game playing itself.

## The `started` gate — and why a resize must not press START

`Game.started` is 0 until a `start` command arrives; while 0, `game_step`
returns before the tick check and `handle_command` refuses `dir`/`hunt`/`pause`
(but allows `click` — placing food aims the AI, it does not steer; `wrap`/`speed`
guard the OTHER way — card-only, refused once STARTed). The trap that proves the
gate matters: `sanitize_after_resize` used to call `game_init`, which sets
`started = 1` and `tick_ms = TICK_MS` — and the overlay's very first act is a
`{"cmd":"size"}` report, so every fresh window silently pressed START at the
default speed; the card was up for one frame and the only thing QML could paint
next was GAME OVER. A resize is a MOVE, not a new run: relocation now carries
`started` and `tick_ms` across `game_init`, and `restart` is the only command
allowed to re-init (it carries the same fields for the same reason).

## Guards worth knowing the shape of

- **`stateUsable` / `stateDir`** (`Overlay.qml`): never hand the engine a
  root-ish path (`"/tsnake"`); with neither `XDG_STATE_HOME` nor `HOME`
  trustworthy, pass no `--state`/`--setup` and let the engine use its own
  defaults.
- **The state-file trust test** (`state_file_trustworthy`): `lstat` (never
  `stat`), `S_ISREG`, `0 < size ≤ 32` — a directory, a fifo, or a megabyte of
  junk reads as "no record" instead of poisoning the parse; writes use
  `O_NOFOLLOW` so a planted symlink can never turn a save into a write to
  whatever it points at.
- **Aspect ratio**: terminal cells are ~2x taller than wide, so a horizontal
  move covers a 2-cell stride (`stride_len_for`), each cell landed and checked
  on its own; the overlay's `--square-cells` board makes every stride one cell.
- **Hunt topology**: see the next section.
- **Mouse coalescing**: `mouseinterval(0)` + press-only handling (no synthesised
  double-fire; no "same cell within N ms" timer — that eats click-then-un-click).
- **`spawn_food`**: bounded at 1000 re-rolls; it must test `other_token_at`
  ("is a DIFFERENT token here"), never `food_index_at(...) != i` — an empty cell
  reads -1, which is `!= i`, so the naive check rejects every legal cell and
  only escapes by re-rolling under the head: an endless loop that looks like a
  frozen game.
- **Never-empty board**: `ensure_food` tops the board back up after every
  removal — food is the only way to grow, and the hunt AI's distance field is
  seeded FROM the tokens.

## The hunt AI plans on the board the snake travels

`hunt_step`'s BFS clipped its neighbour at the board edges while `advance_one`
wrapped. A body wall running edge to edge (just what a long snake looks like)
then sealed the wave off IN THE PLANE even though the torus has an opening at
the seam: every legal neighbour of the head read `dist == -1`, no direction
scored, and the boxed-in branch fell through to marching straight — which in
wrap mode is always legal — so the snake walked one horizontal line across the
screen and through the seam forever, never turning, never eating. Fix: every
step the AI reasons about goes through `hunt_next_cell`, wrap included. The
boxed-in fallback checks the WHOLE stride (`hunt_stride_free`) for the same
reason — a half-checked stride made "legal" a lie, and the straight-case wins
whenever it is allowed at all, which pinned the AI to one direction.

## Harness traps (test_game.c / test_hunt.c)

- `blank_game()` memsets, so it sets `started = 1` **and** `tick_ms = TICK_MS`
  by hand (a blank game means a run IN PROGRESS; a zero `tick_ms` would freeze
  every `game_step`-driven test into a false pass). Keep that discipline when
  adding a rig.
- Harnesses `#include "snake.c"` to reach the statics; never compile `snake.c`
  as a second TU (two `main`s).
- `test_hunt.c` is print-only legacy: no CHECK macros, no verdict — it prints
  `hunt_step`/`alive`/`len` per tick and exits 0 whatever happens. Its 200-tick
  loop lets the rig steer a body it stamped in by hand, scarred and
  self-severing, for twenty blind ticks — what bleeds away under that steering
  is `snake_bite` severing at the bitten cell (the design, not a bug), but
  nothing in the rig grades the difference. Offer it as a toy, never as a
  check — the Makefile says the same.
- Why the old screen-rig ban lifted still reads true: assert on the game's own
  state, never on rendered terminal bytes. The one real bug found this way
  (mouse events one click late under `nodelay`) was only confirmed once the
  ANSI-screen model was replaced by reading engine state.

## Debugging the overlay

**Hide before you summon.** A hidden panel unloads its QML item and kills its
`Process`; an open window makes `summon` a no-op, so you screenshot a stale item
painting the previous engine's last frame while `ps` cheerfully shows a
live-looking `snake --protocol` (exec'd before your rebuild — the old binary
from a deleted inode). Hide, confirm the engine died, then summon.
`journalctl --user` is no evidence either: this Quickshell never forwards a
plugin's JS `console.log`, so "no QML complaints" is silence, not a clean bill —
assert on emitted frames and `grim` pixels, at the geometry `hyprctl clients -j`
reports.

## The keybind line (for whoever adds it by hand)

No plugin can install a keybind. If you want one, put it in
`~/.config/hypr/bindings.lua`:
`o.bind("SUPER + CTRL + ALT + N", "Snake", "omarchy-shell shell toggle io.github.londelo.tsnake '{}'")`
— check first with `omarchy menu keybindings --print`. `float = true` for
`title = "^tsnake$"` gives the centred, hand-sizable window; do NOT add
`centerwindow` (not a `hl.window_rule` field — poisons the whole rule line).

## A marketplace clone lands playable — the first summon builds the engine

`omarchy plugin add` clones, validates, places, and runs nothing: measured,
`omarchy-plugin-enable` spawns no code, `PluginRegistry.qml` spawns no code,
and there is no lifecycle hook anywhere under `/usr/share/omarchy`. So the
only code tsnake can run on its own is its own QML, and the first
`startEngine()` builds the engine before launching it: `cp -u` the sources and
`make` in `$XDG_STATE_HOME/tsnake/build` — never in the watched plugin folder,
where a create event would reload the panel mid-build (see "Why nothing lives
in the watched plugins folder"). `make` is idempotent: a current binary exits
in milliseconds, and after a `plugin update` (which `reset --hard`s the
source) the next summon rebuilds, so a stale binary never outlives its source.
A failed build is not fatal — the candidate list still gets its turn, and the
failure card names what it tried. `install.sh` stays the by-hand path.
`omarchy plugin remove` deletes the code and leaves the record standing — the
host's own convention (see "State lives outside the plugin folder"), and no
hook exists to do otherwise.

## Checks that exist

`make` must stay warning-free under `-Wall -Wextra`. `make unit` (test_game) is
the real suite — a from-scratch build on 2026-10-09 ran **2324 checks / 3
failures / exit 1**: the suite writes its state files to a
per-process `/tmp/tsnake_unit_<pid>/` scratch dir and wipes that dir at exit
(guarded by the `strncmp(run_dir, "/tmp/tsnake_unit_", 17)` shape check, so
the wipe can never point anywhere else), and no test ever writes `~/.tsnake_*` —
a HOME-level copy of either file appearing is something else running dirty,
not the suite. The 3 failures that baseline replaced were real, not contamination — and the
old "shared rig state" diagnosis was wrong when it was written and is wrong
now that the checks are green: `flush_setup()` spent its save-bank once and
refused the second ask (fixed 2026-10-10 — re-entrant, the bank is never
spent), and the pre-start click check clicked the corner cell where the rig's
own `tokens_far()` parks a token, so the engine correctly REMOVED it (the
handler toggles) — a rig bug, fixed by clicking an empty cell instead. When a
check goes red, read the code before blaming the rig. A CHECK COUNT that moves
means a check was added, removed, or is misfiring — hunt the cause, don't
"fix" the count. `make test`
(test_hunt) is the legacy rig above. Human play-through stays the acceptance
gate for anything seen or felt.
