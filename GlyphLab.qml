import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Glyph lab: the "what can I actually draw with?" window. Summon:
//   omarchy-shell shell summon io.github.londelo.tsnake '{"mode":"glyphs"}'
// Sibling of the game window via Overlay.qml's Loader: a mistake here kills the
// lab only, never the board. Starts NO engine (design tool; no second high-score writer).
// The catalog is data: data/glyphs.json (three moves up from this file), read
// by catalogFile.
Item {
  id: lab

  // The plugin root that owns this Loader (Overlay.qml). Only dismiss() is used.
  property var host: null

  // Active group in the catalog, active font, active slot.
  property int groupIndex: 0
  property int fontIndex: 0
  property int roleIndex: 0

  // role key -> {cp, ch, n, f, c} or null (null = keep the text label).
  property var pick: ({})

  // Derived strings are properties, not bindings: `pick` is a plain JS object and
  // mutating one of its keys emits nothing, so anything that reads it would sit
  // there showing the previous choice. Every mutator rewrites these.
  property string sumText: ""
  property string infoText: ""

  property int pickSerial: 0

  // Paint counter: makes "the preview never refreshed" checkable with one click.
  // On the root, not the Canvas, so the canvas has no binding on its own paint.
  property int paintCount: 0

  // --------------------------------------------------------------- fonts
  // `fc-list` output from this machine. First entry = the alias the game itself
  // asks for (menuFamily → "monospace"), so the lab's default view is the board.
  readonly property var fonts: [
    { fam: Style.font.menuFamily, label: "THE GAME FONT (menuFamily)", note: "what the board is drawn in today" },
    { fam: "Adwaita Mono", label: "Adwaita Mono", note: "what the alias resolves to here" },
    { fam: "JetBrainsMono Nerd Font", label: "JetBrainsMono Nerd Font", note: "the only face with the private-use icons" },
    { fam: "JetBrainsMono NF", label: "JetBrainsMono NF", note: "same file, second family name" },
    { fam: "Noto Sans Symbols", label: "Noto Sans Symbols", note: "where fontconfig sends some of the dingbats" },
    { fam: "Noto Sans Symbols 2", label: "Noto Sans Symbols 2", note: "and some of these" },
    { fam: "Noto Color Emoji", label: "Noto Color Emoji", note: "every emoji on this box" },
    { fam: "Font Awesome 7 Free Solid", label: "Font Awesome 7 Free Solid", note: "icon font, no latin letters" },
    { fam: "Standard Symbols PS", label: "Standard Symbols PS", note: "legacy math/symbol face" },
    { fam: "Adwaita Sans", label: "Adwaita Sans", note: "proportional — the UI font, not a board font" }
  ]

  readonly property string currentFont: fonts[fontIndex].fam

  // The face every c:0/c:1 verdict was measured against: `fc-match monospace`
  // answers "Adwaita Mono" here. Naming the resolved face (not the alias) keeps
  // "green = you already have it" checkable.
  readonly property string probeFont: "Adwaita Mono"

  // ----------------------------------------------------------------- slots
  readonly property var roles: [
    { key: "headUp", label: "HEAD UP" },
    { key: "headDown", label: "HEAD DOWN" },
    { key: "headLeft", label: "HEAD LEFT" },
    { key: "headRight", label: "HEAD RIGHT" },
    { key: "body", label: "BODY" },
    { key: "food", label: "FOOD" },
    { key: "corpse", label: "CORPSE" },
    { key: "hunt", label: "AUTO HUNT" },
    { key: "wrap", label: "WRAP" }
  ]

  function hex(cp) {
    var s = cp.toString(16).toUpperCase()
    while (s.length < 4) s = "0" + s
    return s
  }

  function mkGlyph(cp, name, cover, fam) {
    return { cp: cp, ch: String.fromCodePoint(cp), n: name || "",
             c: cover === undefined ? 0 : cover, f: fam || "" }
  }

  function defaultPicks() {
    var d = {}
    d.headUp = lab.mkGlyph(0x5E, "CIRCUMFLEX ACCENT (the terminal head)")
    d.headDown = lab.mkGlyph(0x76, "LATIN SMALL LETTER V (the terminal head)")
    d.headLeft = lab.mkGlyph(0x3C, "LESS-THAN SIGN (the terminal head)")
    d.headRight = lab.mkGlyph(0x3E, "GREATER-THAN SIGN (the terminal head)")
    d.body = lab.mkGlyph(0x6F, "LATIN SMALL LETTER O (the terminal body)")
    d.food = lab.mkGlyph(0x24, "DOLLAR SIGN (the terminal token)")
    d.corpse = lab.mkGlyph(0x6F, "LATIN SMALL LETTER O (terminal corpse, drawn red)")
    d.hunt = null
    d.wrap = null
    return d
  }

  function assign(cell) {
    var r = lab.roles[lab.roleIndex]
    var d = {}
    for (var k in lab.pick) d[k] = lab.pick[k]
    d[r.key] = cell
    lab.pick = d
    lab.pickSerial++
    lab.infoText = "picked " + r.label + ": U+" + lab.hex(cell.cp) + "  " + cell.n
                   + (cell.c === 0 ? "  (in " + lab.currentFont + ")"
                                   : cell.c === 2 ? "  (NEEDS " + cell.f + ")"
                                                  : "  (BORROWED from " + cell.f + ")")
    // A click also copies the glyph to the clipboard (wl-copy takes argv,
    // nothing to quote), like panels/panels/network/Panel.qml's Tailscale pipe.
    Quickshell.execDetached(["wl-copy", cell.ch])
    lab.bump()
  }

  function clearSlot() {
    var r = lab.roles[lab.roleIndex]
    var d = {}
    for (var k in lab.pick) d[k] = lab.pick[k]
    d[r.key] = null
    lab.pick = d
    lab.pickSerial++
    lab.infoText = "cleared " + r.label + " — back to the text label"
    lab.bump()
  }

  function bump() {
    lab.sumText = lab.summary()
    previewCanvas.requestPaint()
  }

  function summary() {
    // Names both the chosen family and the face the substitution notes were judged against.
    var out = ["tsnake glyph set — font: " + lab.currentFont
               + "  (coverage judged against " + lab.probeFont + ")"]
    for (var i = 0; i < lab.roles.length; i++) {
      var r = lab.roles[i]
      var p = lab.pick[r.key]
      out.push("  " + r.label + ": " + (p
        ? "\"" + p.ch + "\"  U+" + lab.hex(p.cp) + "  " + p.n
          + (p.c === 0 ? "" : (p.c === 2 ? "  [private use — needs " + p.f + "]"
                                         : "  [substituted from " + p.f + "]"))
        : "(text label, no glyph)"))
    }
    return out.join("\n")
  }

  function copySummary() {
    Quickshell.execDetached(["wl-copy", lab.summary()])
    lab.infoText = "copied the whole set to the clipboard — paste it to Calcifer"
  }

  function closeLab() {
    if (lab.host && typeof lab.host.dismiss === "function") lab.host.dismiss()
  }

  // Every candidate is absolute and spelled from a known anchor, because
  // `Qt.resolvedUrl("./x")` resolves against the shell's cwd, not against this
  // file — the shell spells even its icon paths `file:///usr/share/icons` for
  // that reason, and `~/.config/omarchy/plugins` is a prefix the shell already
  // spells in full (PluginRegistry.qml). The dev checkout's data/ folder and
  // the installed plugin folder (which is what ./install.sh installs the
  // checkout's data/ folder into) are therefore both named by construction;
  // whichever candidate exists first wins, and no reader crashes while none
  // does — the shelf-note line goes red and says what is wrong instead of
  // painting an empty grid that looks like an empty game.
  readonly property string catalogPath: {
    var home = System.env("HOME") || ""
    var xdgData = (System.env("XDG_DATA_HOME") || "").trim()
    if (xdgData === "" || xdgData === "~" || xdgData.charAt(0) !== "/") xdgData = home + "/.local/share"
    // The dev checkout's data/ folder comes first: that is the one this repo
    // edits, so an edit to glyphs.json takes effect without an install run.
    // An installed machine with an untouched checkout still finds the installed
    // copy via the plugin-folder candidates — and those carry the $XDG_DATA_HOME
    // and `~` fallbacks exactly like stateDir in Overlay.qml, because System.env
    // really does answer "C:\Users\...".
    var xdgConfig = (System.env("XDG_CONFIG_HOME") || "").trim()
    if (xdgConfig === "" || xdgConfig === "~" || xdgConfig.charAt(0) !== "/") xdgConfig = home + "/.config"
    var cands = [xdgData + "/tsnake/glyphs.json",
                 xdgData + "/omarchy/plugins/io.github.londelo.tsnake/data/glyphs.json",
                 xdgData + "/omarchy/plugin-data/io.github.londelo.tsnake/glyphs.json",
                 xdgConfig + "/omarchy/plugins/io.github.londelo.tsnake/data/glyphs.json"]
    for (var i = 0; i < cands.length; i++) if (catalogFile.exists(cands[i])) return cands[i]
    return ""                                    // nothing found: loadCatalog says so
  }
  property var catalog: []                       // filled by catalogFile; [] = trustworthy-read failed
  property string catalogError: ""

  function loadCatalog() {
    try {
      // Shape-check before trusting it, the way snake.c's state_file_trustworthy
      // guards the save files: right-shaped content or a graceful "no catalog",
      // never a poisoned grid.
      var t = catalogFile.text().trim()
      if (t.length > 0 && t.length <= 262144) {
        var c = JSON.parse(t)
        if (Array.isArray(c) && c.length === 9 && c[0].id === "arrows") {
          lab.catalog = c
          lab.catalogError = ""
        } else {
          lab.catalog = []
          lab.catalogError = "glyphs.json parsed, but is not the tsnake catalog"
        }
      } else {
        lab.catalog = []
        lab.catalogError = "glyphs.json is empty or too big to be the catalog"
      }
      previewCanvas.requestPaint()
    } catch (e) {
      lab.catalog = []
      lab.catalogError = "glyphs.json is not valid JSON"
    }
  }

  // Data, not code. c:0 native to the probe font, 1 fontconfig borrows it from
  // family f (different width), 2 Nerd Font private use, 3 never probed. Never
  // guess a cell's coverage: measure it, `fc-match "Adwaita Mono:charset=XXXX"`.
  FileView {
    id: catalogFile
    path: lab.catalogPath
    watchChanges: true
    onLoaded: lab.loadCatalog()
    onLoadFailed: {
      lab.catalog = []
      lab.catalogError = "glyphs.json missing — reinstall the plugin folder"
    }
    // Re-read on change (clock/Panel.qml's langFile): an installed copy that a
    // re-run of install.sh replaces must repaint, not sit on the old table.
    onFileChanged: reload()
  }

  // ------------------------------------------------------------ the window
  FloatingWindow {
    id: labWin
    visible: true
    title: "tsnake glyph lab"
    color: Color.menu.background.toString()
    implicitWidth: Style.space(1360)
    // Sized to its content (~700), not a round number: a too-tall window reads
    // as an empty field under the catalogue. The game window had the same lesson.
    implicitHeight: Style.space(700)
    minimumSize: Qt.size(Style.space(760), Style.space(560))

    // Same stale-id trap as the game window: if hyprland kills this one, the
    // host still has the plugin id in openPanelIds.
    onVisibleChanged: {
      if (!visible) lab.closeLab()
    }

    Column {
      anchors.fill: parent
      anchors.margins: Style.space(18)
      spacing: Style.spacing.md

      // ---------------------------------------------------------- title row
      Row {
        width: parent.width
        spacing: Style.spacing.lg

        Column {
          spacing: 2
          Text {
            textFormat: Text.PlainText
            text: "TSNAKE GLYPH LAB"
            color: Color.menu.selectedText.toString()
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.heading
            font.bold: true
          }
          Text {
            textFormat: Text.PlainText
            text: lab.fonts[lab.fontIndex].note
                  + "  ·  click a glyph to fill the highlighted slot (and copy it)"
                  + "  ·  Tab next slot  ·  g next shelf  ·  f next font  ·  c copy set  ·  q close"
            color: Color.menu.text.toString()
            opacity: 0.7
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.body
          }
        }
      }

      // --------------------------------------------------------- font chips
      Flow {
        width: parent.width
        spacing: Style.spacing.xs

        Repeater {
          model: lab.fonts
          delegate: Rectangle {
            required property int index
            // modelData must be declared, not just used: a Repeater only hands it
            // to a delegate that asks for it, and the shell then logs
            // "Unable to assign [undefined] to QString" against every binding that
            // reads it (first-party delegates do this — background/Background.qml:186).
            required property var modelData
            width: fontRow.implicitWidth + Style.space(16)
            height: fontRow.implicitHeight + Style.space(8)
            radius: Style.cornerRadius
            color: lab.fontIndex === index
                   ? Color.menu.selectedBackground.toString() : "transparent"
            border.color: Color.menu.border.toString()
            border.width: lab.fontIndex === index ? 2 : 1

            // The name is written in the READABLE font and the sample in its OWN
            // face. Labelling a chip in the font it names is self-defeating: in the
            // first screenshot "Standard Symbols PS" came out as σταvδcard Ϩαμμβoλoς
            // ΠΣ, which tells the user nothing about the face it is advertising.
            Row {
              id: fontRow
              anchors.centerIn: parent
              spacing: Style.spacing.sm

              Text {
                textFormat: Text.PlainText
                text: "abc"                 // letters: every face on the shelf has them
                color: "#41d158"
                font.family: modelData.fam
                font.pixelSize: Style.font.body + 3
              }
              Text {
                id: fontLabel
                textFormat: Text.PlainText
                text: modelData.label
                color: Color.menu.text.toString()
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.body
                font.bold: lab.fontIndex === index
              }
            }
            MouseArea {
              anchors.fill: parent
              onClicked: { lab.fontIndex = index; lab.bump() }
            }
          }
        }
      }

      // ------------------------------------------------------------ shelves
      Flow {
        width: parent.width
        spacing: Style.spacing.xs

        // Array-as-model, not `model: lab.catalog`: an array assigned to a var
        // property coerces to its LENGTH here (Ui/ButtonGroup.qml:105,
        // clock/Panel.qml:613 — including the shell's own `model: 26`), which
        // strands the delegates' modelData. An empty array means zero delegates.
        Repeater {
          model: lab.catalog
          delegate: Rectangle {
            required property int index
            required property var modelData
            width: shelfLabel.implicitWidth + Style.space(16)
            height: shelfLabel.implicitHeight + Style.space(8)
            radius: Style.cornerRadius
            color: lab.groupIndex === index
                   ? Color.menu.selectedBackground.toString() : "transparent"
            border.color: Color.menu.border.toString()
            border.width: lab.groupIndex === index ? 2 : 1

            Text {
              id: shelfLabel
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: modelData.label
              color: lab.groupIndex === index
                     ? Color.menu.selectedText.toString() : Color.menu.text.toString()
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.body
              font.bold: lab.groupIndex === index
            }
            MouseArea {
              anchors.fill: parent
              onClicked: { lab.groupIndex = index; lab.infoText = modelData.note }
            }
          }
        }
      }

      Text {
        // LOUD on a missing/broken glyphs.json: it is the one line that can say so.
        textFormat: Text.PlainText
        // currentFont, never the alias: an alias answer to a coverage question
        // hides which face it came from. Verdicts are measured against probeFont.
        text: lab.catalog.length === 0 ? lab.catalogError
                                       : lab.catalog[lab.groupIndex].note
              + "  ·  green = in " + lab.probeFont
              + "  ·  amber = fontconfig borrows it from another face (different width)"
              + "  ·  blue = Nerd Font private use"
        color: Color.menu.text.toString()
        opacity: 0.6
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.body
      }

      // ------------------------------------------------------- body of the lab
      Row {
        width: parent.width
        // The row's height is what is left of the window; both children fill it.
        height: parent.height - y - Style.spacing.md
        spacing: Style.spacing.lg

        // ------------------------------------------------- catalogue (left)
        Flickable {
          id: catalogScroll
          width: parent.width - previewColumn.width - parent.spacing
          height: parent.height
          clip: true
          contentWidth: width
          contentHeight: cellFlow.height + Style.space(4)
          boundsBehavior: Flickable.StopAtBounds
          flickableDirection: Flickable.VerticalFlick

          Flow {
            id: cellFlow
            width: parent.width
            spacing: Style.spacing.xs

            Repeater {
              model: lab.catalog[lab.groupIndex].cells

              delegate: Rectangle {
                required property var modelData
                width: Style.space(58)
                height: Style.space(58)
                radius: Style.cornerRadius
                border.width: 1
                // Coverage colour: the honest answer to "can I use this?".
                border.color: modelData.c === 0 ? "#41d158"
                              : modelData.c === 1 ? "#e8c33f"
                              : modelData.c === 2 ? "#57a6ff" : Color.menu.border.toString()
                color: "transparent"

                Column {
                  anchors.centerIn: parent
                  spacing: 0

                  Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    textFormat: Text.PlainText
                    text: modelData.ch
                    color: Color.menu.selectedText.toString()
                    font.family: lab.currentFont
                    font.pixelSize: Style.space(26)
                    horizontalAlignment: Text.AlignHCenter
                  }
                  Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    textFormat: Text.PlainText
                    text: "U+" + lab.hex(modelData.cp)
                    color: Color.menu.text.toString()
                    opacity: 0.55
                    font.family: Style.font.menuFamily
                    font.pixelSize: Math.max(7, Style.font.body - 3)
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  onClicked: lab.assign(modelData)
                  onEntered: lab.infoText = "U+" + lab.hex(modelData.cp) + "  "
                                          + modelData.n + "  ·  "
                                          + (modelData.c === 0 ? "native to " + lab.currentFont
                                             : modelData.c === 1 ? "borrowed from " + modelData.f
                                             : modelData.c === 2 ? "Nerd Font only" : "not probed")
                }
              }
            }
          }
        }

        // ------------------------------------------------- preview + set (right)
        Column {
          id: previewColumn
          width: Style.space(430)
          height: parent.height
          spacing: Style.spacing.md

          // Slot chips — the highlighted one is what a catalogue click fills.
          Flow {
            width: parent.width
            spacing: Style.spacing.xs

            Repeater {
              model: lab.roles
              delegate: Rectangle {
                required property int index
                required property var modelData
                width: slotLabel.implicitWidth + Style.space(28) + Style.space(16)
                height: slotLabel.implicitHeight + Style.space(8)
                radius: Style.cornerRadius
                color: lab.roleIndex === index
                       ? Color.menu.selectedBackground.toString() : "transparent"
                border.color: lab.roleIndex === index ? "#e8c33f"
                                                      : Color.menu.border.toString()
                border.width: lab.roleIndex === index ? 2 : 1

                Row {
                  anchors.centerIn: parent
                  spacing: Style.spacing.xs

                  Text {
                    id: slotLabel
                    textFormat: Text.PlainText
                    // The slot shows the glyph it currently holds — that is the
                    // whole point of the chip; the name is decoration next to it.
                    text: modelData.label + " "
                          + (lab.pick[modelData.key]
                             ? "\"" + lab.pick[modelData.key].ch + "\"" : "(text)")
                    color: Color.menu.text.toString()
                    font.family: lab.currentFont
                    font.pixelSize: Style.font.body
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  onClicked: {
                    lab.roleIndex = index
                    lab.infoText = "slot " + modelData.label
                                   + " is now the one a click fills"
                  }
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            // The counter is the diagnostic, not decoration: if it moves when the
            // board does not, the bug is in paintPreview; if it does not move, the
            // repaint was never requested. One click answers which, with no rig.
            // Short: this row lives in the 430 px preview column, and the long
            // phrasing ran the number off the window edge where nobody could read it.
            text: "PREVIEW · repaints " + lab.paintCount
            color: Color.menu.text.toString()
            opacity: 0.7
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.body
          }

          Canvas {
            id: previewCanvas
            width: parent.width
            height: Style.space(210)

            // Repaint is driven by PROPERTIES, not only by the imperative
            // requestPaint() in bump(). A property change is what puts the item in
            // the scene-graph's dirty list — the same shape the board canvas uses
            // (Overlay.qml:550 repaints on `onFrameSerialChanged`, never on a bare
            // call), and the reason the board updates ~18x a second while this one
            // sat on its first frame.
            //
            // `pickRef` tracks the whole pick object rather than a counter: assign
            // and clearSlot replace `pick` with a fresh object (never mutate it — a
            // mutated plain object emits nothing), so object identity IS the change
            // signal, and RESET cannot repaint-by-accident-forget-the-counter.
            property var pickRef: lab.pick
            property int opts: lab.fontIndex * 100 + lab.roleIndex * 10 + lab.groupIndex
            onPickRefChanged: requestPaint()
            onOptsChanged: requestPaint()
            // An Item has `width` and `height`, not a consolidated `size` (the shell
            // says so: `Cannot assign to non-existent property "onSizeChanged"`) —
            // the preview is `width: parent.width`, so a window resize must repaint
            // it or the board keeps cells sized for the old width.
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
            // Same reason the board has it: a paint requested before the window is
            // on screen is dropped, and the lab is created by a Loader seconds
            // before anyone looks at it.
            onVisibleChanged: requestPaint()

            // The default pooled-image strategy reuses the previous frame's backing
            // store; Immediate re-runs onPaint over a cleared canvas, so a stale
            // frame is not even representable.
            renderStrategy: Canvas.Immediate

            onPaint: lab.paintPreview(this)
          }

          Rectangle {
            width: parent.width
            height: clearCol.implicitHeight + Style.space(12)
            radius: Style.cornerRadius
            color: Color.menu.selectedBackground.toString()
            border.color: Color.menu.border.toString()
            border.width: 1

            Column {
              id: clearCol
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: Style.space(8)
              spacing: 2

              Text {
                width: parent.width
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                text: lab.infoText
                color: "#e8c33f"
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.body
              }
              Text {
                width: parent.width
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                // Paste-ready: this is the block that comes back to Calcifer.
                text: lab.sumText
                color: Color.menu.selectedText.toString()
                font.family: lab.currentFont
                font.pixelSize: Math.max(8, Style.font.body - 1)
                // No `selectable`: QtQuick's Text has no such property (qmllint:
                // "Could not find property "selectable"" — it belongs to Qt Quick
                // Controls' Text). `c` and the COPY SET button are how this block
                // leaves the window, which is the same thing with fewer parts.
              }
            }
          }

          Row {
            spacing: Style.spacing.sm

            Repeater {
              model: [{ label: "COPY SET (c)" }, { label: "RESET (terminal chars)" },
                      { label: "CLEAR SLOT" }]
              delegate: Rectangle {
                required property var modelData
                required property int index
                width: actLabel.implicitWidth + Style.space(20)
                height: actLabel.implicitHeight + Style.space(10)
                radius: Style.cornerRadius
                color: actMouse.containsMouse ? Color.menu.selectedBackground.toString()
                                              : "transparent"
                border.color: Color.menu.border.toString()
                border.width: 1

                Text {
                  id: actLabel
                  anchors.centerIn: parent
                  textFormat: Text.PlainText
                  text: modelData.label
                  color: Color.menu.text.toString()
                  font.family: Style.font.menuFamily
                  font.pixelSize: Style.font.body
                }
                MouseArea {
                  id: actMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  onClicked: {
                    if (index === 0) lab.copySummary()
                    else if (index === 1) { lab.pick = lab.defaultPicks(); lab.bump() }
                    else lab.clearSlot()
                  }
                }
              }
            }
          }
        }
      }
    }

    // Keys, same shape as the game's catcher: letters come from event.text
    // because the QML Qt object has no Key_<letter> members at all.
    Item {
      id: labKeys
      anchors.fill: parent
      focus: true
      Keys.priority: Keys.BeforeItem

      Keys.onPressed: function(event) {
        if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) {
          event.accepted = true
          return
        }
        var ch = (event.text && event.text.length === 1) ? event.text : ""
        var k = event.key

        // With no catalog loaded, a shelf move has nowhere to land, and an
        // unguarded `% lab.catalog.length` would be `% 0` — NaN, which then
        // poisons every lab.catalog[lab.groupIndex] reader below.
        if (lab.catalog.length === 0 && (k === Qt.Key_Tab || k === Qt.Key_Right
                                         || k === Qt.Key_Left || ch === "g")) {
          event.accepted = true
          return
        }

        if (ch === "q" || k === Qt.Key_Escape) { lab.closeLab() }
        else if (ch === "c") lab.copySummary()
        else if (k === Qt.Key_Tab)
          lab.roleIndex = (lab.roleIndex + 1) % lab.roles.length
        else if (ch === "f")
          lab.fontIndex = (lab.fontIndex + 1) % lab.fonts.length
        else if (ch === "g")
          lab.groupIndex = (lab.groupIndex + 1) % lab.catalog.length
        else if (k === Qt.Key_Right)
          lab.groupIndex = (lab.groupIndex + 1) % lab.catalog.length
        else if (k === Qt.Key_Left)
          lab.groupIndex = (lab.groupIndex - 1 + lab.catalog.length) % lab.catalog.length
        else if (k === Qt.Key_Down)
          catalogScroll.contentY = Math.min(catalogScroll.contentHeight - catalogScroll.height,
                                            catalogScroll.contentY + Style.space(60))
        else if (k === Qt.Key_Up)
          catalogScroll.contentY = Math.max(0, catalogScroll.contentY - Style.space(60))

        // Consumed either way: nothing from the lab should leak to the shell.
        event.accepted = true
      }
    }

    Connections {
      target: labKeys
      function onActiveFocusChanged() {
        if (!labKeys.activeFocus)
          Qt.callLater(function() { labKeys.forceActiveFocus() })
      }
    }

    Component.onCompleted: {
      lab.pick = lab.defaultPicks()
      lab.bump()
      Qt.callLater(function() { labKeys.forceActiveFocus() })
    }
  }

  // ------------------------------------------------------------- the painter
  // A miniature board, 12x5, drawn with the same primitives the real board uses:
  // floor rect, border stroke, one fillText per glyph. Deliberately NOT a copy of
  // the live engine's frame — this is a swatch, so the snake is a fixed, flattering
  // pose (four body cells, three fading corpses, two tokens) rather than a game.
  function paintPreview(canvas) {
    var ctx = canvas.getContext("2d")
    if (!ctx) return
    var w = canvas.width
    var h = canvas.height
    ctx.clearRect(0, 0, w, h)

    var cols = 12
    var rows = 5
    var hud = Style.space(24)
    // The head-glyph row under the board needs its own band, budgeted BEFORE the
    // cell size is derived. Deriving cell from the board alone is what clipped it:
    // a height-capped cell pushed the board's bottom edge to the canvas floor, so
    // the row landed at y > height and simply was not there.
    var headRow = Style.space(28)
    var pad = Style.space(8)
    // The cell is capped by BOTH axes on purpose: a board 2.5x wider than tall
    // would otherwise take a height-capped cell and sit in a wide empty margin
    // (the first screenshots read as an empty field under the preview).
    var cell = Math.max(8, Math.min(Math.floor((h - hud - headRow - pad) / rows),
                                    Math.floor((w - pad) / cols)))
    var left = Math.floor((w - cell * cols) / 2)
    // Vertically centred in the space left for it, so the board never drifts to
    // the top of a tall canvas.
    var top = hud + Math.max(0, Math.floor((h - hud - headRow - cell * rows - pad) / 2))

    // HUD row: the scoring is length, so this is the scoreboard, with the two
    // status badges exactly where the game puts them (right-aligned, yellow).
    ctx.fillStyle = Color.menu.text.toString()
    ctx.font = String(Math.floor(hud * 0.62)) + "px " + lab.currentFont
    ctx.textAlign = "left"
    ctx.textBaseline = "middle"
    ctx.fillText("LEN 08   BEST 12", left, top - hud / 2)

    var badge = ""
    var bh = lab.pick.hunt
    var bw = lab.pick.wrap
    if (bh) badge += bh.ch + " "
    else badge += "AUTO HUNT "
    if (bw) badge += bw.ch
    else badge += "WRAP"
    ctx.fillStyle = "#e8c33f"
    ctx.textAlign = "right"
    ctx.fillText(badge, left + cell * cols, top - hud / 2)

    // Floor + border, same priority as paintBoard: hunt armed burns red-orange.
    ctx.fillStyle = Color.menu.selectedBackground.toString()
    ctx.fillRect(left, top, cell * cols, cell * rows)
    ctx.strokeStyle = lab.pick.hunt ? "#ff7043" : Color.menu.border.toString()
    ctx.lineWidth = 2
    ctx.strokeRect(left + 1, top + 1, cell * cols - 2, cell * rows - 2)

    ctx.textAlign = "center"
    ctx.textBaseline = "middle"
    var fsize = String(Math.floor(cell * 0.86)) + "px " + lab.currentFont
    ctx.font = fsize

    function put(gx, gy, glyph, colour, alpha) {
      if (!glyph) return
      ctx.globalAlpha = alpha === undefined ? 1.0 : alpha
      ctx.fillStyle = colour
      ctx.fillText(glyph.ch, left + gx * cell + cell / 2, top + gy * cell + cell / 2)
      ctx.globalAlpha = 1.0
    }

    var p = lab.pick

    // Corpses first (behind), dimmed like the last third of a wound's ttl.
    put(4, 3, p.corpse, "#e0524b", 0.4)
    put(5, 3, p.corpse, "#e0524b", 0.7)
    put(6, 3, p.corpse, "#e0524b", 1.0)

    // Tokens.
    put(2, 1, p.food, "#41d158")
    put(9, 1, p.food, "#41d158")
    put(10, 4, p.food, "#41d158")

    // Body, tail to head, head last so it wins any overlap.
    put(3, 2, p.body, "#f2f2f2")
    put(4, 2, p.body, "#f2f2f2")
    put(5, 2, p.body, "#f2f2f2")
    put(6, 2, p.body, "#f2f2f2")
    put(7, 2, p.body, "#f2f2f2")
    put(8, 2, p.headRight, "#f2f2f2")

    // The other three head glyphs, in the margin under the board, because the
    // head only ever shows one at a time and that is useless for comparing.
    ctx.font = String(Math.floor(Math.min(cell * 0.72, headRow * 0.78))) + "px " + lab.currentFont
    ctx.fillStyle = "#f2f2f2"
    var y = top + cell * rows + headRow / 2
    var labels = [p.headUp, p.headDown, p.headLeft, p.headRight]
    for (var i = 0; i < labels.length; i++) {
      if (!labels[i]) continue
      ctx.fillText(labels[i].ch, left + cell * (i * 0.75 + 0.4), y)
    }

    lab.paintCount++
  }
}
