import QtQuick
import qs.Ui

// Bar entry for the overlay. Shape copied from
// /usr/share/omarchy/shell/plugins/menu/BarWidget.qml:1-24 — a BarWidget sized
// to its WidgetButton, whose press goes through the bar host's run() to the
// shell's IPC `toggle`, never straight at the overlay itself.
//
// It deliberately holds no game state and launches no engine: the widget lives
// in the bar for the whole session, and a process started from here would be
// invisible-but-running the moment the overlay closed. The engine's whole life
// is owned by Overlay.qml.
//
// The label is plain text rather than an "omarchy" icon-font codepoint: the
// icon font has no glyph I could verify reads as a snake, and a wrong
// private-use value renders tofu in the bar.
BarWidget {
  id: root
  moduleName: "io.github.londelo.tsnake"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "tsnake"
    horizontalMargin: 7.5
    tooltipText: "Play tsnake"
    onPressed: function(button) {
      if (!root.bar) return
      else root.bar.run("omarchy-shell shell toggle io.github.londelo.tsnake '{}'")
    }
  }
}
