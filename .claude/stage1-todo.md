# Stage 1 — tsnake as a local Omarchy plugin (+ unit tests)

Scope: **Brodie's machine only.** No marketplace work, no prebuilt-binary decision,
no `preview.png`, no publishing. Plan of record: `.claude/omarchy-plugin-plan.md`.

Owner key: `me` = Claude, `qml` = qml-plugin subagent, `ut` = unittests subagent,
`Brodie` = human play-test.

| # | Task | Owner | Status |
|---|---|---|---|
| 1 | De-mirror the lifted test ban in `omarchy-plugin-plan.md` | me | [ ] |
| 2 | Verify Omarchy/quickshell environment on this box | me | [ ] |
| 3 | `snake --protocol`: NDJSON frame emit + command read, self-ticking | me | [ ] |
| 4 | `snake --state <path>`: engine-owned file, hardened read, flush-only writes | me | [ ] |
| 5 | `--square-cells`: 2-cell aspect stride becomes a renderer-side option | me | [ ] |
| 6 | `make` warning-free under `-Wall -Wextra` (both targets) | me | [ ] |
| 7 | Unit tests for the mechanics behind the ncurses seam | ut | [ ] |
| 8 | `manifest.json` at repo root (`overlay` + `bar-widget`) | qml | [ ] |
| 9 | `Overlay.qml`: PanelWindow/Overlay layer, exclusive focus, raw `Keys.onPressed`, board | qml | [ ] |
| 10 | `BarWidget.qml`: bar button that toggles the overlay | qml | [ ] |
| 11 | Engine lifecycle: start on `open()`, kill on `close()`/`dismiss()`/`onDestruction` | qml | [ ] |
| 12 | Save data: read at `open()`, flush only after the overlay is closed | qml + me | [ ] |
| 13 | Plugin install into `~/.config/omarchy/plugins/` + `omarchy plugin validate` + `qmllint` | me | [ ] |
| 14 | Human play-test: does it feel like the terminal game | Brodie | [ ] |
| 15 | README: install, removal, keybind line (local-facing only) | qml | [ ] |

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
  is closed (the plugins dir is inotify-watched: a write during play kills the game)
