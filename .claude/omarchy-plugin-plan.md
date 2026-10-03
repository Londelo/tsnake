# tsnake as an Omarchy plugin — plan & research record

Research session 2026-10-02. This is the durable record of what was found (with
sources) and what was decided. Nothing here has been built yet — no plugin files
exist, and `snake.c` is untouched.

## Decisions (locked)

| # | Question | Decision |
|---|---|---|
| 1 | Source of truth | **`snake.c`**. The plugin is a front-end; the C engine owns all game rules *and* all save data. |
| 2 | Route | **Route C** — keep the C engine, drive it from QML over a stdin/stdout NDJSON pipe. No JS reimplementation of the rules. |
| 3 | Repo | **This repo.** `manifest.json` goes at the repo root; the plugin and the terminal game ship together (precedent: `terminal.minesweeper`, `omarchy-my-tetris` both ship game + QML in one repo). |
| 4 | Order | **Personal first, then marketplace.** Build it for Brodie's machine, play it, then decide about publishing. Tests are ours, not CI's. |
| 5 | Save data | Score file lives **inside the plugin folder** so `omarchy plugin remove` destroys it, and the **engine** writes it, **only when the overlay is already closed** (deferred flush — see "The save-data problem"). |

Rejected alternatives, for the record: **Route A** (bar-widget launcher that
launches the curses binary in a terminal via `omarchy-launch-or-focus-tui`) —
structurally dodges every gotcha below but caps the look at the terminal's palette
and is a window, not the desktop; already done twice by others. **Route B** (port
the rules to `Model.js`) — cleanest to publish, but forks the engine and re-derives
every hard-won invariant. Route A is a ~2-hour detour from here, not a sunk cost,
because `snake.c` is the game in either route.

## What an Omarchy plugin is

A git repo with `manifest.json` at its root, containing QML, loaded into the single
long-lived `omarchy-shell` Quickshell process and running **unsandboxed as the user**
(`/usr/share/omarchy/shell/README.md:1-16,115`). Never start a second Quickshell
process for a plugin.

Kinds and their required entry-point keys
(`/usr/share/omarchy/bin/omarchy-plugin-validate:97-109`): `bar-widget`→`barWidget`,
`panel`→`panel`, `overlay`→`overlay`, `menu`→`menu`, `service`→`service`, `bar`→`bar`.
Multi-kind manifests are normal (`omarchy.media` = service+bar-widget,
`omarchy.menu` = menu+bar-widget). We want **`["overlay", "bar-widget"]`**: the widget
is the bar button, the overlay is the game.

`omarchy plugin validate` rules, read from the script itself: `schemaVersion` must be
the JSON **number** `1`; required `id, name, version, kinds, entryPoints`; id matches
`^[A-Za-z0-9][A-Za-z0-9._-]*$`, no `..`, never `omarchy.*`; `kinds` non-empty array;
every entry point a relative path with no `..` pointing at a file that exists;
`barWidget.defaultSection` ∈ left|center|right; **no symlinks anywhere** in the folder
(`.git` pruned from that check).

Machine check: this box is Omarchy 4.0.4, Hyprland 0.56.2, `/usr/bin/quickshell`,
`OMARCHY_PATH=/usr/share/omarchy`. The whole reference tree is local — read
`/usr/share/omarchy/shell/` before the web.

## The overlay contract (from first-party code)

`/usr/share/omarchy/shell/plugins/emojis/Emojis.qml` is the working template:

- Root is an `Item` with `property bool opened` and functions `open(payloadJson)`,
  `close()`, `dismiss()` (which also calls `root.shell.hide(manifest.id)`), `toggle()`
  (`:45-67`).
- Fullscreen surface: `PanelWindow { visible: root.opened; anchors {top;bottom;left;right}
  ; color: "transparent"; WlrLayershell.layer: WlrLayer.Overlay;
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive; exclusionMode:
  ExclusionMode.Ignore }` (`:160-168`). Exclusive keyboard focus is what a game needs.
