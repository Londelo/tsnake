import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// tsnake overlay: the front-end for `snake --protocol` — the same game the
// terminal build plays, with the curses face swapped for this window. The engine
// goes DOWN before it goes UP: a hidden panel unloads its item and kills its
// Process, so `shown` alone can leave the last engine's last frame still painting.
//
// Letter shortcuts must match `event.text`, not Qt.Key_<letter>: this QML's Qt
// object has no Key_h member (that is why `h`/`p`/`r`/`q` read event.text; Shift+h
// arrives as "H" and matches nothing).
//
// Quickshell 0.3.1 SplitParser/Process traps: splitMarker counts BYTES and flushes
// on "\n"; clearOnExit defaults to TRUE (this file's last-frame path is covered by
// stopEngine() + killTimer, and no first-party QML sets it false); there is no
// flush()/waitForFinished(), so a restart() mid-run would orphan the old engine.
//
// Shape from plugins/emojis/Emojis.qml (host-injected shell/manifest) and
// dev-gallery/GalleryPanel.qml:277 — a FloatingWindow, i.e. a real hyprland-managed
// toplevel: movable, resizable, tileable, decorated; ordinary window focus.
Item {
  id: root

  // ------------------------------------------------------- host-injected
  // shell.qml:1338-1344 assigns these onto the loaded item when present.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  // The host reads item.opened to decide summon-vs-hide (shell.qml:1205).
  property bool opened: false

  // Set from the summon payload (`{"mode":"glyphs"}`): the glyph lab comes up
  // instead of the game, and NO engine starts. The lab is a design tool — a
  // self-ticking AI snake behind the catalogue would be noise, and a second
  // writer of the high-score file.
  property bool labMode: false

  // True only while WE are the ones hiding the window, so the window's
  // onVisibleChanged doesn't call host hide() back at the host that is already
  // hiding us (and, in dismiss()'s case, is about to tear this item down).
  property bool closingFromHost: false

  readonly property string pluginId: "io.github.londelo.tsnake"

  // -------------------------------------------------------------- glyph set
  // The board's alphabet, in ONE place, keyed exactly the way the glyph lab's
  // slots are keyed (GlyphLab.qml `roles`) so a `c`-copied set from the lab maps
  // onto this table cell for cell.
  //
  // This is Brodie's pick out of the lab (2026-10-03), not a guess of mine. Every
  // one of the seven is `c:0` in the lab's catalog — native to the board face
  // (Adwaita Mono, what `monospace` resolves to), which is what makes them safe:
  // a substituted glyph arrives with a different advance width and stops sitting in
  // its cell. `AUTO HUNT` and `WRAP` stay as text labels (hudRight); the terminal
  // build keeps its own `^ v < > o $` and is a different face of the game.
  readonly property var glyphs: ({
    headUp: "▲",      // U+25B2 BLACK UP-POINTING TRIANGLE
    headDown: "▼",    // U+25BC BLACK DOWN-POINTING TRIANGLE
    headLeft: "◀",    // U+25C0 BLACK LEFT-POINTING TRIANGLE
    headRight: "▶",   // U+25B6 BLACK RIGHT-POINTING TRIANGLE
    body: "◆",        // U+25C6 BLACK DIAMOND
    food: "□",        // U+25A1 WHITE SQUARE
    corpse: "◇"       // U+25C7 WHITE DIAMOND
  })

  // Glyph size as a multiple of the cell. Not cosmetic tuning — it is an ink
  // correction. A monospace glyph's INK is roughly 0.7 em, not 1 em (the em box
  // includes the advance and the leading), so drawing at `cell * 0.82` put the
  // diamond at about 60% of the cell it was replacing: the old body was a solid
  // `fillRect` edge to edge, and the bead-chain screenshot is what that mismatch
  // looked like. Above 1.0 deliberately — a diamond's ink spans corner to corner
  // of its em, so this is where it finally touches the cell it lives in.
  readonly property var glyphScale: ({ body: 1.18, corpse: 1.18, food: 1.05, head: 1.0 })

  // The plugin's own folder, resolved from where THIS file actually is — not a
  // hardcoded path, because the same item gets loaded out of a clone, a symlink or the
  // dev checkout. Qt.resolvedUrl(".") is a file:// URL ending in "/".
  // Used for ONE thing only: finding the engine binary. Nothing that gets written lives
  // here — see stateDir.
  readonly property string pluginDir: {
    var u = String(Qt.resolvedUrl("."))
    if (u.lastIndexOf("file://", 0) === 0) u = u.slice(7)
    if (u.endsWith("/")) u = u.slice(0, -1)
    return u
  }

  // ---------------------------------------------------------- state paths
  // The record and the card's two answers live under the XDG state root, in a folder of
  // their own: `$XDG_STATE_HOME/tsnake`, else `~/.local/state/tsnake`. QML only hands the
  // engine these two paths on argv and writes no file at all (no Settings object either):
  // the engine is the only writer, and it writes the INSTANT the number is beaten or the
  // card changes — save_highscore()/save_setup() in snake.c. The engine also mkdir -p's the
  // parent chain (ensure_parent_dir), so a fresh machine needs nothing from QML.
  //
  // Being OUTSIDE ~/.config/omarchy/plugins is the entire point of this block. The shell
  // inotify-watches that whole tree for close_write/create/delete/move
  // (PluginRegistry.qml:663) and reloads every plugin on any change to a NON-hidden path,
  // and localPluginIdForPath treats only a LEADING "." on the top-level entry as hidden
  // (:735) — a nested dot-file hides nothing. So a save inside the watched folder is a
  // panel reload during play: the game dies under the player because they ate something.
  // That single constraint is why the engine used to BANK both saves and write them once,
  // on the way out — and the way out never arrives. `hide()` unmounts this item and
  // Quickshell 0.3.1's Process destructor SIGKILLs the running child with the
  // `flush`+`quit` write still buffered inside QProcess; that API offers exec, signal and
  // write, and has no flush, no closeStdin, no terminatedType to wait for. Measured
  // against the installed engine: quit/SIGTERM/EOF wrote the files, kill -9 and plain
  // abandonment wrote nothing — so in the only configuration that mattered, banking saved
  // nothing, ever. "The record hits disk the moment it is beaten" cannot be honored by a
  // file somebody is watching, so the files moved.
  //
  // The price, said out loud: `omarchy plugin remove` only ever deletes
  // $PLUGINS_DIR/$id (bin/omarchy-plugin-remove:10,:71), so an uninstall now leaves
  // ~/.local/state/tsnake standing. Player history outranks a spotless uninstall.
  //
  // And there is deliberately NO fallback to the plugin folder for these two files, in
  // either direction: one home for the record, or a card that reads one number and writes
  // another.
  readonly property string stateDir: {
    var s = String(Quickshell.env("XDG_STATE_HOME") || "")
    if (s === "") s = String(Quickshell.env("HOME") || "") + "/.local/state"
    while (s.endsWith("/")) s = s.slice(0, -1)
    return s + "/tsnake"
  }
  readonly property string stateFile: stateDir + "/highscore"
  // The card's own two answers (wrap, tick_ms) live beside the record, and the ENGINE
  // reads and writes them — this file never does. That is why the card needs no Settings
  // object: it paints wrap and speed out of frames, and the engine loads the saved ones
  // before its first frame exists, so what you left is what comes back.
  readonly property string setupFile: stateDir + "/setup"
  // Both empty only on a machine with neither XDG_STATE_HOME nor HOME, where there is no
  // sane absolute path to name. Then pass nothing and let the engine use its own defaults
  // rather than hand it "/.local/state/…", a root it could never mkdir.
  // A root-ish state root means the environment was pathological (a menu row runs
  // with an empty env — see uninstall.sh); pass nothing rather than "/.local/state".
  // Full story: docs/decisions.md.
  readonly property bool stateUsable: stateDir.length > 1 && stateDir !== "/tsnake"

  // Engine binary resolution order: an explicit TSNAKE_BIN (debugging), then the copy
  // installed WITH the plugin (install.sh builds snake into the plugin folder), then the
  // auto-built binary in the state root (buildProc below). Nothing here names a personal
  // checkout: a marketplace clone has no dev build beside it, and an absolute path to
  // one machine's home folder is litter on every other machine.
  property int engineIndex: 0
  property bool engineFailed: false
  property var engineStderr: []

  // ------------------------------------------------------- auto-install
  // A marketplace `plugin add` clones, validates, places — and runs NOTHING. Measured:
  // omarchy-plugin-enable spawns no code, PluginRegistry.qml spawns no code, and there
  // is no lifecycle hook anywhere under /usr/share/omarchy. The only code a plugin can
  // run on its own is its own QML, so the first summon builds the engine itself. The
  // build lands in the STATE ROOT, never in the watched plugin folder: a create event
  // there reloads the panel mid-build, and folder churn under a running shell poisons
  // its type index (see the scar tissue above). `make` is idempotent — when the binary
  // is current it exits in milliseconds; after a `plugin update` (which reset --hard's
  // the source) the next summon rebuilds, so a stale binary never outlives its source.
  readonly property string buildDir: stateUsable ? stateDir + "/build" : ""
  readonly property string buildTarget: buildDir === "" ? "" : buildDir + "/snake"

  function engineCandidates() {
    var out = []
    var envBin = String(Quickshell.env("TSNAKE_BIN") || "")
    if (envBin !== "") out.push(envBin)
    out.push(root.pluginDir + "/snake")
    if (root.buildTarget !== "") out.push(root.buildTarget)
    return out
  }

  // ------------------------------------------------------- engine protocol
  // NDJSON both ways. Frames are COMPLETE snapshots and are never diffed, so
  // a dropped frame skips one paint and nothing else. The engine self-ticks
  // every 55 ms and emits a frame per tick plus one after any input change —
  // QML must never drive ticks, or QML stutter becomes game lag.
  readonly property int woundFade: 55      // mirrors WOUND_FADE, snake.c:29

  property int bw: 10
  property int bh: 6
  property int alive: 1
  property int paused: 0
  property int wrapOn: 0
  property int huntOn: 0
  property int flash: 0
  property int len: 0
  property int best: 0
  property int dirX: 1
  property int dirY: 0
  property var bodyPts: []
  property var woundPts: []
  property var foodPts: []
  property int frameSerial: 0              // bump ⇒ repaint
  property bool gotFrame: false

  // ------------------------------------------------------- the run's setup
  // The setup card's two settings, and they are the ENGINE's numbers, read out of
  // every frame — the card never keeps an opinion of its own. `started` is 0 until
  // the player presses START; the engine will not advance, steer, pause, or re-tune
  // a run that has not begun, and refuses wrap/speed edits once it has.
  property int started: 0
  property int tickMs: 55
  // While the thumb is being dragged (and until the frame that confirms the edit
  // arrives) this holds the value the player asked for. PanelSlider resets its knob
  // to `value` the moment you let go, so without this the slider snaps back for a
  // frame and looks broken.
  property int askedMs: -1
  // ...but only for a few frames. A command the engine never honours — a speed edit
  // sent after START, which it is entitled to ignore — must not strand the knob at a
  // value that does not exist.
  property int askedGraces: 0
  // snake.c's TICK_MS. One copy in this file: the slider is authored in multiples
  // of it, so 1.0× means "the speed the game has always had".
  readonly property int baseTickMs: 55
  readonly property int shownMs: root.askedMs >= 0 ? root.askedMs : root.tickMs
  readonly property real speedMult: root.shownMs > 0 ? root.baseTickMs / root.shownMs : 1.0
  // The slider's ends, in multiples: half speed to double speed, 1.0× in the middle.
  // The engine's own guards (MIN/MAX_TICK_MS in snake.c) sit OUTSIDE this range, so a
  // thumb that cannot leave [0.5×, 2×] can never press against them.
  readonly property real speedLo: 0.5
  readonly property real speedHi: 2.0

  // The slider speaks multiples because that is what a player can reason about; the
  // engine speaks milliseconds because that is what a tick is. This is the only
  // translation between the two, and it is deliberately one-directional per call.
  function msForMult(m) {
    var clamped = Math.max(root.speedLo, Math.min(root.speedHi, m))
    return Math.round(root.baseTickMs / clamped)
  }

  // Both numbers in this string are derived from the SAME millisecond value, so the
  // "×" and the "ms" can never contradict each other (they would if the multiple were
  // snapped to the slider's detents independently: 41 ms is 1.34×, not 1.35×).
  readonly property string speedLabel: {
    var t = root.speedMult.toFixed(2) + "×   " + root.shownMs + " ms"
    return root.shownMs === root.baseTickMs ? t + "   (default)" : t
  }

  readonly property bool menuUp: root.opened && (root.alive === 0 || root.paused === 1)
  // The opening order, Brodie's call 2026-10-13: BLACK SCREEN first — the window shows
  // nothing but its background while the engine is built and forked — then the engine's
  // FIRST FRAME, then the setup card. The card is the engine's own answer, never an
  // opinion: every number it shows (wrap, speed, LEN, BEST) arrives in that frame, so it
  // cannot appear, correct itself a beat later, and it cannot offer controls for a board
  // that does not exist yet. The same gate holds the HUD and the help row off the black
  // screen, so the whole surface arrives together. What keeps it honest is engineFailed:
  // an engine that never shows is caught by the watchdog, and the black screen makes way
  // for the error panel. (This reverses the 2026-10-10 "card the instant the window is"
  // decision, which traded a two-beat pop-in for a card that could speak before the
  // engine could. The full story is in docs/decisions.md.)
  readonly property bool setupUp: root.gotFrame && root.opened && root.started === 0
                                 && root.alive === 1 && !root.engineFailed

  // --------------------------------------------------- exactly one cell map
  // Drawing and click→board mapping both go through boardLeft/boardTop/
  // cellSize, so pointing and painting cannot drift. This is the guard the
  // terminal build implements as CELL_TOP/CELL_LEFT, which draw() writes with
  // and handle_click() reads through.
  //
  // Sizes come off the WINDOW, one way only: hyprland sizes the window, the
  // window sizes the board. There is no inner card to size in between any more
  // (see FloatingWindow), so cellSize never feeds anything back upward.
  // Rows sized off their own font, the way plugins/emojis/Emojis.qml:36 sizes its
  // header (`max(space(34), Style.font.title + controlPaddingY * 2)`). A flat
  // space(20) row holding a bold title-size label clipped the descenders.
  readonly property real hudHeight: Math.max(Style.space(28),
    Style.font.title + Style.spacing.controlPaddingY * 2)
  readonly property real helpHeight: Math.max(Style.space(22),
    Style.font.body + Style.spacing.controlPaddingY * 2)
  // Padding INSIDE the menu cards only (pause / game-over / engine-missing).
  // They are the only boxes left in the window besides the board itself.
  readonly property real cardPadding: Style.space(24)
  // The one gap in the whole surface: play field to WINDOW frame. Without an
  // explicit inset the board's own border sits a hair off the window edge and
  // reads as part of the chrome rather than as the play field. Brodie's "a
  // little gap between the game and the frame".
  readonly property real windowMargin: Style.space(30)
  readonly property real availW: panel.width > 0
    ? Math.max(2, panel.width - windowMargin * 2) : 2
  readonly property real availH: panel.height > 0
    ? Math.max(2, panel.height - windowMargin * 2 - hudHeight - helpHeight
                 - Style.spacing.md * 2) : 2

  // Square cells by construction: one cell size for both axes. FIT is only half
  // of it — the other half is CAP. cellSize is derived by fitting whatever board
  // the engine reports into the window, so an unsized board is stretched to fill
  // the screen: at 10x6 that measured out at ~220 px a cell, a 35 px border, and
  // a snake as wide as a third of the monitor. Capping at cellTarget means a
  // board the overlay failed to size reads as a small centered card — which is
  // the truth — instead of a mosaic nobody can play.
  readonly property real cellSize: (root.bw > 0 && root.bh > 0 && panel.width > 1 && panel.height > 1)
    ? Math.max(2, Math.min(root.cellTarget,
        Math.floor(Math.min(root.availW / root.bw, root.availH / root.bh))))
    : 2
  readonly property real boardLeft: (boardArea.width - cellSize * root.bw) / 2
  readonly property real boardTop: (boardArea.height - cellSize * root.bh) / 2

  function cellLeft(col) { return root.boardLeft + col * root.cellSize }
  function cellTop(row) { return root.boardTop + row * root.cellSize }
  function colAt(px) { return Math.floor((px - root.boardLeft) / root.cellSize) }
  function rowAt(py) { return Math.floor((py - root.boardTop) / root.cellSize) }

  // Target cell the board dimensions are planned against, and the ceiling on
  // cellSize; the engine clamps the board to 10..400 x 6..250 and the frame's
  // w/h stay the source of truth.
  //
  // Fitting the board to the WINDOW alone is what made it unreadable both ways:
  // unsized it was 10x6 at ~220 px a cell, and once sized it became ~190x78 at
  // 18 px — a black field with a speck on it. Cell size has to be chosen for the
  // EYE first (a `$` and a `>` glyph are only legible above ~24 px), and the grid
  // then capped to a playable count so a big monitor buys chunkier cells, not a
  // bigger empty board.
  readonly property int cellTarget: Math.max(10, Style.space(28))
  readonly property int maxCols: 80
  readonly property int maxRows: 40

  function desiredBoard() {
    var w = Math.floor(root.availW / root.cellTarget)
    var h = Math.floor(root.availH / root.cellTarget)
    return { w: Math.max(10, Math.min(root.maxCols, w)),
             h: Math.max(6, Math.min(root.maxRows, h)) }
  }

  property string sizeSent: ""

  function maybeSendSize() {
    if (!engineProc.running) return
    // Refuse to ask while the window has no size yet. availW/availH fall back to
    // 2 px, desiredBoard clamps that to the engine's 10x6 floor, and sizeSent
    // then LATCHES the mistake — `onStarted` was the only caller, so the overlay
    // played the whole run on a 10x6 board fit to the screen at ~220 px a cell.
    // Sizing is now re-asked on every panel width/height change instead.
    if (panel.width <= 1 || panel.height <= 1) return
    var d = root.desiredBoard()
    var key = d.w + "x" + d.h
    if (key === root.sizeSent) return
    root.sizeSent = key
    root.send({ cmd: "size", w: d.w, h: d.h })
  }

  // Menu cards are sized in ABSOLUTE terms, only capped by the board. A bare
  // "0.6 * board width" reads fine on a small board and as a ~2000 px slab over
  // a 3440 px one, which is most of what "looks messy" was.
  function menuWidth(boardW) {
    return Math.max(Style.space(260), Math.min(Style.space(560), boardW * 0.55))
  }

  // -------------------------------------------------------------- lifecycle
  // The #1 leak risk: a child left running grinds BFS invisibly for the rest
  // of the session, and with keepLoaded=false the Loader is torn down on every
  // hide and every hot reload — so HIDDEN MEANS NO PROCESS, on all three exits.
  // Whether the current attempt still has to prove itself with a frame. ONE
  // owner flips it, so the watchdog and onExited can never both consume a
  // candidate and skip past a binary that would have worked.
  property bool launchPending: false

  function startEngine() {
    if (engineProc.running) return
    root.engineFailed = false
    root.engineStderr = []
    root.gotFrame = false
    root.engineIndex = 0
    root.clearFrame()
    // Build first, launch after: with a current binary `make` is a no-op that exits
    // in milliseconds, and the launch happens in buildProc's onExited. No state root
    // to build in, or a build already running? Go straight to (or wait on) the
    // candidates.
    if (root.buildDir !== "" && !buildProc.running) buildProc.running = true
    else if (!buildProc.running) root.launchCandidate()
  }

  function launchCandidate() {
    var cands = root.engineCandidates()
    if (root.engineIndex >= cands.length) {
      root.engineFailed = true
      root.launchPending = false
      return
    }
    var argv = [cands[root.engineIndex], "--protocol", "--square-cells"]
    // The engine's two files, named by the one side that knows where the state root is
    // (see stateDir). The engine does the reading and the writing; this is only argv.
    if (root.stateUsable) argv = argv.concat(["--state", root.stateFile, "--setup", root.setupFile])
    engineProc.command = argv
    root.launchPending = true
    engineProc.running = true
    startWatchdog.restart()
  }

  // A failed attempt: take down whatever is up, try the next candidate, and
  // once the list is dry the overlay says so and names what it tried. The
  // relaunch goes through callLater so it never runs inside the dying
  // process's own handler.
  function attemptFailed() {
    if (!root.launchPending) return
    root.launchPending = false
    startWatchdog.stop()
    if (engineProc.running) engineProc.running = false
    root.engineIndex = root.engineIndex + 1
    Qt.callLater(function() { root.launchCandidate() })
  }

  function onEngineExited() {
    // A frame already proved this binary, so an exit now is either the quit
    // this overlay asked for or a crash. Anything else is a failed attempt.
    if (root.gotFrame) {
      root.sizeSent = ""
      if (root.opened) root.engineFailed = true   // the player watched it die
      return
    }
    root.attemptFailed()
  }

  function stopEngine() {
    root.launchPending = false
    startWatchdog.stop()
    if (!engineProc.running) return
    // Order is load-bearing, not cosmetic: close()/dismiss() set opened=false FIRST, so by
    // the time this runs the surface is down and the shell is free to tear this Loader
    // apart. Nothing in this pair is a save any more — the engine put the record on disk
    // the moment it was beaten and the card the moment it changed (snake.c:save_highscore,
    // save_setup) — it only asks the child to exit politely. killTimer is what fires when
    // the polite answer never arrives, and losing it costs nothing now.
    engineProc.write("{\"cmd\":\"flush\"}\n{\"cmd\":\"quit\"}\n")
    killTimer.restart()
  }

  function send(obj) {
    if (engineProc.running) engineProc.write(JSON.stringify(obj) + "\n")
  }

  // Blank the board AND the status line. A fresh engine that has not emitted a
  // frame yet must not inherit the last run's AUTO HUNT / WRAP labels or LEN/BEST
  // numbers: those are painted straight from these properties, with nothing on
  // screen to contradict them.
  function clearFrame() {
    root.bodyPts = []
    root.woundPts = []
    root.foodPts = []
    root.alive = 1
    root.paused = 0
    root.flash = 0
    root.huntOn = 0
    root.wrapOn = 0
    root.len = 0
    root.best = 0
    root.dirX = 1
    root.dirY = 0
    // A fresh engine is a fresh setup: it has not been started, and nothing of the last
    // run's setup survives here — these are PLACEHOLDERS for the one frame's worth of
    // silence before the engine speaks, not the values the card will show. The engine
    // loads the SAVED wrap and speed before it emits anything, so the numbers the player
    // left are the numbers that arrive; blanking to the defaults is what keeps a broken
    // engine from wearing the last run's clothes.
    root.started = 0
    root.tickMs = root.baseTickMs
    root.askedMs = -1
  }

  // ------------------------------------------------------- setup card actions
  // Every one of these writes the ENGINE and waits for the frame to say it took.
  // The terminal build's `x` key still toggles wrap mid-run; the overlay's player
  // chose wrap before START and cannot change it after, which is the whole point of
  // putting it on a setup card.
  function toggleWrap() {
    if (root.started !== 0) return
    root.send({ cmd: "wrap", on: root.wrapOn === 1 ? 0 : 1 })
  }

  // ms, not a multiple: the engine's unit is the tick, and the clamp that keeps a
  // nonsense value from producing a busy-spin or a frozen game lives in snake.c.
  // Deduped against the value already IN FLIGHT, not against root.tickMs: comparing
  // to the engine's last-known tick would swallow a drag back toward the current
  // speed and leave the readout naming the ms the thumb just left.
  function setSpeed(ms) {
    if (root.started !== 0) return
    var want = Math.round(ms)
    if (want === root.askedMs) return
    root.askedMs = want
    root.askedGraces = 3
    root.send({ cmd: "speed", ms: want })
  }

  function startRun() {
    root.send({ cmd: "start" })
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function onFrameLine(line) {
    var t = String(line).trim()
    if (t === "" || t.charAt(0) !== "{") return
    var f
    try { f = JSON.parse(t) } catch (e) { return }
    if (!f || f.event !== "frame") return

    // Parsed always — even under a menu. Only the PAINTING is gated on
    // alive/paused, never the parser.
    root.gotFrame = true
    // A frame is the proof the binary works; the failover watchdog stands down.
    root.launchPending = false
    startWatchdog.stop()
    root.bw = f.w | 0
    root.bh = f.h | 0
    root.alive = f.alive | 0
    root.paused = f.paused | 0
    root.wrapOn = f.wrap | 0
    root.huntOn = f.hunt | 0
    root.flash = f.flash | 0
    root.len = f.len | 0
    root.best = f.best | 0
    root.dirX = (f.dir && f.dir.length > 0) ? (f.dir[0] | 0) : 1
    root.dirY = (f.dir && f.dir.length > 1) ? (f.dir[1] | 0) : 0
    root.started = f.started | 0
    if ((f.speed | 0) > 0) {
      root.tickMs = f.speed | 0
      // The engine's answer has caught up with the drag: hand the knob back to the
      // real number. An edit the engine refused (a speed sent after START, say) runs
      // out of graces and the knob goes back to the truth — but not mid-drag, where
      // a per-frame decrement would make the readout flicker under the thumb.
      if (root.askedMs >= 0) {
        if (root.askedMs === root.tickMs) {
          root.askedMs = -1
          root.askedGraces = 0
        } else if (!speedSlider.dragging && --root.askedGraces <= 0) {
          root.askedMs = -1
          root.askedGraces = 0
        }
      }
    }
    root.bodyPts = f.body || []
    root.woundPts = f.wound || []
    root.foodPts = f.food || []
    root.frameSerial++
  }

  function open(payloadJson) {
    root.closingFromHost = false
    root.opened = true
    root.sizeSent = ""

    // The payload is the host's, not the engine's: shell.qml:1152-1189 stashes
    // whatever JSON `summon`/`toggle` was handed and delivers it to open(), so
    // `omarchy-shell shell summon <id> '{"mode":"glyphs"}'` arrives here as-is.
    // Anything unparseable is simply the plain game — a typo in a summon
    // argument must not leave Brodie with no window at all.
    root.labMode = false
    if (payloadJson && payloadJson.length > 0) {
      try {
        var p = JSON.parse(payloadJson)
        if (p && p.mode === "glyphs") root.labMode = true
      } catch (e) {
        root.labMode = false
      }
    }

    if (root.labMode) return   // the lab owns the screen; no engine, no sizing
    root.startEngine()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    // Ask again after layout, from whichever of the two moments turns out to
    // have a real window size — the engine's `onStarted` may well fire first.
    Qt.callLater(function() { root.maybeSendSize() })
  }

  function close() {
    root.closingFromHost = true
    root.opened = false
    root.labMode = false
    root.stopEngine()
  }

  function dismiss() {
    root.closingFromHost = true
    root.opened = false
    root.labMode = false
    // stopEngine BEFORE hide, not after it. With `keepLoaded: false` the host's
    // hide() tears this whole item down, so the call that followed it landed on
    // a dead object: "TypeError: Property 'stopEngine' ... is not a function",
    // logged by Quickshell against this file. That bug was invisible for the same
    // reason the save itself was: nothing was riding on this call any more, because
    // the engine writes as it plays (snake.c:save_highscore) instead of waiting to be
    // asked on the way out — the destructor's SIGKILL used to arrive holding the run.
    root.stopEngine()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || root.pluginId)
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // ---------------------------------------------------------------- engine
  Process {
    id: engineProc
    running: false
    stdinEnabled: true

    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(line) { root.onFrameLine(line) }
    }
    stderr: SplitParser {
      splitMarker: "\n"
      onRead: function(line) {
        var t = String(line).trim()
        if (t === "") return
        var next = root.engineStderr.slice(-4)
        next.push(t)
        root.engineStderr = next
      }
    }

    onStarted: root.maybeSendSize()

    // No parameter list, matching the first-party handlers (clipboard/
    // Clipboard.qml:271, :291): naming the signal's typed parameters makes the
    // linter demand QProcess::ExitStatus, which it cannot resolve here, and
    // nothing in this file reads the exit code anyway.
    onExited: root.onEngineExited()
  }

  // One-shot build for the auto-install above. `cp -u` keeps the sources in buildDir
  // honest — make compares timestamps, and without the copy an updated snake.c in the
  // plugin folder could look older than a stale binary. A failed build is not fatal:
  // the candidate list still gets its turn, and the failure card speaks only when
  // every candidate is dry (build stderr rides along to say why).
  Process {
    id: buildProc
    running: false
    command: ["bash", "-c",
      "mkdir -p '" + root.buildDir + "' && cp -u '" + root.pluginDir + "/snake.c' '" +
      root.pluginDir + "/Makefile' '" + root.buildDir + "'/ && make -C '" +
      root.buildDir + "' snake"]

    stderr: SplitParser {
      splitMarker: "\n"
      onRead: function(line) {
        var t = String(line).trim()
        if (t === "") return
        var next = root.engineStderr.slice(-4)
        next.push(t)
        root.engineStderr = next
      }
    }

    onExited: {
      // Summoned but not yet playing ⇒ the build was the prelude and the engine is
      // next. If the window closed while make ran, this returns without launching.
      if (root.opened && !root.gotFrame) root.launchCandidate()
    }
  }

  // No frame by now ⇒ this candidate is not the engine. `started` alone proves
  // nothing (a binary can exec and say nothing), and QProcess's errorOccurred
  // is exposed in Quickshell 0.3.1 as an overridable Method rather than a
  // signal, with no first-party user in the shell tree — so this watchdog, not
  // that hook, is what detects a missing binary. The engine emits its opening
  // frame before its first tick, so 1500 ms is generous, not tight.
  Timer {
    id: startWatchdog
    interval: 1500
    repeat: false
    onTriggered: root.attemptFailed()
  }

  // `quit` normally ends the child by itself. This only fires if it ignored
  // quit — and whether the write ever reached the pipe no longer matters at all:
  // when the Loader tears this Process down the destructor kills the child, and
  // the record it was holding was already on disk when it was beaten. Both files
  // are written by the engine as it plays; nothing here is load-bearing.
  Timer {
    id: killTimer
    interval: 600
    repeat: false
    onTriggered: if (engineProc.running) engineProc.signal(15)
  }

  Component.onDestruction: root.stopEngine()

  // ------------------------------------------------------------ the surface
  // A real, hyprland-managed toplevel — NOT a layer-shell overlay. Layer-shell
  // surfaces are unmanaged by definition: no decorations, no tiling, no
  // user-resize, so the game could only ever be a fixed slab on top of the
  // desktop. Quickshell 0.3.1 exposes `FloatingWindow` for this (an XDG toplevel
  // hyprland will tile, float, move, decorate and resize), and the first-party
  // dev-gallery plugin uses it from inside a plugin
  // (plugins/dev-gallery/GalleryPanel.qml:277), which is also proof the host's
  // Loader + summon path works for it.
  //
  // The board follows the window instead of the monitor: sizing is re-asked on
  // every width/height change, so dragging a resize or un-floating the window
  // hands back a bigger or smaller grid rather than a stretched one.
  //
  // One surface, ONE background: the window itself is the card. There used to be
  // a `Rectangle { id: card }` inside it — themed fill, 1 px border, rounded
  // corners — holding a board that drew its own border on its own floor, which
  // read as a box inside a box inside a box (window chrome, card, board). Brodie's
  // fix is the flat one: a window with a background, the board in it, and the
  // instructions around the board. So the fill moved up here, and the board's own
  // border + the two centred menu cards are the only edges left.
  //
  // Solid theme fill, not the old translucent scrim: hyprland now decorates and
  // rounds this window, and a scrim over a managed window just washes out and
  // lets whatever was tiled behind it show through the play field.
  // The glyph lab, as a SIBLING of the game window rather than a child: the
  // Loader keeps this file out of the game's compile unit entirely, so a broken
  // GlyphLab.qml takes the lab down and leaves the board playable. Nothing here
  // starts until a summon carries {"mode":"glyphs"}.
  Loader {
    id: labLoader
    active: root.opened && root.labMode
    source: "GlyphLab.qml"
    onLoaded: if (item) item.host = root
  }

  FloatingWindow {
    id: panel
    visible: root.opened && !root.labMode
    title: "tsnake"
    color: Color.menu.background.toString()
    implicitWidth: Style.space(1280)
    implicitHeight: Style.space(860)
    // 10x6 is the engine's own floor (MIN_BOARD_W/H); 420x360 is what that needs
    // at the target cell plus the HUD and help rows.
    minimumSize: Qt.size(Style.space(420), Style.space(360))

    // The board is planned against THIS window, and the window is not guaranteed
    // to have a size at the instant the engine starts — so sizing is a standing
    // question asked whenever the size moves, not a one-shot on `onStarted`. Now
    // also the resize hook: hyprland resizes it, the board re-fits.
    onWidthChanged: root.maybeSendSize()
    onHeightChanged: root.maybeSendSize()

    // Hyprland can close this window from under us (window kill, a keybind, the
    // decorations). The host has to hear about it, or its `openPanelIds` keeps an
    // id for a window that is gone and the bar button then hides an already
    // hidden panel — the same stale-id trap `q` avoids by calling dismiss()
    // rather than close(). Mirrors GalleryPanel.qml:286-290, guard and all.
    onVisibleChanged: {
      if (!visible && !root.closingFromHost && root.shell
          && typeof root.shell.hide === "function")
        root.shell.hide((root.manifest && root.manifest.id) || root.pluginId)
    }

    Column {
      id: boardColumn
      anchors.centerIn: parent
      width: boardArea.width
      spacing: Style.spacing.md

      Item {
        id: hud
        width: parent.width
        height: root.hudHeight
        // Black screen until the engine speaks: LEN 0 / LAST HIGH SCORE 0 would be
        // the overlay inventing numbers the first frame has not confirmed (opening
        // order, see setupUp).
        visible: root.gotFrame

        Text {
          id: hudLeft
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          // The number is `best` straight out of engine frames, which is the record AS IT
          // STANDS ON DISK (snake.c:best_len) and rises the instant the run beats it — the
          // save is no longer waiting for the window to close. The word stays LAST because
          // it is what the record has always been called on this card; while a record run is
          // in progress it climbs with LEN, which is the truth, not a bug.
          text: "LEN " + root.len + "   LAST HIGH SCORE " + root.best
          color: Color.menu.text.toString()
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.title
          font.bold: true
        }

        // Status labels: yellow ALL-CAPS, right-aligned, only while enabled —
        // the terminal's help-row labels (COLOR_PAIR(4) + A_BOLD). They live
        // here rather than on the Canvas because boardTop is exactly 0 when
        // height is the limiting axis, so a label painted above the board
        // floor gets clipped by the Canvas bounds and never shows.
        Text {
          id: hudRight
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          visible: root.huntOn === 1 || root.wrapOn === 1
          textFormat: Text.PlainText
          text: (root.huntOn === 1 ? "AUTO HUNT" : "")
                + (root.huntOn === 1 && root.wrapOn === 1 ? "   " : "")
                + (root.wrapOn === 1 ? "WRAP" : "")
          color: "#e8c33f"
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.title
          font.bold: true
        }
      }

      Item {
        id: boardArea
        width: Math.max(2, root.cellSize * root.bw)
        height: Math.max(2, root.cellSize * root.bh)
        // The placeholder 10x6 outline (bw/bh start values) has no business on
        // the black screen — the engine's own board size arrives in the first
        // frame, and then the board shows with everything else (see setupUp).
        visible: root.gotFrame

        Canvas {
          id: boardCanvas
          anchors.fill: parent
          onPaint: root.paintBoard(this)
          onVisibleChanged: requestPaint()
        }

        Connections {
          target: root
          function onFrameSerialChanged() { boardCanvas.requestPaint() }
          function onCellSizeChanged() { boardCanvas.requestPaint() }
        }

        // Press only, ever: the engine TOGGLES a cell, so a synthesised or
        // double-fired click un-places what it just placed — hence no
        // release handler and no debounce timer. focus stays off so a click
        // cannot take active focus from keyCatcher.
        MouseArea {
          anchors.fill: parent
          focus: false
          acceptedButtons: Qt.LeftButton
          cursorShape: Qt.PointingHandCursor
          onPressed: function(mouse) {
            // A menu up means the board is hiding its tokens; clicking then
            // would edit a board the player cannot see.
            if (!root.opened || root.menuUp || !engineProc.running) return
            var col = root.colAt(mouse.x)
            var row = root.rowAt(mouse.y)
            if (col < 0 || row < 0 || col >= root.bw || row >= root.bh) return
            root.send({ cmd: "click", x: col, y: row })
            mouse.accepted = true
          }
        }
      }

      Text {
        id: helpRow
        width: parent.width
        height: root.helpHeight
        visible: root.gotFrame   // same black-screen gate as the HUD (see setupUp)
        textFormat: Text.PlainText
        // Two different key sets, because there are two different games up here: the
        // setup card answers `q` and the mouse, and naming `arrows`/`h`/`p`/`r` while
        // the run has not begun would advertise keys that are wired to nothing.
        text: root.started === 0
              ? "set wrap and speed, then START   ·   q quit"
              : "arrows move · h auto-hunt · p pause · r restart · q quit"
        color: Color.menu.text.toString()
        opacity: 0.65
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.body      // a hint line, not a heading
        horizontalAlignment: Text.AlignRight
        elide: Text.ElideRight
      }
    }

    // The black screen is not empty-empty: while the engine builds and forks,
    // a blocky white snake traces an infinity loop in the middle of it — the
    // pixel ouroboros, same language as the board. It retires the instant the
    // first frame lands, and steps aside for the error panel if no frame ever
    // does (the same gotFrame gate that holds the board back).
    Canvas {
      id: logoCanvas
      anchors.centerIn: parent
      visible: root.opened && !root.gotFrame && !root.engineFailed
      readonly property int logoBlock: Math.max(6, Style.space(7))
      width: 60 * logoBlock
      height: 34 * logoBlock
      onPaint: root.paintLogo(logoCanvas)
      onVisibleChanged: requestPaint()
    }

    // Menu overlays live OUTSIDE the column, so a panel never resizes the
    // board underneath it and reflows no cells mid-death.
    //
    // ---------------------------------------------------------------- setup card
    // What this run IS, chosen before it begins: settings on top, START at the
    // bottom. Wrap and speed live HERE and nowhere else — after START the engine
    // refuses both (snake.c: `if (g->started) return 1;`), so a control that
    // outlived the card would be claiming a power it no longer has. The snake sits
    // on the board behind it, painted and still: the engine is ticking, it just will
    // not advance an unstarted run, and the clicks that place food before the go
    // signal are kept — placing a token is telling the AI where to eat, not steering.
    Rectangle {
      id: setupPanel
      visible: root.setupUp
      anchors.centerIn: parent        // see pausePanel: boardArea is not a valid anchor target
      width: root.menuWidth(boardArea.width)
      height: setupColumn.implicitHeight + root.cardPadding
      radius: Style.cornerRadius
      color: Color.menu.background.toString()
      border.color: Color.menu.border.toString()
      border.width: 1

      Column {
        id: setupColumn
        anchors.centerIn: parent
        width: parent.width - Style.space(24)
        spacing: Style.spacing.lg

        Text {
          textFormat: Text.PlainText
          text: "SET UP YOUR RUN"
          color: Color.menu.selectedText.toString()
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.display
          font.bold: true
          horizontalAlignment: Text.AlignHCenter
          width: parent.width
        }

        // WRAP. The switch is drawn from the ENGINE's flag, never from a click count:
        // if the frame says wrap is off, the switch says off, whatever was clicked.
        Item {
          width: parent.width
          height: Math.max(Style.space(46), wrapSwitch.height)

          Column {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.xs

            Text {
              textFormat: Text.PlainText
              text: "WRAP"
              color: Color.menu.selectedText.toString()
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }
            Text {
              textFormat: Text.PlainText
              text: root.wrapOn === 1 ? "walls are doors; the far side opens"
                                      : "walls kill, as they always have"
              color: Color.menu.text.toString()
              opacity: 0.75
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.caption
            }
          }

          ToggleSwitch {
            id: wrapSwitch
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            checked: root.wrapOn === 1
            onToggled: root.toggleWrap()
          }
        }

        // SPEED. Left is slower, right is faster, and the middle is the speed this
        // game has always had (55 ms) — so the default position is not a guess the
        // player has to undo, it is where the thumb already sits.
        Column {
          width: parent.width
          spacing: Style.spacing.xs

          Item {
            width: parent.width
            height: Math.max(speedCaption.height, speedTitle.height)

            Text {
              id: speedTitle
              textFormat: Text.PlainText
              text: "SPEED"
              color: Color.menu.selectedText.toString()
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }
            Text {
              id: speedCaption
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: root.speedLabel
              color: Color.menu.text.toString()
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.caption
            }
          }

          PanelSlider {
            id: speedSlider
            width: parent.width
            minimum: root.speedLo
            maximum: root.speedHi
            step: 0.05
            value: Math.max(root.speedLo, Math.min(root.speedHi, root.speedMult))
            // Named, not defaulted. PanelSlider has no bar to inherit from outside a
            // Panel, and its no-bar fallbacks are hardcoded dark greys — on this
            // menu-coloured card the track would be invisible in a light theme.
            trackColor: Color.menu.border
            fillColor: Color.menu.selectedText
            knobColor: Color.menu.selectedText

            // moved, not just released: the readout has to follow the thumb, and the
            // engine takes a tick change cheaply. setSpeed() drops a value that is
            // already in flight, so a drag across detents is not a write storm.
            onMoved: function(v) { root.setSpeed(root.msForMult(v)) }
            onReleased: function(v) { root.setSpeed(root.msForMult(v)) }
          }

          // Which end is which, said once, in the pixels the slider has. An Item with
          // two anchored labels, deliberately not a Row: a Row sets x on its children,
          // which is the thing `anchors.right` contradicts.
          Item {
            width: parent.width
            height: fastCaption.height

            Text {
              textFormat: Text.PlainText
              text: "slow"
              color: Color.menu.text.toString()
              opacity: 0.6
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.caption
            }
            Text {
              id: fastCaption
              anchors.right: parent.right
              textFormat: Text.PlainText
              text: "fast"
              color: Color.menu.text.toString()
              opacity: 0.6
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        // START — the bottom of the card, and the only thing that gets the snake
        // moving. Mouse on purpose: this is a decision, not a key to mash past.
        Button {
          id: startButton
          anchors.horizontalCenter: parent.horizontalCenter
          text: "START"
          selected: true
          fontSize: Style.font.title
          horizontalPadding: Style.space(30)
          onClicked: root.startRun()
        }
        // No key hint under the button: the help row under the board already names
        // `q quit` for this state, and saying it twice in one window is noise.
      }
    }

    Rectangle {
      id: pausePanel
      visible: root.opened && root.alive === 1 && root.paused === 1
      // centerIn: parent (the window), NOT boardArea. boardArea is a descendant
      // of a sibling, so QML rejected that anchor outright — "Cannot anchor to an
      // item that isn't a parent or sibling", logged twice against this file —
      // and the card sat unanchored at the window's top-left corner. The column
      // is centred on the window and the board is the middle of the column, so
      // the window's centre is the board's centre to within half the difference
      // between the HUD row and the help row (~5 px). Good enough to read as
      // sitting over the board; anchoring to the board itself is what broke.
      anchors.centerIn: parent
      width: root.menuWidth(boardArea.width)
      height: pauseColumn.implicitHeight + root.cardPadding
      radius: Style.cornerRadius
      color: Color.menu.background.toString()
      border.color: Color.menu.border.toString()
      border.width: 1

      Column {
        id: pauseColumn
        anchors.centerIn: parent
        width: parent.width - Style.space(24)
        spacing: Style.spacing.md

        Text {
          textFormat: Text.PlainText
          text: "PAUSED"
          color: Color.menu.selectedText.toString()
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.display
          font.bold: true
          horizontalAlignment: Text.AlignHCenter
          width: parent.width
        }
        Text {
          textFormat: Text.PlainText
          text: "p resume · r restart · q quit"
          color: Color.menu.text.toString()
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.title
          horizontalAlignment: Text.AlignHCenter
          width: parent.width
        }
      }
    }

    Rectangle {
      id: overPanel
      visible: root.opened && root.alive === 0
      anchors.centerIn: parent        // see pausePanel: boardArea is not a valid anchor target
      width: root.menuWidth(boardArea.width)
      height: overColumn.implicitHeight + root.cardPadding
      radius: Style.cornerRadius
      color: Color.menu.background.toString()
      border.color: Color.menu.border.toString()
      border.width: 1

      Column {
        id: overColumn
        anchors.centerIn: parent
        width: parent.width - Style.space(24)
        spacing: Style.spacing.md

        Text {
          textFormat: Text.PlainText
          text: "GAME OVER"
          color: Color.menu.selectedText.toString()
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.display
          font.bold: true
          horizontalAlignment: Text.AlignHCenter
          width: parent.width
        }
        Text {
          textFormat: Text.PlainText
          // The same words as the HUD, and by now they are the same number too: the record
          // went to disk the tick this run beat it, so the game-over card is reporting the
          // file the player could go and read — not a promise about what will be written
          // when the window closes.
          text: "LEN " + root.len + " · LAST HIGH SCORE " + root.best
          color: Color.menu.text.toString()
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.title
          horizontalAlignment: Text.AlignHCenter
          width: parent.width
        }
        Text {
          textFormat: Text.PlainText
          text: "r restart · q quit"
          color: Color.menu.text.toString()
          opacity: 0.8
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.title
          horizontalAlignment: Text.AlignHCenter
          width: parent.width
        }
      }
    }

    Rectangle {
      id: failPanel
      visible: root.opened && root.engineFailed
      anchors.centerIn: parent
      // Fixed width on purpose: reading failColumn.implicitWidth here while
      // the column's own width reads back off this rectangle is a binding
      // loop, and the wrapping Text below is exactly the child that closes
      // it (implicit width of a wrapped label depends on the width given to
      // it). Height is safe — it never feeds back into width.
      width: Style.space(360)
      height: failColumn.implicitHeight + root.cardPadding
      radius: Style.cornerRadius
      color: Color.menu.background.toString()
      border.color: Color.menu.border.toString()
      border.width: 1

      Column {
        id: failColumn
        anchors.centerIn: parent
        width: parent.width - root.cardPadding
        spacing: Style.spacing.md

        Text {
          textFormat: Text.PlainText
          text: root.gotFrame ? "tsnake engine exited" : "tsnake engine not found"
          color: Color.menu.selectedText.toString()
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.heading
          font.bold: true
        }
        Text {
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          width: parent.width
          visible: !root.gotFrame
          text: "No engine binary, and the automatic build failed. Run ./install.sh in"
                + " this folder (it builds snake and installs it beside this file), or"
                + " check that `make` and `gcc` are installed."
                + "\nTried: " + root.engineCandidates().join(", ")
          color: Color.menu.text.toString()
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.title
        }
        Text {
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          width: parent.width
          visible: root.engineStderr.length > 0
          text: root.engineStderr.join("\n")
          color: Color.menu.text.toString()
          opacity: 0.7
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.body
        }
        Text {
          textFormat: Text.PlainText
          text: "q quit"
          color: Color.menu.text.toString()
          opacity: 0.8
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.title
        }
      }
    }

    // Raw Keys.onPressed, never Ui/PanelKeyCatcher: that emits moveRequested
    // for h/j/k/l, which would smuggle vim movement back in against the
    // arrows-only rule — here `h` must mean auto-hunt. Lowercase only: no
    // wasd, no uppercase (Qt.Key_H is a different key), no space, no Enter.
    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.priority: Keys.BeforeItem

      Keys.onPressed: function(event) {
        if (!root.opened || root.labMode) return

        // Ctrl/Alt/Meta never mean a game key: without this, Ctrl+R would
        // restart the run and Ctrl+H hunt, right through the browser habits.
        if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) {
          event.accepted = true
          return
        }

        // Before START the card owns the window: the snake does not move, so steering
        // keys have nothing to steer and `h`/`p`/`r` all name a run that does not
        // exist yet. Only quitting is real — the mouse has the settings, and a player
        // who summoned the game by mistake must always be able to put it back down.
        if (root.started === 0) {
          var ch0 = (event.text && event.text.length === 1) ? event.text : ""
          if (ch0 === "q" || event.key === Qt.Key_Escape) root.dismiss()
          event.accepted = true
          return
        }

        var k = event.key
        var dirCmd = null
        if (k === Qt.Key_Left) dirCmd = { cmd: "dir", dx: -1, dy: 0 }
        else if (k === Qt.Key_Right) dirCmd = { cmd: "dir", dx: 1, dy: 0 }
        else if (k === Qt.Key_Up) dirCmd = { cmd: "dir", dx: 0, dy: -1 }
        else if (k === Qt.Key_Down) dirCmd = { cmd: "dir", dx: 0, dy: 1 }

        if (dirCmd !== null) {
          root.send(dirCmd)
          event.accepted = true
          return
        }

        // Letter keys match event.text, NOT Qt.Key_h: the QML Qt object carries
        // only the special keys (Left/Up/Return/Escape/…), it has no Key_h
        // member — qmllint says so ("Member "Key_h" not found on type QtObject")
        // and Emojis.qml:228 reads event.text for the same reason. Matching the
        // character is also what makes lowercase-only real the way snake.c is:
        // Shift+h arrives as "H" and matches nothing at all.
        var ch = (event.text && event.text.length === 1) ? event.text : ""
        if (ch === "h") root.send({ cmd: "hunt" })
        else if (ch === "p") root.send({ cmd: "pause" })
        // No `x` here any more, though snake.c still answers it in the terminal
        // build. Wrap is a decision about what the run IS, and the setup card is the
        // only place that gets to make it; mid-run it is locked (the engine refuses
        // the command once started), so a key for it would be a control that lies.
        else if (ch === "r") root.send({ cmd: "restart" })
        // q fully unmounts rather than merely hiding: close() stops the engine
        // and drops the surface, but leaves the host's openPanelIds holding this
        // id. The bar button toggles through `omarchy-shell shell toggle`, so a
        // stale id makes the next press HIDE a panel that is already hidden and
        // strands the Loader item — q must agree with the host about being gone.
        else if (ch === "q") root.dismiss()
        else if (k === Qt.Key_Escape) root.dismiss()

        // Everything is consumed while the game holds exclusive focus, so no
        // stray key — arrows, space, Enter — ever leaks down to the shell.
        event.accepted = true
      }
    }

    // Focus can be handed off by a surface enter/leave; a game that stopped
    // reading keys looks frozen, so take it back whenever it is lost.
    Connections {
      target: keyCatcher
      function onActiveFocusChanged() {
        // !root.labMode, or the game's catcher fights the lab's catcher for
        // focus on every change and the lab can never be typed at.
        if (root.opened && !root.labMode && !keyCatcher.activeFocus)
          Qt.callLater(function() { keyCatcher.forceActiveFocus() })
      }
    }
  }

  // ------------------------------------------------------------- the painter
  // Canvas, not a Repeater of Rectangles: a snapshot lands ~18x a second, and a
  // Repeater rebinds w*h items (960 at 40x24) every time, nearly all of them to
  // "transparent". A Canvas repaints what the frame actually names — head,
  // body, corpses, tokens — so per-frame cost tracks the snake, not the board,
  // and there is no layout pass per tick. It also keeps the cell mapping in one
  // place: paint and clicks both read boardLeft/boardTop/cellSize.
  //
  // Colours: theme tokens everywhere the theme has a word for it
  // (Color.menu.*). What is hard-coded below has no qs.Commons equivalent — a
  // menu palette has no "food", "corpse" or "hunt warning" role — and each
  // value is the terminal build's own, so the two faces read as one game:
  // pair 1 green (food, eat flash), pair 2 white (body), pair 3 red (corpse)
  // plus its A_BOLD red-orange (hunt border). Pair 4 yellow is the same
  // argument up in hudRight.
  // The black-screen logo: a white snake tracing an infinity loop — an ouroboros
  // in pixels, the same blocky language the board paints with. The curve is a
  // lemniscate of Gerono (x = cos t, y = sin t cos t) sampled onto the grid;
  // every cell it lands in becomes one white block, and the head sits on the
  // loop where the tail crosses, biting it. No engine, no frame, nothing
  // invented — this is the honest face of "still starting".
  function paintLogo(canvas) {
    var ctx = canvas.getContext("2d")
    if (!ctx) return
    ctx.clearRect(0, 0, canvas.width, canvas.height)

    // The shape and shadow language, from the reference and redrawn flat-side:
    // a ribbon infinity whose RIGHT strand passes OVER the left through the
    // middle, casting a shadow onto it, with a soft dithered drop shadow
    // under the whole body. Two colours only — white (left strand, the head)
    // and light grey (right strand, on top) — plus their dithers. The lobes
    // are round; the crossing is the long thin twist of a real ribbon, not a
    // sharp X, which is exactly how the reference draws its own twist.
    var block = canvas.logoBlock
    var cols = 60
    var rows = 34
    var cx = (cols - 1) / 2
    var cy = (rows - 1) / 2
    var A = 21          // half-width in cells
    var H = 12.5        // lobe amplitude in cells
    var R = 4.3         // body radius in cells

    // The two strands as sample points: right (cos t > 0) passes over.
    var N = 750
    var rx = []
    var ry = []
    var lx = []
    var ly = []
    for (var i = 0; i <= N; i++) {
      var t = i / N * 2 * Math.PI
      var px = cx + A * Math.cos(t)
      var py = cy + H * Math.sin(t) * Math.cos(t)
      if (Math.cos(t) > 0) { rx.push(px); ry.push(py) }
      else { lx.push(px); ly.push(py) }
    }

    function dmin(ax, ay, mx, my) {
      var best = 1e18
      for (var s = 0; s < ax.length; s++) {
        var dx = mx - ax[s]
        var dy = my - ay[s]
        var d2 = dx * dx + dy * dy
        if (d2 < best) best = d2
      }
      return Math.sqrt(best)
    }

    // Classify every cell once: 0 empty, 1 white strand, 2 grey strand,
    // 3 cast shadow (grey dither on the left strand, where the right one
    // crosses over), 4 drop shadow (grey dither, body offset down-right).
    var grid = []
    var inside = []
    for (var y = 0; y < rows; y++) {
      for (var x = 0; x < cols; x++) {
        var mx = x + 0.5
        var my = y + 0.5
        var dR = dmin(rx, ry, mx, my)
        var dL = dmin(lx, ly, mx, my)
        var d = dR < dL ? dR : dL
        inside[y * cols + x] = d < R
        if (dR < R) grid[y * cols + x] = 2
        else if (dL < R && dR < R + 1.5) grid[y * cols + x] = 3
        else if (dL < R) grid[y * cols + x] = 1
        else grid[y * cols + x] = 0
      }
    }
    for (var y2 = 0; y2 < rows; y2++) {
      for (var x2 = 0; x2 < cols; x2++) {
        if (grid[y2 * cols + x2] !== 0) continue
        // Drop shadow: the body two cells up-left of here.
        var ox = x2 - 2
        var oy = y2 - 2
        if (ox >= 0 && oy >= 0 && inside[oy * cols + ox]) grid[y2 * cols + x2] = 4
      }
    }

    var white = "#ffffff"
    var grey = "#d6d6d6"
    for (var yy = 0; yy < rows; yy++) {
      for (var xx = 0; xx < cols; xx++) {
        var v = grid[yy * cols + xx]
        if (v === 1) ctx.fillStyle = white
        else if (v === 2) ctx.fillStyle = grey
        else if (v === 3 || v === 4) {
          if ((xx + yy) % 2 !== 0) continue
          ctx.fillStyle = grey
        } else continue
        ctx.fillRect(xx * block, yy * block, block, block)
      }
    }

    // Head: a solid white blob on the right lobe's end, with two black eyes
    // — the snake biting its own tail, as the reference sets its head.
    var hx = cx + A
    var hy = cy
    for (var hy2 = 0; hy2 < rows; hy2++) {
      for (var hx2 = 0; hx2 < cols; hx2++) {
        var ddx = hx2 + 0.5 - hx
        var ddy = hy2 + 0.5 - hy
        if (ddx * ddx + ddy * ddy <= 3.0 * 3.0) {
          ctx.fillStyle = white
          ctx.fillRect(hx2 * block, hy2 * block, block, block)
        }
      }
    }
    ctx.fillStyle = "#000000"
    ctx.fillRect((hx + 1) * block - block * 0.15, (hy - 1) * block - block * 0.15,
                 block * 0.9, block * 0.9)
    ctx.fillRect((hx + 1) * block - block * 0.15, (hy + 1) * block - block * 0.15,
                 block * 0.9, block * 0.9)
  }

  function paintBoard(canvas) {
    var ctx = canvas.getContext("2d")
    if (!ctx) return
    ctx.clearRect(0, 0, canvas.width, canvas.height)

    var cell = root.cellSize
    var left = root.boardLeft
    var top = root.boardTop
    var bw = root.bw
    var bh = root.bh

    // Board floor.
    ctx.fillStyle = Color.menu.selectedBackground.toString()
    ctx.fillRect(left, top, cell * bw, cell * bh)

    // Border priority straight off draw(): flash outranks hunt; hunt is the
    // red-orange AUTO HUNT warning; otherwise the theme's plain border.
    var border = Color.menu.border.toString()
    if (root.flash > 0) border = "#41d158"
    else if (root.huntOn === 1) border = "#ff7043"
    ctx.strokeStyle = border
    // Capped, not merely proportional. The 0.16 ratio is the one that reads like
    // the terminal's solid border at an ordinary cell size; unbounded it was a
    // 35 px green slab at the 220 px cells the unsized board produced.
    ctx.lineWidth = Math.max(2, Math.min(3, Math.round(cell * 0.16)))
    var inset = ctx.lineWidth / 2
    ctx.strokeRect(left + inset, top + inset,
                   cell * bw - ctx.lineWidth, cell * bh - ctx.lineWidth)

    // Menus up ⇒ contents hidden, as draw() hides food/snake/wounds while
    // paused || !alive. Frames keep arriving; only painting stops.
    if (root.menuUp) return

    ctx.textAlign = "center"
    ctx.textBaseline = "middle"

    // Everything drawn from here on is a glyph out of `root.glyphs`, centred in its
    // cell. The terminal paints '$' and 'o' as characters and the corpse/body as
    // solid cells; the overlay now paints what the lab was built to choose.
    // Each glyph sets its own size (see glyphScale), so there is no shared board
    // font any more; the one below is only the fallback a blank slot's cell needs.
    function fontFor(mult) {
      return String(Math.max(6, Math.floor(cell * mult))) + "px " + Style.font.menuFamily
    }

    ctx.font = fontFor(1.0)

    function put(ch, x, y, colour, alpha, mult) {
      if (!ch) return
      ctx.font = fontFor(mult)
      ctx.globalAlpha = alpha === undefined ? 1.0 : alpha
      ctx.fillStyle = colour
      ctx.fillText(ch, root.cellLeft(x) + cell / 2, root.cellTop(y) + cell / 2)
      ctx.globalAlpha = 1.0
    }

    // Food (pair 1 green). Was the terminal's '$'.
    var food = root.foodPts
    var i
    for (i = 0; i < food.length; i++) {
      if (!food[i]) continue
      put(root.glyphs.food, food[i].x, food[i].y, "#41d158", undefined,
          root.glyphScale.food)
    }

    // Corpses (pair 3 red), dimmed over their last third (snake.c:755 dims at
    // ttl < WOUND_FADE / 3). Was a solid cell; an outline diamond fades far more
    // legibly than a shrinking block of red.
    var wounds = root.woundPts
    for (i = 0; i < wounds.length; i++) {
      if (!wounds[i]) continue
      put(root.glyphs.corpse, wounds[i].x, wounds[i].y, "#e0524b",
          (wounds[i].ttl < root.woundFade / 3) ? 0.4 : 1.0, root.glyphScale.corpse)
    }

    // Snake (pair 2 white). The head is the direction glyph — the same decision
    // head_glyph() makes, by direction, not by index: dir[1]==-1 up, dir[1]==1
    // down, dir[0]==-1 left, else right.
    var body = root.bodyPts
    for (i = 0; i < body.length; i++) {
      if (!body[i]) continue
      var g
      if (i === 0) {
        g = root.glyphs.headRight
        if (root.dirY === -1) g = root.glyphs.headUp
        else if (root.dirY === 1) g = root.glyphs.headDown
        else if (root.dirX === -1) g = root.glyphs.headLeft
      } else {
        g = root.glyphs.body
      }
      // An empty slot means "draw the cell", not "draw nothing": a blank body or
      // corpse glyph would otherwise paint an invisible snake and read as a bug in
      // the engine. (No slot in today's set is empty; this is what makes the table
      // safe to edit.)
      if (!g) {
        ctx.fillStyle = "#f2f2f2"
        ctx.fillRect(root.cellLeft(body[i].x), root.cellTop(body[i].y), cell, cell)
        continue
      }
      put(g, body[i].x, body[i].y, "#f2f2f2", undefined,
          i === 0 ? root.glyphScale.head : root.glyphScale.body)
    }

    // The AUTO HUNT / WRAP labels are not painted here — see hudRight, which
    // sits in the HUD row where there is guaranteed room for them.
  }
}
