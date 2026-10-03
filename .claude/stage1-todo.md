# Stage 1 — tsnake as a local Omarchy plugin (+ unit tests)

Scope: **Brodie's machine only.** No marketplace work, no prebuilt-binary decision,
no `preview.png`, no publishing. Plan of record: `.claude/omarchy-plugin-plan.md`.

Owner key: `me` = Claude, `qml` = qml-plugin subagent, `ut` = unittests subagent,
`Brodie` = human play-test.

| # | Task | Owner | Status |
|---|---|---|---|
| 1 | De-mirror the lifted test ban in `omarchy-plugin-plan.md` | me | [x] |
| 2 | Verify Omarchy/quickshell environment on this box | me | [x] Quickshell 0.3.1, refs present, plugins dir empty, no `qmllint` on PATH, **no `omarchy-shell` running** |
| 3 | `snake --protocol`: NDJSON frame emit + command read, self-ticking | me | [x] |
| 4 | `snake --state <path>`: engine-owned file, hardened read, flush-only writes | me | [x] verified by hand: nothing on disk while live, one write after close; symlink read+write refused with target intact; garbage file ignored; nested dirs created |
| 5 | `--square-cells`: 2-cell aspect stride becomes a renderer-side option | me | [x] `stride_len_for()` is the single decider, shared by `game_step` and `hunt_stride_free` |
| 6 | `make` warning-free under `-Wall -Wextra` (both targets) | me | [x] engine commit; re-check after the agents land |
| 7 | Unit tests for the mechanics behind the ncurses seam | ut | [x] **1853 checks, 0 failures**, 28/28 suites, exit 0, warning-free, repeat runs byte-identical. All 22 initial failures were rig bugs; `snake.c` was never touched. Independently mutation-tested by me: no `O_NOFOLLOW` → 2 failures, `ensure_food` neutered → 12, wrap disabled → 14 |
| 8 | `manifest.json` at repo root (`overlay` + `bar-widget`) | qml | [x] passes the real `omarchy-plugin-validate` |
| 9 | `Overlay.qml`: PanelWindow/Overlay layer, exclusive focus, raw `Keys.onPressed`, board | qml | [x] 780 lines; qmllint exit 0, no silencing comments, its warning categories reproduce on first-party `Emojis.qml` |
| 10 | `BarWidget.qml`: bar button that toggles the overlay | qml | [x] 36 lines, shaped from `plugins/menu/BarWidget.qml:1-24` |
| 11 | Engine lifecycle: start on `open()`, kill on `close()`/`dismiss()`/`onDestruction` | qml | [x] candidate list, `launchPending` + 1500 ms watchdog, 600 ms grace then SIGTERM backstop |
| 12 | Save data: read at `open()`, flush only after the overlay is closed | qml + me | [x] `opened = false` precedes `stopEngine()` in both paths; flush→quit→kill. State at `$HOME/.local/state/tsnake/highscore`, engine binary outside the plugins dir — the inotify trap is designed out, not trusted |
| 13 | Plugin install into `~/.config/omarchy/plugins/` + `omarchy plugin validate` + `qmllint` | me | [x] installed at `~/.config/omarchy/plugins/io.github.londelo.tsnake` + engine at `~/.local/state/tsnake/snake`; validator exit 0 on the installed folder; installed binary proven to stream frames and flush on quit |
| 14 | Human play-test: does it feel like the terminal game | Brodie | [ ] **the only thing left.** Needs a login session with `omarchy-shell` up; never yet run under Quickshell |
| 15 | README: install, removal, keybind line (local-facing only) | qml | [x] append-only: 84 insertions, 0 deletions |

## Stage-1 landing notes (verified, not assumed)