- Keys: `Item { focus: true; Keys.priority: Keys.BeforeItem; Keys.onPressed:
  function(event){ … event.accepted = true } }`, focus grabbed with
  `Qt.callLater(function(){ keyCatcher.forceActiveFocus() })` (`:51,192-232`).
- Host injects `omarchyPath`, `shell`, `manifest`, `pluginRegistry`,
  `barWidgetRegistry` into the entry point if declared (`shell.qml:218-224,1335-1346`);
  third-party plugins receive **capability-scoped facades**, so don't expect to reach
  other plugins.
- Summoning: `omarchy-shell shell summon <id> '{}'`, `… toggle <id> '{}'`, `… hide <id>`
  (`shell/README.md:172-215`).

**Do not use `Ui/PanelKeyCatcher.qml`** — it emits `moveRequested` for `h/j/k/l` as
well as arrows, which smuggles vim controls back in against the arrows-only rule. Use a
raw `Keys.onPressed` handling only `Qt.Key_Left/Right/Up/Down` + `h`/`p`/`x`/`r`/`q` +
Escape.

## The engine pipe

Quickshell `Process` (docs v0.3.1, `Quickshell.Io/Process`) exposes `command`,
`stdinEnabled`, `stdout`, `stderr`, `environment`, `workingDirectory`, `running`,
`processId`, and `startDetached`, `write`, `signal`, `exec`, with `started`/`exited`.
So a long-lived bidirectional pipe is supported: `stdinEnabled: true`, `write()` to
send commands, stdout parser (`SplitParser`) to read frames. First-party precedent for
external binaries is everywhere (~35 built-in files use `Process {`); the closest
game precedent is `io.github.bogard1.doom` (`Panel.qml`, 315 lines: `Process`,
`running = true`, `signal(19)`/`signal(18)` for SIGSTOP/SIGCONT, `execDetached` helper
scripts in `bin/`) — but DOOM still renders in its own window, not in the shell.

Draft protocol, one JSON object per line, both directions:

- QML → engine: `{"cmd":"tick"}` (not needed; engine self-ticks),
  `{"cmd":"dir","dx":1,"dy":0}`, `{"cmd":"click","x":9,"y":4}`, `{"cmd":"pause"}`,
  `{"cmd":"wrap"}`, `{"cmd":"hunt"}`, `{"cmd":"restart"}`, `{"cmd":"flush"}`,
  `{"cmd":"quit"}`.
- Engine → QML: `{"event":"frame","tick":123,"w":..,"h":..,"alive":true,"paused":false,
  "wrap":false,"hunt":false,"flash":0,"len":7,"best":42,"head":{"x":..,"y":..},
  "dir":[1,0],"body":[{"x":..,"y":..}…],"wound":[{"x":..,"y":..,"ttl":31}…],
  "food":[{"x":..,"y":..,"placed":true}…]}`.

Implementation notes:

- Add the mode as a **flag in `snake.c`'s existing `main`** (e.g. `snake --protocol`),
  keeping the one-file rule. `test_hunt.c` already proves the ncurses/logic seam is
  clean — everything except `draw`/`draw_panel`/`head_glyph`/`setup_colors`/
  `handle_key`/`handle_mouse`/`fit_board` is pure.
- The engine keeps its own tick clock (`TICK_MS` 55, `now_ms`), exactly as it does now,
  and emits one frame per tick plus one on any input-driven state change. QML never
  drives ticks — that preserves "input latency never waits for a tick".
- The 2-cell horizontal aspect hack (`game_step` advancing horizontal moves two cells)
  is an ncurses artifact: 950x540 terminal cells are ~2:1. In QML cells are square, so
  the hack — and the `hunt_stride_free` both-cells burden it created — should become a
  protocol-side option (engine flag `--square-cells`) rather than being deleted, so the
  terminal game keeps its current behaviour.

## Lifecycle rules (Route C's real cost)

