import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// tsnake overlay: the front-end for `snake --protocol`, the same game the
// terminal build plays with the curses face swapped out for this window.
//
// Surface/lifecycle shape taken from /usr/share/omarchy/shell/plugins/emojis/
// Emojis.qml: the host injects shell/manifest and drives open()/close()/
// dismiss()/toggle(), and the surface is a fullscreen Overlay-layer
// PanelWindow with EXCLUSIVE keyboard focus — without exclusive focus a game
// is not playable, the shell keeps the keyboard.
Item {
  id: root

  // ------------------------------------------------------- host-injected
  // shell.qml:1338-1344 assigns these onto the loaded item when present.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  // The host reads item.opened to decide summon-vs-hide (shell.qml:1205).
  property bool opened: false

  readonly property string pluginId: "io.github.londelo.tsnake"

  // ---------------------------------------------------------- state paths
  // The ENGINE owns every byte under the state dir; QML writes nothing there,
  // and nothing anywhere inside the plugin folder either. HOME + XDG state,
  // the idiom at plugins/notifications/Service.qml:24-25.
  readonly property string home: String(Quickshell.env("HOME") || "")
  readonly property string stateRoot: home !== "" ? home + "/.local/state"
                                                   : String(Quickshell.stateDir)
  readonly property string stateFile: stateRoot + "/tsnake/highscore"

  // Engine binary resolution order. Deliberately NEVER inside the plugin
  // folder: the shell inotify-watches all of ~/.config/omarchy/plugins for
  // close_write/create/delete/move and reloads every plugin on any event, so a
  // `make` in there would rebuild this Loader under the player mid-run.
  property int engineIndex: 0
  property bool engineFailed: false
  property var engineStderr: []

  function engineCandidates() {
    var out = []
    var envBin = String(Quickshell.env("TSNAKE_BIN") || "")
    if (envBin !== "") out.push(envBin)
    out.push(root.stateRoot + "/tsnake/snake")
    // Last resort: the dev build (never launched from inside the plugin dir).
    out.push("/home/londelo/CastleLondelo/projects/tsnake/snake")
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

  readonly property bool menuUp: root.opened && (root.alive === 0 || root.paused === 1)

  // --------------------------------------------------- exactly one cell map
  // Drawing and click→board mapping both go through boardLeft/boardTop/
  // cellSize, so pointing and painting cannot drift. This is the guard the
  // terminal build implements as CELL_TOP/CELL_LEFT, which draw() writes with
  // and handle_click() reads through.
  //
  // Sizes come off the WINDOW, never off the card: cellSize → card size would
  // be a binding loop the moment the card also feeds boardArea's size.
  readonly property real hudHeight: Style.space(20)
  readonly property real helpHeight: Style.space(20)
  readonly property real cardPadding: Style.space(24)
  readonly property real availW: panel.width > 0
    ? Math.max(2, panel.width - cardPadding * 2) : 2
  readonly property real availH: panel.height > 0
    ? Math.max(2, panel.height - cardPadding * 2 - hudHeight - helpHeight
                 - Style.spacing.md * 2) : 2

  // Square cells by construction: one cell size for both axes.
  readonly property real cellSize: (root.bw > 0 && root.bh > 0)
    ? Math.max(2, Math.floor(Math.min(root.availW / root.bw, root.availH / root.bh)))
    : 2
  readonly property real boardLeft: (boardArea.width - cellSize * root.bw) / 2
  readonly property real boardTop: (boardArea.height - cellSize * root.bh) / 2

  function cellLeft(col) { return root.boardLeft + col * root.cellSize }
  function cellTop(row) { return root.boardTop + row * root.cellSize }
  function colAt(px) { return Math.floor((px - root.boardLeft) / root.cellSize) }
  function rowAt(py) { return Math.floor((py - root.boardTop) / root.cellSize) }

  // Target cell the board dimensions are planned against; the engine clamps
  // to 10..400 x 6..250 and the frame's w/h stay the source of truth.
  readonly property int targetCell: Math.max(10, Style.space(18))

  function desiredBoard() {
    var w = Math.floor(root.availW / root.targetCell)
    var h = Math.floor(root.availH / root.targetCell)
    return { w: Math.max(10, Math.min(400, w)), h: Math.max(6, Math.min(250, h)) }
  }

  property string sizeSent: ""

  function maybeSendSize() {
    if (!engineProc.running) return
    var d = root.desiredBoard()
    var key = d.w + "x" + d.h
    if (key === root.sizeSent) return
    root.sizeSent = key
    root.send({ cmd: "size", w: d.w, h: d.h })
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
    root.launchCandidate()
  }

  function launchCandidate() {
    var cands = root.engineCandidates()
    if (root.engineIndex >= cands.length) {
      root.engineFailed = true
      root.launchPending = false
      return
    }
    engineProc.command = [cands[root.engineIndex], "--protocol", "--square-cells",
                          "--state", root.stateFile]
    root.launchPending = true
    engineProc.running = true
    startWatchdog.restart()
  }

  // A failed attempt: take down whatever is up, try the next candidate, and
  // once the list is dry the overlay tells the player to run `make`. The
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
    // Order is load-bearing, not cosmetic. By the time this runs the surface is
    // already down (close()/dismiss() set opened=false FIRST), because the
    // shell's teardown rebuilds this Loader: a save that landed while the board
    // was visible would destroy the game under the player's eyes, and a save on
    // death would reset the game-over panel mid-display. Then flush, then quit,
    // then kill as the backstop.
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
    root.bodyPts = f.body || []
    root.woundPts = f.wound || []
    root.foodPts = f.food || []
    root.frameSerial++
  }

  function open(payloadJson) {
    root.opened = true
    root.sizeSent = ""
    root.startEngine()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
    root.stopEngine()
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || root.pluginId)
    root.stopEngine()
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
  // quit — and the write cannot be lost anyway: when the Loader tears this
  // Process down, the pipe closes, and the engine banks the run and exits on
  // EOF (snake.c:1202-1207). The save survives either path.
  Timer {
    id: killTimer
    interval: 600
    repeat: false
    onTriggered: if (engineProc.running) engineProc.signal(15)
  }

  Component.onDestruction: root.stopEngine()

  // ------------------------------------------------------------ the surface
  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-tsnake"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: Color.menu.scrim
    }

    Rectangle {
      id: card
      anchors.centerIn: parent
      // Sized FROM the board, never the other way round.
      width: boardArea.width + root.cardPadding
      height: boardArea.height + root.cardPadding + root.hudHeight + root.helpHeight
              + Style.spacing.md * 2
      radius: Style.cornerRadius
      color: Color.menu.background.toString()
      border.color: Color.menu.border.toString()
      border.width: 1

      Column {
        id: boardColumn
        anchors.centerIn: parent
        width: boardArea.width
        spacing: Style.spacing.md

        Item {
          id: hud
          width: parent.width
          height: root.hudHeight

          Text {
            id: hudLeft
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: "LEN " + root.len + "   BEST " + root.best
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
          textFormat: Text.PlainText
          text: "arrows move · h auto-hunt · x wrap · p pause · r restart · q quit"
          color: Color.menu.text.toString()
          opacity: 0.65
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.title
          horizontalAlignment: Text.AlignRight
          elide: Text.ElideRight
        }
      }

      // Menu overlays live OUTSIDE the column, so a panel never resizes the
      // board underneath it and reflows no cells mid-death.
      Rectangle {
        id: pausePanel
        visible: root.opened && root.alive === 1 && root.paused === 1
        anchors.centerIn: boardArea
        width: Math.max(Style.space(200), boardArea.width * 0.6)
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
        anchors.centerIn: boardArea
        width: Math.max(Style.space(200), boardArea.width * 0.6)
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
            text: "LEN " + root.len + " · BEST " + root.best
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
            text: "Build it first:  cd /home/londelo/CastleLondelo/projects/tsnake && make"
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
        if (!root.opened) return

        // Ctrl/Alt/Meta never mean a game key: without this, Ctrl+R would
        // restart the run and Ctrl+H hunt, right through the browser habits.
        if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) {
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
        else if (ch === "x") root.send({ cmd: "wrap" })
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
        if (root.opened && !keyCatcher.activeFocus)
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
    ctx.lineWidth = Math.max(2, Math.round(cell * 0.16))
    var inset = ctx.lineWidth / 2
    ctx.strokeRect(left + inset, top + inset,
                   cell * bw - ctx.lineWidth, cell * bh - ctx.lineWidth)

    // Menus up ⇒ contents hidden, as draw() hides food/snake/wounds while
    // paused || !alive. Frames keep arriving; only painting stops.
    if (root.menuUp) return

    var bodyFont = String(Math.floor(cell * 0.82)) + "px " + Style.font.menuFamily
    ctx.font = bodyFont
    ctx.textAlign = "center"
    ctx.textBaseline = "middle"

    // Food: the terminal draws '$' in green (pair 1).
    ctx.fillStyle = "#41d158"
    var food = root.foodPts
    var i
    for (i = 0; i < food.length; i++) {
      if (!food[i]) continue
      ctx.fillText("$", root.cellLeft(food[i].x) + cell / 2,
                       root.cellTop(food[i].y) + cell / 2)
    }

    // Corpses: red, dimmed over their last third (snake.c:755 dims at
    // ttl < WOUND_FADE / 3).
    var wounds = root.woundPts
    for (i = 0; i < wounds.length; i++) {
      if (!wounds[i]) continue
      ctx.globalAlpha = (wounds[i].ttl < root.woundFade / 3) ? 0.4 : 1.0
      ctx.fillStyle = "#e0524b"
      ctx.fillRect(root.cellLeft(wounds[i].x), root.cellTop(wounds[i].y), cell, cell)
    }
    ctx.globalAlpha = 1.0

    // Snake: white body (pair 2); the head is the direction glyph, matching
    // head_glyph() — dir[1]==-1 '^', dir[1]==1 'v', dir[0]==-1 '<', else '>'.
    var body = root.bodyPts
    for (i = 0; i < body.length; i++) {
      if (!body[i]) continue
      ctx.fillStyle = "#f2f2f2"
      if (i === 0) {
        var g = ">"
        if (root.dirY === -1) g = "^"
        else if (root.dirY === 1) g = "v"
        else if (root.dirX === -1) g = "<"
        ctx.font = String(Math.floor(cell * 0.92)) + "px " + Style.font.menuFamily
        ctx.fillText(g, root.cellLeft(body[i].x) + cell / 2,
                        root.cellTop(body[i].y) + cell / 2)
        ctx.font = bodyFont
      } else {
        ctx.fillRect(root.cellLeft(body[i].x), root.cellTop(body[i].y), cell, cell)
      }
    }

    // The AUTO HUNT / WRAP labels are not painted here — see hudRight, which
    // sits in the HUD row where there is guaranteed room for them.
  }
}