Three ways the brief was wrong about the 0.3.1 API, each caught against
qmltypes/qmllint rather than guessed: `SplitParser` takes `splitMarker`, not
`token`; `errorOccurred` is an overridable method with zero first-party users
(dropped — a watchdog Timer + `onExited` share one `launchPending` flag instead);
and `Qt.Key_h/p/x/r/q` **do not exist** on the QML `Qt` object, so those five
keys would have silently never fired — they now match lowercase `event.text`,
which also makes the lowercase-only rule real (`Shift+h` arrives as `H`).
`q` calls `dismiss()`, not `close()`: `close()` stops the engine and hides the
surface but leaves the host's `openPanelIds` holding the id, and the bar button
toggles through `shell toggle` — a stale id makes the next press hide an already
hidden panel and strands the Loader item.

Unproven by any amount of automation, and not pretending to be: exclusive
keyboard focus under hyprland, `Color.menu.*` on Canvas `fillStyle`,
`Style.font.menuFamily` strings, and the feel of click-to-place.

Found and fixed while building task 4: `ensure_parent_dir`'s component walk ran
past the end of its own buffer, so the first save segfaulted under `--protocol`
and returned garbage to its caller in the terminal build. Caught by hand-smoke,
not by a rig.

Deliberately deferred to stage 2: marketplace submission, Automated Security Baseline
handling, `keepLoaded: true`, `preview.png`, category/tag choice.

Invariant reminders the build must not break:
- curses path stays behaviourally identical (same keys, same 2-cell horizontal stride,
  same constant `TICK_MS` 55)
- the hunt AI plans on the SAME topology the snake travels — stride checks must cover
  the WHOLE stride, both cells, including when `--square-cells` makes it one
- the board is never empty of tokens (`ensure_food`)
- only walls kill; a self bite wounds
- the engine is the only writer of the state file, and it writes only while the overlay
  is closed. The state file now lives at `$HOME/.local/state/tsnake/highscore`, outside
  the inotify-watched plugins dir, so a stray write can no longer trigger a reload by
  itself — but a save during play would still reset the panel under the player

## Stage 1b — visual polish, from live screenshots (Brodie's play-test, 2026-10-03)

Brodie played it and said: everything too big (border, snake, fruit), menu in the
wrong place, "just looks messy". I can now drive it myself — `omarchy-shell shell
summon`, `grim`, `wtype` for keys — so every item below is judged against a
photograph, not against the code. Shots in `/tmp/tsnake_shots/`.

| # | Task | Owner | Status |
|---|---|---|---|
| 16 | Reproduce + photograph the overlay (summon / grim / wtype) | me | [x] 6 shots; measured the board out of the PNG pixels |
| 17 | Board sized while the window had no size → 10×6 board, 220 px cells | me | [ ] **root cause of "too big"** |
| 18 | Cap `cellSize` so no board can ever fill the screen again | me | [ ] |
| 19 | Border thickness + menu-card widths | me | [ ] |
| 20 | Center the pause / game-over cards (anchors rejected by QML, runtime-proven) | me | [ ] |
| 21 | `dismiss()` TypeError — `stopEngine()` after `hide()` destroys the item | me | [ ] |
| 22 | HUD / help-row heights and fonts | me | [ ] |
| 23 | Re-photograph and compare before/after until it looks right | me | [x] Over-corrected once: capping the cell at 18 px and letting the board fit the monitor produced ~190x78 cells of 18 px — a black field with a speck on it. Cell size now chosen for the eye (28 px) and the grid capped to a playable 80x40 |
| 24 | qmllint + validator on the changed overlay, commit | me | [ ] qmllint clean apart from the `qs.*` import warnings the first-party tree shares; commit pending Brodie's look |

## Stage 1c — it is a real window now, not a layer-shell overlay (Brodie's call, 2026-10-03)

Brodie asked whether turning the overlay into a normal app window — so he can
size and control it — would be a dramatic change. It was not: Quickshell 0.3.1
exposes `FloatingWindow`, which the **first-party** dev gallery already uses from
inside a plugin (`plugins/dev-gallery/GalleryPanel.qml:277`), so the swap is the
surface declaration plus the window-close guard.