- **Kill the child.** Closing the overlay must stop the engine (`signal(19)`/`kill`, or
  just `quit` then `kill`), and `Component.onDestruction` must kill it — otherwise every
  hot-reload leaks a process and an invisible game grinds BFS for the whole session.
- **No CPU while hidden** (explicit convention in the ecosystem: *"The game loop only
  runs while the panel is open, so the plugin uses no CPU while hidden"*): the QML timer
  gates on `running: root.opened && phase === "playing"` and `close()` stops it; here
  the process is the loop, so the same discipline applies to the process.

## The save-data problem (settled, with proof)

`omarchy plugin remove` does `rm -rf "$target"` for a git-checkout install
(`omarchy-plugin-remove:103`) → **files inside the plugin folder die with the plugin**.
That is what we want. (Caveat: a *hand-made* dir install is only moved to a timestamped
backup inside `plugins/` (`:107-114`), so during development the file will survive
removal. Marketplace installs are git checkouts, so the publish behaviour is correct.)

But the folder is watched: `inotifywait -m -r -q -e close_write,create,delete,move` over
the **entire plugins dir with no name filter** (`services/PluginRegistry.qml:663-682`),
every event → `reloadPlugins()` (`shell.qml:1476-1478`), and the overlay's `Loader` is
rebuilt from a freshly computed `panelEntries` model (`shell.qml:1312,1322-1337`) — so
**any file written inside the plugin folder destroys and recreates the overlay**, killing
the `Process` and thus the game. A hidden-entry exemption exists
(`PluginRegistry.qml:734-735`) but it only covers dot-entries *directly under*
`plugins/` (clone staging dirs, remove backups), not dot-files inside a plugin.

**Design that follows:**

1. Score file = `<pluginDir>/.local/highscore`, owned and written **only by the engine**
   (`load_highscore`/`save_highscore` pointed at it via a `--state` flag or argv, so the
   C side keeps ownership — no second writer).
2. QML never writes during play. On `close()`/`dismiss()` it sends `{"cmd":"flush"}`;
   the engine writes; the resulting reload happens while nothing is on screen →
   invisible. **Never flush on death** while the game-over panel is up — that would
   reset the panel under the player's eyes.
3. Accepted cost: a shell crash before closing the overlay loses that session's best.
4. The built `snake` binary must **not** live in the plugin folder either (same watcher;
   a `make` would reload the plugin). Resolve it from the shell.json entry setting
   (`gameBin`), else `~/.local/state/tsnake/snake`. For Brodie's machine the repo's
   `make` output is fine as an explicit setting.
5. Do **not** put the score in `shell.json` inline settings (what `sebasgl23.snake`
   does): `TitanicRuby`'s README reports that disabling a third-party bar widget deletes
   its inline settings — including saved scores.
6. Since the state file is read by a long-lived shared shell process, harden the read
   (refuse symlinks, cap size) — the approach `yamz8.snake` takes for the same reason.

## Dev loop (this machine)

```sh
# layout
~/.config/omarchy/plugins/io.github.londelo.tsnake/{manifest.json,…qml}
omarchy plugin validate .                       # same rules the shell enforces
omarchy-shell shell rescanPlugins               # force rediscovery
omarchy plugin list --json | jq '.[] | select(.id=="io.github.londelo.tsnake")'
omarchy-shell shell toggle io.github.londelo.tsnake '{}'
qmllint -I "$OMARCHY_PATH/shell" *.qml          # keep it clean
make                                            # must stay warning-free: -Wall -Wextra
```

**Gotcha:** with `keepLoaded: true` the mounted surface keeps serving stale code — QML
edits need `omarchy restart shell`, and JS changes also need
`rm -rf ~/.cache/quickshell/qmlcache/*`. Both existing overlay snakes document this.
Develop with `keepLoaded` **off** and turn it on at the end (it keeps the layer-shell
window mounted between summons).

**Keybind:** no plugin can install one. It goes in the README for the user to add to
`~/.config/hypr/bindings.lua`, e.g.
`o.bind("SUPER + CTRL + ALT + N", "Snake", "omarchy-shell shell toggle io.github.londelo.tsnake '{}'")`,
checking first with `omarchy menu keybindings --print`.

## Prior art (all verified against the live registry)

Catalog = `raw.githubusercontent.com/omacom/omarchy-plugin-marketplace/main/registry.json`
(9.2 MB, 4,755 listed plugins; the plugins.omarchy.org pages themselves rendered empty —
the registry file is the real data). Local copy was at `/tmp/reg.json`.

178 plugins carry the `games` **tag**. Six are already snake:

| id | repo | kinds | notes |
|---|---|---|---|
| `yamz8.snake` | yamz8/omarchy-snake | **overlay + bar-widget**, `keepLoaded` | verified manifest; `Canvas{onPaint}` board, `Timer`, rules in `SnakeGame.js`, hardened state file |
| `io.github.lennartai.snake` | LennartAI/omarchy-snake | overlay, `keepLoaded` (agent-reported; **my manifest fetch failed — UNVERIFIED**) | the fullscreen reference |
| `io.github.titanicruby.snake` | TitanicRuby/omarchy-snake | bar-widget | plain `Item` + `Repeater` grid, per-mode best |
| `io.github.faeric.omasnake` | Faeric/omasnake | bar-widget | monochrome, `activation:"on-demand"`, ships `tests/check.sh` |
| `sebasgl23.snake` | Sebasgl23/omarchy-snake | bar-widget | `GameModel.js` + `tests/tst_GameModel.qml`, score in shell.json settings |
| `jhgundersen.snake` | jhgundersen/omarchy-snake-plugin | bar-widget | QtQuick Shapes, file-based highscore with merge-on-write |

Terminal games (the Route A precedent, verified myself):
`terminal.minesweeper` (acobrerosf/omarchy-minesweeper) ships a 61 KB extensionless
executable + `Minesweeper.desktop` →
`Exec=sh -c 'omarchy-launch-or-focus-tui --app-id=org.omarchy.minesweeper "$HOME/.config/omarchy/plugins/terminal.minesweeper/omarchy-minesweeper"'`,
`Categories=Game;LogicGame;`, 2 KB BarWidget + 10.7 KB Panel; `terminal.tetris`
(Ycaro-Oleg/omarchy-my-tetris) same shape + `sounds/`. No QML terminal emulator is
embedded anywhere (no VTE/foot/kitty precedent) — the sanctioned path is that
first-party launcher (`omarchy-launch-tui` → `setsid uwsm-app -- xdg-terminal-exec`).

**The empty square (verified):** intersecting the 178 `games` plugins against the 44
sources carrying the `bundled-executable-binary` capability returns **zero** — nobody
ships a compiled game — and no plugin paints an external engine's board in-shell. That
is where tsnake sits. Our differentiation is mechanics, not kind: none of the six has the
sever-and-fade self-bite, click-to-place/toggle food, or the BFS auto-hunt AI.

## Marketplace rules (when we get there)

- Requirements (`SUBMISSION.md`): public GitHub repo, **one** plugin, `manifest.json` at
  root, root README with install **and removal**, root LICENSE, documented external
  dependencies, optional one root `preview.png|jpg|jpeg|webp|avif` (≤50 MB / 40 MP).
- Categories (exact, case-sensitive, pick 1): Appearance, Desktop, Developer Tools,
  Hardware, Kids, Productivity, System, Widgets, Other. **There is no Games category.**
  Tags (pick 1–3, lowercase): ai, bar, education, **games**, hyprland, kids, launcher,
  media, power-management, quickshell, security, system, vpn, workspaces.
- IDs are permanent and globally unique; retired IDs are never reusable
  (`retiredPluginIds` = 69). Prefer `io.github.londelo.tsnake`; check it's free first.
- Publishing runs the **Automated Security Baseline** — a static scan of the exact
  commit that never executes plugin code. ELF/PE/Mach-O detection produces the
  `bundled-executable-binary` **capability** → `review-required`, which is *not* a
  blocking finding and can be accepted by a maintainer via `approved-and-verified`
  (`SECURITY.md:47,65-71,79-88`). Blocking findings are things like `curl | pipe | shell`,
  `cargo-git-unpinned`, `remote-git-execution-unpinned`. Building from the repo's own
  source → `remote-build` capability (653 precedents), also review-only. Registry
  outcomes: 2543 `passed`, 2135 `review-required`.
- The installer never builds and never runs hooks (`shell/README.md:126-129`), so a
  stranger gets source and no binary: **publishing needs either a committed prebuilt
  binary (x86_64-only, `bundled-executable-binary`) or a documented build-on-first-run
  into `~/.local/state/tsnake/` (`remote-build`, needs gcc + ncurses).** Personal build
  defers this decision.
- Note for the repo: `.claude/CLAUDE.md` and this plan ship with the repo and the
  scanner reads them — fine, but be deliberate.

## Constraints from this project's own conventions

- One file, zero deps beyond ncurses → the protocol mode is a **flag in `snake.c`'s
  `main`**, not a new source file.
- Arrows + `h`/`p`/`x`/`r`/`q`, lowercase only, no vim/wasd/uppercase/space/Enter —
  hence no `PanelKeyCatcher`.
- Constant speed (`TICK_MS` 55) must not scale with progress.
- **Unit tests are allowed** (Brodie lifted the old "none is to be written" ban on
  2026-10-02). Test the logic *behind* the ncurses seam — state, not pixels: the bite /
  wound rules, `hunt_step` BFS topology, stride legality, food invariants, resize
  preservation, and the `--protocol` codec. Do **not** copy the pty/ANSI screen-model
  rigs the other snakes ship: asserting on rendered terminal bytes produced a whole
  session of false failures here (see `.claude/CLAUDE.md`, Testing). Human verification
  is still the acceptance gate — `make run`, play it, and the same for the overlay.
- `make` stays warning-free under `-Wall -Wextra`. That is the only automated check.

## Build order (personal install first)

1. `snake --protocol` mode in `snake.c` (frame emit, command read, `--state <path>`,
   `--square-cells`). Keep the curses path byte-for-byte behaviourally identical.
2. `manifest.json` at repo root: `io.github.londelo.tsnake`,
   `kinds: ["overlay","bar-widget"]`, `entryPoints: { overlay: "Overlay.qml", barWidget:
   "BarWidget.qml" }`, `barWidget.defaultSection: "right"`.
3. `Overlay.qml` — PanelWindow/Overlay layer/Exclusive focus, raw `Keys.onPressed`
   (arrows + our keys + Escape), square-cell grid (`Canvas` with `requestPaint()` for a
   ~60-cell board, or `Repeater` of `Rectangle`s), theme colours from `qs.Commons`
   (`Color.*`, `Style.*`), hunt border orange / eat flash green / wounds dimming.
4. `BarWidget.qml` — bar button that toggles the overlay.
5. Engine lifecycle: start on `open()`, kill on `close()`/`dismiss()`/
   `Component.onDestruction`.
6. Save data: flush-on-close only; read at `open()`.
7. Play it. Then flip `keepLoaded: true`, add `preview.png`, write the README
   (install + removal + the keybind line), then talk marketplace.

## Still open / unverified

- `io.github.lennartai.snake`'s manifest (fetch failed) — assumed overlay+`keepLoaded`.
- The exact published allow-list for the free-text `barWidget.category` field (observed:
  `"Fun"`, `"Games"`, `"Time"`).
- Whether a compiled-binary *game* specifically would clear maintainer review is
  inferred from the 44 precedents (none a game), not stated in policy.
- Whether the frame protocol needs a `--fps` knob, or whether emitting every 55 ms tick
  over a pipe is smooth enough — measure by playing it.
- Naming: Brodie said "Machi plugin plan"; recorded as `omarchy-plugin-plan.md`.