| # | Task | Owner | Status |
|---|---|---|---|
| 25 | `PanelWindow` (layer-shell) → `FloatingWindow` (managed toplevel) | me | [x] `title`, `implicitWidth/Height`, `minimumSize` instead of `anchors`/`WlrLayershell.*`/`ExclusionMode`; layer-shell import dropped |
| 26 | Host must hear about a hyprland-side window close | me | [x] `onVisibleChanged → shell.hide(id)`, guarded by `closingFromHost` so `close()`/`dismiss()` don't call hide back at the host that is already tearing us down (idiom from `GalleryPanel.qml:286-290`) |
| 27 | Prove it is really managed | me | [x] `hyprctl clients -j`: `{class:"org.quickshell", title:"tsnake", floating:false, size:[1697,1382], at:[1729,14], pid:…}` — hyprland is tiling it. Screenshots `w1_windowed.png`, `w2_live.png` |
| 28 | Live resize re-fits the board | me | [ ] Hook is wired (`onWidthChanged`/`onHeightChanged → maybeSendSize`) and the board demonstrably derives from the window (3440 px wide ⇒ ~120 cols; 1697 px wide ⇒ ~57 cols, same 28 px cell). **Not driven by an actual resize**: this Hyprland takes dispatches as Lua (`hyprctl dispatch 'hl.dsp.focus({workspace="5"})'`, `Workspaces.qml:35`) and I could not find the resize/float function name — Brodie to grab a corner |
| 29 | Keys still reach the game without the exclusive grab | Brodie | [ ] focus is ordinary window focus now; arrows/`hpxrq` need his hand. `wtype p`/`r` did work from the shell side |

## Stage 1d — one background, no nested boxes (Brodie's eye, 2026-10-03)

"Box inside of a box, inside of a box. This would just be a window with our game
board with a background and instructions around that game board."

| # | Task | Owner | Status |
|---|---|---|---|
| 30 | Flatten the chrome — the window IS the card | me | [x] `Rectangle { id: card }` (themed fill + 1 px border + radius) deleted; its fill moved up to `FloatingWindow.color` (`menu.background`, solid, not the old translucent scrim — hyprland decorates this window now). Column/Canvas/MouseArea and the three menu cards are direct children of the window. `availW/availH` subtract ONE `windowMargin`, not `cardPadding + windowMargin`. Proof: `f1_flat.png`, `f2_live.png`, `f3_paused.png` and a journal with **no** QML warnings after `omarchy-restart-shell` |
| 31 | The hyprland rule must not error | me | [x] `centerwindow = "on"` was raising `helpers.lua:153: hl.window_rule: unknown field 'centerwindow'` (red config banner, `w4_centered.png`). Dropped — `centerwindow` is a windowrule *keyword*, not a field `hl.window_rule` accepts (`strings /usr/bin/Hyprland` has it; the Lua whitelist does not). `~/.config/hypr/looknfeel.lua` now reads `o.window({ title = "^tsnake$" }, { float = true })`; banner gone, `hyprctl clients` still says `floating:true, at:[974,204], size:[1493,1003]` ≈ centered on 3440x1440 |
| 32 | Live board legible at the fitted size | me | [x] `f2_live.png`: 51x30 board at 28 px cells, `$` tokens and the `>` head glyph both readable, HUD above / hints below the board |
| 33 | README tells the truth about installing it | me | [x] plugin folder named by manifest id, `omarchy plugin enable … --section right` (the form `omarchy-plugin-enable:6` documents), the `install -Dm755 snake` step, the new "It is a window, not an overlay" section with the float rule, and the stale "has not been played through Quickshell yet" line replaced |

Note on the GAME OVER card in `f1_flat.png`: not a bug — a fresh engine ticks
itself into the right wall in ~1.7 s (`wrap: 0` at start, 40 columns from x=10),
so any screenshot taken a second late shows a dead run. `f2`/`f3` are the same
window with `r` pressed just before the shutter.

`hl.dsp.window.center({window=w})` exists (`hl.dsp.window` exposes
`center,float,move,resize,pin,pseudo,…`) but moved the window 0 px, so nothing
dispatches it — centering is hyprland's own placement.

## Standing notes — reload behaviour, and a save that never lands

**Hot reload does not reload QML.** `DEBUG qml: Local plugin changed, reloading`
fires on every save, and the anchor warnings I had already deleted (`466:7`,
`505:7` — lines with no anchor in the new file at all) kept printing with the OLD
line numbers: Quickshell re-instantiates from its cached QML document. The only
reliable reload is `omarchy-restart-shell` (the official guarded helper; it
refuses while the session is locked). Verify a QML edit by the *absence* of its
warning after a restart, never after a save.

**Run is lost when the engine is torn down with the Loader (found 2026-10-03, NOT
fixed — needs Brodie's call).** After several overlay runs — including a death at
LEN 4 — `~/.local/state/tsnake/highscore` never appeared, while both engine-side
paths demonstrably work in isolation: `{"cmd":"flush"}`+`{"cmd":"quit"}` on stdin
wrote `3`, and `kill -TERM` wrote `3` (`terminate_handler`, `7a1e7c4`). The
overlay's only untested exit is the one Quickshell owns: with `keepLoaded:false`
the host destroys the Loader, `Component.onDestruction → stopEngine()` writes
flush+quit, and the same teardown destroys the `Process` — which kills the child
outright, before it ever reads its stdin or sees EOF. Candidate fixes: give the
engine a moment before the Process dies, or drop the deferral and let the engine
save on death — which is now harmless, since the state file left the inotify-watched
plugins tree in the first place ("nothing on disk while live" was the property the
deferral existed to protect, and it was chosen before that move).

Evidence for 17 (two independent lines, both agree):
- Pixel measurement of `01_fresh.png`: green border runs 622..656 and 2787..2821
  (35 px), board floor 2130 px wide, cell ≈ 220 px → board is **10 × 6**.
- Engine probe: with no `size` command the engine plays at 40×20; 10×6 is *exactly*
  the `MIN_BOARD_W/H` clamp, which only `desiredBoard()` produces when `availW/availH`
  are still the 2 px no-window fallback — and `sizeSent` then latches it, so nothing
  is ever re-sent. `maybeSendSize()` was wired to `onStarted` only.

Evidence for 20 and 21, from Quickshell's own log (not my reading of the file):
`WARN scene: QML QQuickRectangle ... Overlay.qml[505:7]: Cannot anchor to an item
that isn't a parent or sibling` (and `[466:7]`) — `anchors.centerIn: boardArea`
targets a descendant of a sibling, so both menus were left unanchored at the card's
top-left; and `TypeError: Property 'stopEngine' ... is not a function` at `[273:-1]`.

## Known latent engine bug (found by the suite's read-through, NOT fixed — needs Brodie's call)

`snake.c:340`, in `snake_bite`: `if (n > MAX_SNAKE - s->wound_len) n = ...;` then
`if (n <= 0) return;`. That returns *before* `s->len = depth`, so once the corpse queue
is saturated the bite severs nothing and `advance_one` pushes the head onto a live body
cell anyway — the snake silently overlaps itself, with no severing and no death.
Unreachable on any real board (it wants ~4096 un-faded corpses at once, and `WOUND_FADE`
is 55 ticks), so it is latent; the reason it is worth writing down is that the failure
mode is silent rather than loud. The fix is to treat "cannot sever" as "cannot bite" and
skip the push, or to drop the oldest corpses to make room.

Hygiene: `test_game` shows as untracked build output (`snake`/`test_hunt` are ignored);
one `.gitignore` line closes that.

## Stage 1e — the glyph lab: what characters can this app even use? (Brodie's ask, 2026-10-03)

Asked: which characters are available for designing the overlay, a summonable picker to
see them in, and reference sites. Answer delivered as `GlyphLab.qml` + prose + verified links.

| # | Task | Owner | Status |
|---|---|---|---|
| 34 | Coverage truth: which candidates the board font actually has | me | [x] `/tmp/cov.sh` — `fc-match "Adwaita Mono:charset=XXXX"` over 227 candidates: **183 native, 44 substituted**. Emoji always borrow (Noto Color Emoji); `27F5-27F7` borrow from JetBrainsMono Nerd Font |
| 35 | Icon truth: name the Nerd Font private-use glyphs from the font, not from memory | me | [x] 3714 PUA glyphs read out of `JetBrainsMonoNerdFont-Regular.ttf` by `/tmp/glyphnames.py` (hand-parsed `cmap` fmt4/12 + `post` 2.0). Guessed names for fire/tree/shield were **disproved** this way |
| 36 | Catalog generated, not hand-typed | me | [x] `/tmp/gen_catalog.py` → 9 shelves; names from `unicodedata` (UCD **16.0.0**), which is also the assignment check — an unassigned codepoint is dropped, because `fc-match` calls those "native" (the old probe's `26EAD` was exactly that lie) |
| 37 | `GlyphLab.qml`: shelves, font chips, click-to-assign, live preview, paste-ready set | me | [x] ~950 lines, loaded through a `Loader` so the game never pays for it; `{"mode":"glyphs"}` payload routes to it and **no engine starts** |
| 38 | Shell-warning-free after restart | me | [x] `journalctl --user` grep for `GlyphLab\|Overlay.qml` → **0** hits. Four delegates needed `required property var modelData` before a Repeater hands it over |
| 39 | Photo-driven fixes, each read off a screenshot | me | [x] title typo; head-glyph row clipped (the cell was height-capped, so the board bottom reached the canvas floor — the band is now budgeted *before* the cell is derived); font chips labelled in the font they name (Σταvδcard Σαμμβoλoς ΠΣ) → swatch in that face, label in `menuFamily`; empty field under the preview → board centred in its canvas; legend said "already in monospace" for a probe run against Adwaita Mono → `probeFont` |
| 40 | Reference sites, reachable or unnamed | me | [x] verified by HTTP status, not by search snippet: `unicode.org/charts/` 200, `nerdfonts.com/cheat-sheet` 200, `nerd-fonts/wiki/Glyph-Sets` 200, `fileformat.info/.../char/search.htm` 200, `compart.com/en/unicode/U+25C6` 200. **Dead**: `unicode.org/chararts/chararts.html` 404, `graphemica.com` 403, `symbl.cc` 401 |
| 41 | Hyprland float rule covers the lab window too | me | [x] **the earlier "eval never applies" verdict was wrong.** `hyprctl eval 'hl.window_rule({match={title="^tsnake$"}, pin=true, float=true})'` then a re-summon → client reports `float True pin True`. Window rules apply at **map** time, so the trick is close-then-summon, not `hyprctl reload`. Caveat: eval'd rules are runtime-only — they die at logout, so the `looknfeel.lua` line still needs one login to persist |
| 42 | Brodie picks the set, then the redesign pass | me+Brodie | [x] his pasted block is now the single `glyphs` table in `Overlay.qml` (`▲▼◀▶` head, `◆` body, `□` food, `◇` corpse). `AUTO HUNT`/`WRAP` stay text labels — his words: "the wrap text is wrong though keep that unchanged". `[ ]` his eyes on it: the scale multipliers are unverified by photo (see 43) |
| 43 | Ink correction for the glyph sizes | me | [x] `glyphScale` per role (body/corpse 1.18, food 1.05, head 1.0) — a mono glyph's ink is ~0.7 em, so the old shared `cell*0.82` drew the diamond at ~60% of the cell it replaced (the bead-chain screenshot). `[ ]` verified only as far as "compiles, paints, zero QML warnings" — see 44 for why no photo |
| 44 | Summoned window maps unfocused, behind the other windows, and self-hides seconds later | me | [ ] reproducible: summon → window exists ~3-6 s → it is gone from `hyprctl clients` and the engine is stopped with it (no orphan: no `snake --protocol` process survives). Pin+float did not raise it above Brodie's terminals, so a photo of the board needs Brodie to click it or summon it himself. This is the same seam as row 29 (keyboard feel without the layer-shell grab) — likely the host hiding the panel on focus loss |
