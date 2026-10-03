import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Glyph lab: the "what can I actually draw with?" window. Summon it with
//   omarchy-shell shell summon io.github.londelo.tsnake '{"mode":"glyphs"}'
// and it shows every character worth putting on the board, rendered IN THE FONT
// it would be rendered in, with the codepoint and the Unicode name under it.
//
// It is a sibling of the game window, not a child of it: Overlay.qml instantiates
// this through a Loader, so a mistake in this file takes the lab down and leaves
// the game playable. It also starts no engine — the lab is a design tool, and an
// AI-driven snake ticking behind the catalogue would just be noise (and a second
// writer of the high-score file).
//
// Where the data comes from — nothing here is guessed:
//   catalog       generated (see the header above it): official Unicode names from
//                 python unicodedata, coverage from `fc-match "Adwaita Mono:charset="`
//                 against the board font, Nerd Font names from that font's own post
//                 table.
//   fonts[]       every family `fc-list` reports as installed on this box.
//   defaults      the terminal build's own chars: '$' food, 'o' body, '^' 'v' '<' '>'
//                 head (snake.c:792, :806, :816 — the corpse is 'o' in red there,
//                 which is NOT what the overlay paints today: it fills the cell).
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

  // How many times the preview has actually been painted. Not a decoration:
  // 'the preview never refreshed' is unfalsifiable from the outside, and this makes
  // it a number a single click can check. Kept on the root rather than on the Canvas
  // so the canvas never has a binding that depends on its own paint.
  property int paintCount: 0

  // --------------------------------------------------------------- fonts
  // All of these are `fc-list` output from this machine — not a list of fonts
  // that exist in the abstract. The first entry is deliberately the alias the
  // game itself asks for (Style.font.menuFamily, "monospace"), so the lab's
  // default view IS the board as it currently looks.
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

  // The family every c:0/c:1 verdict in the catalog was measured against:
  // `fc-match "Adwaita Mono:charset=XXXX"` (the script is /tmp/cov.sh). The
  // board font is configured as the alias `monospace`, and on this box
  // `fc-match monospace` answers "Adwaita Mono" — so the alias is what the game
  // asks for, and this is the face that actually answers. Naming only the alias
  // in the legend would report a coverage verdict against a font that was never
  // measured; the resolved name is what makes "green = you already have it"
  // checkable.
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
    // Clicking a glyph also puts it on the clipboard, so it can be pasted
    // straight into a chat or an editor. First-party precedent is
    // plugins/panels/network/Panel.qml:450 (tailscale/Service.qml:109 pipes
    // through bash; wl-copy takes argv, so there is nothing to quote here).
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
    // The pasted block is the deliverable, so it says which family to put in the
    // setting AND which face the substitution notes were judged against.
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

  // The catalog. c: 0 in the board font, 1 fontconfig borrows it from `f`,
  // 2 Nerd Font private use, 3 never probed.
  // The generator was a throwaway /tmp script (one fc-match probe per cell) and /tmp
  // gets reaped, so this table is hand-carried data now — adding a cell by hand is
  // fine, guessing its coverage is not: measure it with
  // `fc-match "Adwaita Mono:charset=XXXX"` and trust that over the codepoint's looks.
  // name: python unicodedata (UCD 16.0.0).  coverage: fc-match against
  // the board font "Adwaita Mono" — c:0 native, c:1 fontconfig
  // substitutes it from family f (renders, different metrics), c:2 Nerd
  // Font private use (needs a Nerd Font), c:3 never probed.
  readonly property var catalog: [
    { id:"arrows", label:"ARROWS — steering, the head, hunt badges", note:"direction is the one thing the head must say out loud", cells:[
      {cp:0x2190, ch:"←", n:"LEFTWARDS ARROW", c:0, f:""},
      {cp:0x2191, ch:"↑", n:"UPWARDS ARROW", c:0, f:""},
      {cp:0x2192, ch:"→", n:"RIGHTWARDS ARROW", c:0, f:""},
      {cp:0x2193, ch:"↓", n:"DOWNWARDS ARROW", c:0, f:""},
      {cp:0x21D0, ch:"⇐", n:"LEFTWARDS DOUBLE ARROW", c:0, f:""},
      {cp:0x21D1, ch:"⇑", n:"UPWARDS DOUBLE ARROW", c:0, f:""},
      {cp:0x21D2, ch:"⇒", n:"RIGHTWARDS DOUBLE ARROW", c:0, f:""},
      {cp:0x21D3, ch:"⇓", n:"DOWNWARDS DOUBLE ARROW", c:0, f:""},
      {cp:0x27F5, ch:"⟵", n:"LONG LEFTWARDS ARROW", c:1, f:"JetBrainsMono Nerd Font"},
      {cp:0x27F6, ch:"⟶", n:"LONG RIGHTWARDS ARROW", c:1, f:"JetBrainsMono Nerd Font"},
      {cp:0x27F7, ch:"⟷", n:"LONG LEFT RIGHT ARROW", c:1, f:"JetBrainsMono Nerd Font"},
      {cp:0x27F8, ch:"⟸", n:"LONG LEFTWARDS DOUBLE ARROW", c:1, f:"Adwaita Sans"},
      {cp:0x2794, ch:"➔", n:"HEAVY WIDE-HEADED RIGHTWARDS ARROW", c:0, f:""},
      {cp:0x2799, ch:"➙", n:"HEAVY RIGHTWARDS ARROW", c:1, f:"Noto Sans Symbols 2"},
      {cp:0x279B, ch:"➛", n:"DRAFTING POINT RIGHTWARDS ARROW", c:1, f:"Noto Sans Math"},
      {cp:0x279E, ch:"➞", n:"HEAVY TRIANGLE-HEADED RIGHTWARDS ARROW", c:0, f:""},
      {cp:0x27A2, ch:"➢", n:"THREE-D TOP-LIGHTED RIGHTWARDS ARROWHEAD", c:0, f:""},
      {cp:0x27A4, ch:"➤", n:"BLACK RIGHTWARDS ARROWHEAD", c:0, f:""},
      {cp:0x27A6, ch:"➦", n:"HEAVY BLACK CURVED UPWARDS AND RIGHTWARDS ARROW", c:0, f:""},
      {cp:0x2B92, ch:"⮒", n:"NEWLINE LEFT", c:0, f:""},
      {cp:0x2B93, ch:"⮓", n:"NEWLINE RIGHT", c:0, f:""},
      {cp:0x2B94, ch:"⮔", n:"FOUR CORNER ARROWS CIRCLING ANTICLOCKWISE", c:0, f:""},
      {cp:0x2B95, ch:"⮕", n:"RIGHTWARDS BLACK ARROW", c:0, f:""},
      {cp:0x2B9C, ch:"⮜", n:"BLACK LEFTWARDS EQUILATERAL ARROWHEAD", c:1, f:"Noto Sans Symbols 2"},
      {cp:0x2B9D, ch:"⮝", n:"BLACK UPWARDS EQUILATERAL ARROWHEAD", c:1, f:"Noto Sans Symbols 2"},
      {cp:0x2941, ch:"⥁", n:"CLOCKWISE CLOSED CIRCLE ARROW", c:0, f:""},
    ] },
    { id:"head", label:"HEAD SHAPES — triangles, corners, quadrants", note:"four of these, one per heading, replaces the terminal's ^ v < >", cells:[
      {cp:0x25B2, ch:"▲", n:"BLACK UP-POINTING TRIANGLE", c:0, f:""},
      {cp:0x25BC, ch:"▼", n:"BLACK DOWN-POINTING TRIANGLE", c:0, f:""},
      {cp:0x25B6, ch:"▶", n:"BLACK RIGHT-POINTING TRIANGLE", c:0, f:""},
      {cp:0x25C0, ch:"◀", n:"BLACK LEFT-POINTING TRIANGLE", c:0, f:""},
      {cp:0x25B8, ch:"▸", n:"BLACK RIGHT-POINTING SMALL TRIANGLE", c:0, f:""},
      {cp:0x25C2, ch:"◂", n:"BLACK LEFT-POINTING SMALL TRIANGLE", c:0, f:""},
      {cp:0x25BA, ch:"►", n:"BLACK RIGHT-POINTING POINTER", c:0, f:""},
      {cp:0x25C4, ch:"◄", n:"BLACK LEFT-POINTING POINTER", c:0, f:""},
      {cp:0x25E4, ch:"◤", n:"BLACK UPPER LEFT TRIANGLE", c:0, f:""},
      {cp:0x25E5, ch:"◥", n:"BLACK UPPER RIGHT TRIANGLE", c:0, f:""},
      {cp:0x25E2, ch:"◢", n:"BLACK LOWER RIGHT TRIANGLE", c:0, f:""},
      {cp:0x25E3, ch:"◣", n:"BLACK LOWER LEFT TRIANGLE", c:0, f:""},
      {cp:0x25F0, ch:"◰", n:"WHITE SQUARE WITH UPPER LEFT QUADRANT", c:0, f:""},
      {cp:0x25F1, ch:"◱", n:"WHITE SQUARE WITH LOWER LEFT QUADRANT", c:0, f:""},
      {cp:0x25F2, ch:"◲", n:"WHITE SQUARE WITH LOWER RIGHT QUADRANT", c:0, f:""},
      {cp:0x25F3, ch:"◳", n:"WHITE SQUARE WITH UPPER RIGHT QUADRANT", c:0, f:""},
    ] },
    { id:"blocks", label:"BLOCKS + DOTS — body segments", note:"the body is a solid cell today; these are the alternatives to a plain square", cells:[
      {cp:0x2588, ch:"█", n:"FULL BLOCK", c:0, f:""},
      {cp:0x2593, ch:"▓", n:"DARK SHADE", c:0, f:""},
      {cp:0x2592, ch:"▒", n:"MEDIUM SHADE", c:0, f:""},
      {cp:0x2591, ch:"░", n:"LIGHT SHADE", c:0, f:""},
      {cp:0x2580, ch:"▀", n:"UPPER HALF BLOCK", c:0, f:""},
      {cp:0x2584, ch:"▄", n:"LOWER HALF BLOCK", c:0, f:""},
      {cp:0x258F, ch:"▏", n:"LEFT ONE EIGHTH BLOCK", c:0, f:""},
      {cp:0x258C, ch:"▌", n:"LEFT HALF BLOCK", c:0, f:""},
      {cp:0x258B, ch:"▋", n:"LEFT FIVE EIGHTHS BLOCK", c:0, f:""},
      {cp:0x25A0, ch:"■", n:"BLACK SQUARE", c:0, f:""},
      {cp:0x25A1, ch:"□", n:"WHITE SQUARE", c:0, f:""},
      {cp:0x25AA, ch:"▪", n:"BLACK SMALL SQUARE", c:0, f:""},
      {cp:0x25AB, ch:"▫", n:"WHITE SMALL SQUARE", c:0, f:""},
      {cp:0x25A4, ch:"▤", n:"SQUARE WITH HORIZONTAL FILL", c:0, f:""},
      {cp:0x25A5, ch:"▥", n:"SQUARE WITH VERTICAL FILL", c:0, f:""},
      {cp:0x25A6, ch:"▦", n:"SQUARE WITH ORTHOGONAL CROSSHATCH FILL", c:0, f:""},
      {cp:0x25CF, ch:"●", n:"BLACK CIRCLE", c:0, f:""},
      {cp:0x25CB, ch:"○", n:"WHITE CIRCLE", c:0, f:""},
      {cp:0x25C9, ch:"◉", n:"FISHEYE", c:0, f:""},
      {cp:0x25CE, ch:"◎", n:"BULLSEYE", c:0, f:""},
      {cp:0x25C6, ch:"◆", n:"BLACK DIAMOND", c:0, f:""},
      {cp:0x25C7, ch:"◇", n:"WHITE DIAMOND", c:0, f:""},
      {cp:0x25C8, ch:"◈", n:"WHITE DIAMOND CONTAINING BLACK SMALL DIAMOND", c:0, f:""},
      {cp:0x25D0, ch:"◐", n:"CIRCLE WITH LEFT HALF BLACK", c:0, f:""},
      {cp:0x25D1, ch:"◑", n:"CIRCLE WITH RIGHT HALF BLACK", c:0, f:""},
      {cp:0x25D2, ch:"◒", n:"CIRCLE WITH LOWER HALF BLACK", c:0, f:""},
      {cp:0x25D3, ch:"◓", n:"CIRCLE WITH UPPER HALF BLACK", c:0, f:""},
      {cp:0x25DC, ch:"◜", n:"UPPER LEFT QUADRANT CIRCULAR ARC", c:0, f:""},
      {cp:0x25DD, ch:"◝", n:"UPPER RIGHT QUADRANT CIRCULAR ARC", c:0, f:""},
      {cp:0x25DE, ch:"◞", n:"LOWER RIGHT QUADRANT CIRCULAR ARC", c:0, f:""},
      {cp:0x25DF, ch:"◟", n:"LOWER LEFT QUADRANT CIRCULAR ARC", c:0, f:""},
      {cp:0x25E6, ch:"◦", n:"WHITE BULLET", c:0, f:""},
      {cp:0x25EB, ch:"◫", n:"WHITE SQUARE WITH VERTICAL BISECTING LINE", c:0, f:""},
      {cp:0x25AE, ch:"▮", n:"BLACK VERTICAL RECTANGLE", c:0, f:""},
      {cp:0x25AF, ch:"▯", n:"WHITE VERTICAL RECTANGLE", c:0, f:""},
      {cp:0x2B1B, ch:"⬛", n:"BLACK LARGE SQUARE", c:0, f:""},
      {cp:0x2B1C, ch:"⬜", n:"WHITE LARGE SQUARE", c:0, f:""},
      {cp:0x2B21, ch:"⬡", n:"WHITE HEXAGON", c:0, f:""},
      {cp:0x2B22, ch:"⬢", n:"BLACK HEXAGON", c:0, f:""},
      {cp:0x2B23, ch:"⬣", n:"HORIZONTAL BLACK HEXAGON", c:0, f:""},
      {cp:0x2B24, ch:"⬤", n:"BLACK LARGE CIRCLE", c:0, f:""},
      {cp:0x2B25, ch:"⬥", n:"BLACK MEDIUM DIAMOND", c:0, f:""},
      {cp:0x2B26, ch:"⬦", n:"WHITE MEDIUM DIAMOND", c:0, f:""},
    ] },
    { id:"braille", label:"BRAILLE — dense 2x4 dot cells", note:"reads as texture at small cell sizes; U+2800 is the blank cell", cells:[
      {cp:0x2800, ch:"⠀", n:"BRAILLE PATTERN BLANK", c:0, f:""},
      {cp:0x2837, ch:"⠷", n:"BRAILLE PATTERN DOTS-12356", c:0, f:""},
      {cp:0x2847, ch:"⡇", n:"BRAILLE PATTERN DOTS-1237", c:0, f:""},
      {cp:0x289B, ch:"⢛", n:"BRAILLE PATTERN DOTS-12458", c:0, f:""},
      {cp:0x28A7, ch:"⢧", n:"BRAILLE PATTERN DOTS-12368", c:0, f:""},
      {cp:0x28BF, ch:"⢿", n:"BRAILLE PATTERN DOTS-1234568", c:0, f:""},
      {cp:0x28FF, ch:"⣿", n:"BRAILLE PATTERN DOTS-12345678", c:0, f:""},
    ] },
    { id:"box", label:"BOX DRAWING — borders, grid lines", note:"the border is painted today; these are how a glyph border would look", cells:[
      {cp:0x2500, ch:"─", n:"BOX DRAWINGS LIGHT HORIZONTAL", c:0, f:""},
      {cp:0x2501, ch:"━", n:"BOX DRAWINGS HEAVY HORIZONTAL", c:0, f:""},
      {cp:0x2502, ch:"│", n:"BOX DRAWINGS LIGHT VERTICAL", c:0, f:""},
      {cp:0x2503, ch:"┃", n:"BOX DRAWINGS HEAVY VERTICAL", c:0, f:""},
      {cp:0x250C, ch:"┌", n:"BOX DRAWINGS LIGHT DOWN AND RIGHT", c:0, f:""},
      {cp:0x2510, ch:"┐", n:"BOX DRAWINGS LIGHT DOWN AND LEFT", c:0, f:""},
      {cp:0x2514, ch:"└", n:"BOX DRAWINGS LIGHT UP AND RIGHT", c:0, f:""},
      {cp:0x2518, ch:"┘", n:"BOX DRAWINGS LIGHT UP AND LEFT", c:0, f:""},
      {cp:0x250F, ch:"┏", n:"BOX DRAWINGS HEAVY DOWN AND RIGHT", c:0, f:""},
      {cp:0x2513, ch:"┓", n:"BOX DRAWINGS HEAVY DOWN AND LEFT", c:0, f:""},
      {cp:0x2517, ch:"┗", n:"BOX DRAWINGS HEAVY UP AND RIGHT", c:0, f:""},
      {cp:0x251B, ch:"┛", n:"BOX DRAWINGS HEAVY UP AND LEFT", c:0, f:""},
      {cp:0x251C, ch:"├", n:"BOX DRAWINGS LIGHT VERTICAL AND RIGHT", c:0, f:""},
      {cp:0x2524, ch:"┤", n:"BOX DRAWINGS LIGHT VERTICAL AND LEFT", c:0, f:""},
      {cp:0x252C, ch:"┬", n:"BOX DRAWINGS LIGHT DOWN AND HORIZONTAL", c:0, f:""},
      {cp:0x2534, ch:"┴", n:"BOX DRAWINGS LIGHT UP AND HORIZONTAL", c:0, f:""},
      {cp:0x253C, ch:"┼", n:"BOX DRAWINGS LIGHT VERTICAL AND HORIZONTAL", c:0, f:""},
      {cp:0x254C, ch:"╌", n:"BOX DRAWINGS LIGHT DOUBLE DASH HORIZONTAL", c:0, f:""},
      {cp:0x254D, ch:"╍", n:"BOX DRAWINGS HEAVY DOUBLE DASH HORIZONTAL", c:0, f:""},
      {cp:0x2550, ch:"═", n:"BOX DRAWINGS DOUBLE HORIZONTAL", c:0, f:""},
      {cp:0x2551, ch:"║", n:"BOX DRAWINGS DOUBLE VERTICAL", c:0, f:""},
      {cp:0x2506, ch:"┆", n:"BOX DRAWINGS LIGHT TRIPLE DASH VERTICAL", c:0, f:""},
      {cp:0x2508, ch:"┈", n:"BOX DRAWINGS LIGHT QUADRUPLE DASH HORIZONTAL", c:0, f:""},
      {cp:0x250A, ch:"┊", n:"BOX DRAWINGS LIGHT QUADRUPLE DASH VERTICAL", c:0, f:""},
    ] },
    { id:"dingbats", label:"DINGBATS — food tokens, sparks", note:"stars, snowflakes, scissors: the stylish token shelf", cells:[
      {cp:0x2605, ch:"★", n:"BLACK STAR", c:0, f:""},
      {cp:0x2606, ch:"☆", n:"WHITE STAR", c:0, f:""},
      {cp:0x2733, ch:"✳", n:"EIGHT SPOKED ASTERISK", c:0, f:""},
      {cp:0x2734, ch:"✴", n:"EIGHT POINTED BLACK STAR", c:0, f:""},
      {cp:0x2736, ch:"✶", n:"SIX POINTED BLACK STAR", c:0, f:""},
      {cp:0x2739, ch:"✹", n:"TWELVE POINTED BLACK STAR", c:0, f:""},
      {cp:0x273B, ch:"✻", n:"TEARDROP-SPOKED ASTERISK", c:0, f:""},
      {cp:0x273C, ch:"✼", n:"OPEN CENTRE TEARDROP-SPOKED ASTERISK", c:0, f:""},
      {cp:0x273E, ch:"✾", n:"SIX PETALLED BLACK AND WHITE FLORETTE", c:0, f:""},
      {cp:0x273F, ch:"✿", n:"BLACK FLORETTE", c:0, f:""},
      {cp:0x2740, ch:"❀", n:"WHITE FLORETTE", c:0, f:""},
      {cp:0x2741, ch:"❁", n:"EIGHT PETALLED OUTLINED BLACK FLORETTE", c:0, f:""},
      {cp:0x2742, ch:"❂", n:"CIRCLED OPEN CENTRE EIGHT POINTED STAR", c:0, f:""},
      {cp:0x2746, ch:"❆", n:"HEAVY CHEVRON SNOWFLAKE", c:0, f:""},
      {cp:0x2748, ch:"❈", n:"HEAVY SPARKLE", c:0, f:""},
      {cp:0x2749, ch:"❉", n:"BALLOON-SPOKED ASTERISK", c:0, f:""},
      {cp:0x274B, ch:"❋", n:"HEAVY EIGHT TEARDROP-SPOKED PROPELLER ASTERISK", c:0, f:""},
      {cp:0x274D, ch:"❍", n:"SHADOWED WHITE CIRCLE", c:1, f:"Noto Sans Symbols 2"},
      {cp:0x274F, ch:"❏", n:"LOWER RIGHT DROP-SHADOWED WHITE SQUARE", c:1, f:"Noto Sans Symbols 2"},
      {cp:0x2750, ch:"❐", n:"UPPER RIGHT DROP-SHADOWED WHITE SQUARE", c:1, f:"Noto Sans Symbols 2"},
      {cp:0x2751, ch:"❑", n:"LOWER RIGHT SHADOWED WHITE SQUARE", c:1, f:"Noto Sans Symbols 2"},
      {cp:0x2752, ch:"❒", n:"UPPER RIGHT SHADOWED WHITE SQUARE", c:1, f:"Noto Sans Symbols 2"},
      {cp:0x2756, ch:"❖", n:"BLACK DIAMOND MINUS WHITE X", c:0, f:""},
      {cp:0x2758, ch:"❘", n:"LIGHT VERTICAL BAR", c:0, f:""},
      {cp:0x275A, ch:"❚", n:"HEAVY VERTICAL BAR", c:0, f:""},
      {cp:0x2720, ch:"✠", n:"MALTESE CROSS", c:0, f:""},
      {cp:0x271A, ch:"✚", n:"HEAVY GREEK CROSS", c:0, f:""},
      {cp:0x271B, ch:"✛", n:"OPEN CENTRE CROSS", c:0, f:""},
      {cp:0x271C, ch:"✜", n:"HEAVY OPEN CENTRE CROSS", c:0, f:""},
      {cp:0x271D, ch:"✝", n:"LATIN CROSS", c:0, f:""},
      {cp:0x271E, ch:"✞", n:"SHADOWED WHITE LATIN CROSS", c:1, f:"Noto Sans Symbols"},
      {cp:0x271F, ch:"✟", n:"OUTLINED LATIN CROSS", c:1, f:"Noto Sans Symbols"},
      {cp:0x274C, ch:"❌", n:"CROSS MARK", c:0, f:""},
      {cp:0x274E, ch:"❎", n:"NEGATIVE SQUARED CROSS MARK", c:0, f:""},
      {cp:0x2757, ch:"❗", n:"HEAVY EXCLAMATION MARK SYMBOL", c:1, f:"Noto Color Emoji"},
    ] },
    { id:"misc", label:"MISC SYMBOLS — suits, badges, status", note:"cards, music, weather, checks: HUD and status-label material", cells:[
      {cp:0x2620, ch:"☠", n:"SKULL AND CROSSBONES", c:1, f:"Noto Color Emoji"},
      {cp:0x2622, ch:"☢", n:"RADIOACTIVE SIGN", c:1, f:"Noto Color Emoji"},
      {cp:0x2623, ch:"☣", n:"BIOHAZARD SIGN", c:1, f:"Noto Color Emoji"},
      {cp:0x263A, ch:"☺", n:"WHITE SMILING FACE", c:0, f:""},
      {cp:0x2639, ch:"☹", n:"WHITE FROWNING FACE", c:0, f:""},
      {cp:0x2660, ch:"♠", n:"BLACK SPADE SUIT", c:0, f:""},
      {cp:0x2663, ch:"♣", n:"BLACK CLUB SUIT", c:0, f:""},
      {cp:0x2665, ch:"♥", n:"BLACK HEART SUIT", c:0, f:""},
      {cp:0x2666, ch:"♦", n:"BLACK DIAMOND SUIT", c:0, f:""},
      {cp:0x266A, ch:"♪", n:"EIGHTH NOTE", c:0, f:""},
      {cp:0x266D, ch:"♭", n:"MUSIC FLAT SIGN", c:0, f:""},
      {cp:0x266F, ch:"♯", n:"MUSIC SHARP SIGN", c:0, f:""},
      {cp:0x2691, ch:"⚑", n:"BLACK FLAG", c:0, f:""},
      {cp:0x2693, ch:"⚓", n:"ANCHOR", c:1, f:"Noto Color Emoji"},
      {cp:0x2696, ch:"⚖", n:"SCALES", c:1, f:"Noto Color Emoji"},
      {cp:0x2699, ch:"⚙", n:"GEAR", c:0, f:""},
      {cp:0x26A0, ch:"⚠", n:"WARNING SIGN", c:0, f:""},
      {cp:0x26A1, ch:"⚡", n:"HIGH VOLTAGE SIGN", c:0, f:""},
      {cp:0x26B0, ch:"⚰", n:"COFFIN", c:1, f:"Noto Color Emoji"},
      {cp:0x26BD, ch:"⚽", n:"SOCCER BALL", c:1, f:"Noto Sans Mono CJK KR"},
      {cp:0x26BE, ch:"⚾", n:"BASEBALL", c:1, f:"Noto Sans Mono CJK KR"},
      {cp:0x26C4, ch:"⛄", n:"SNOWMAN WITHOUT SNOW", c:1, f:"Noto Color Emoji"},
      {cp:0x26CF, ch:"⛏", n:"PICK", c:1, f:"Noto Color Emoji"},
      {cp:0x26D3, ch:"⛓", n:"CHAINS", c:1, f:"Noto Color Emoji"},
      {cp:0x26D4, ch:"⛔", n:"NO ENTRY", c:1, f:"Noto Color Emoji"},
      {cp:0x26F2, ch:"⛲", n:"FOUNTAIN", c:1, f:"Noto Color Emoji"},
      {cp:0x26F9, ch:"⛹", n:"PERSON WITH BALL", c:1, f:"Noto Color Emoji"},
      {cp:0x26FD, ch:"⛽", n:"FUEL PUMP", c:1, f:"Noto Color Emoji"},
      {cp:0x2020, ch:"†", n:"DAGGER", c:0, f:""},
      {cp:0x2021, ch:"‡", n:"DOUBLE DAGGER", c:0, f:""},
      {cp:0x203C, ch:"‼", n:"DOUBLE EXCLAMATION MARK", c:0, f:""},
      {cp:0x2049, ch:"⁉", n:"EXCLAMATION QUESTION MARK", c:0, f:""},
      {cp:0x2042, ch:"⁂", n:"ASTERISM", c:0, f:""},
      {cp:0x221E, ch:"∞", n:"INFINITY", c:0, f:""},
      {cp:0x2295, ch:"⊕", n:"CIRCLED PLUS", c:0, f:""},
      {cp:0x2297, ch:"⊗", n:"CIRCLED TIMES", c:0, f:""},
      {cp:0x2299, ch:"⊙", n:"CIRCLED DOT OPERATOR", c:0, f:""},
      {cp:0x22EE, ch:"⋮", n:"VERTICAL ELLIPSIS", c:0, f:""},
      {cp:0x22EF, ch:"⋯", n:"MIDLINE HORIZONTAL ELLIPSIS", c:0, f:""},
      {cp:0x2B58, ch:"⭘", n:"HEAVY CIRCLE", c:0, f:""},
      {cp:0x23F1, ch:"⏱", n:"STOPWATCH", c:0, f:""},
      {cp:0x23F8, ch:"⏸", n:"DOUBLE VERTICAL BAR", c:0, f:""},
      {cp:0x23F9, ch:"⏹", n:"BLACK SQUARE FOR STOP", c:0, f:""},
      {cp:0x23FA, ch:"⏺", n:"BLACK CIRCLE FOR RECORD", c:0, f:""},
      {cp:0x00A7, ch:"§", n:"SECTION SIGN", c:0, f:""},
      {cp:0x00B6, ch:"¶", n:"PILCROW SIGN", c:0, f:""},
      {cp:0x2039, ch:"‹", n:"SINGLE LEFT-POINTING ANGLE QUOTATION MARK", c:0, f:""},
      {cp:0x203A, ch:"›", n:"SINGLE RIGHT-POINTING ANGLE QUOTATION MARK", c:0, f:""},
      {cp:0x00AB, ch:"«", n:"LEFT-POINTING DOUBLE ANGLE QUOTATION MARK", c:0, f:""},
      {cp:0x00BB, ch:"»", n:"RIGHT-POINTING DOUBLE ANGLE QUOTATION MARK", c:0, f:""},
      {cp:0x2022, ch:"•", n:"BULLET", c:0, f:""},
      {cp:0x2219, ch:"∙", n:"BULLET OPERATOR", c:0, f:""},
      {cp:0x22C5, ch:"⋅", n:"DOT OPERATOR", c:0, f:""},
    ] },
    { id:"emoji", label:"EMOJI — colour, always a substitution", note:"colour on the board costs a font switch: none of these are in the mono face", cells:[
      {cp:0x1F34D, ch:"🍍", n:"PINEAPPLE", c:1, f:"Noto Color Emoji"},
      {cp:0x1F34E, ch:"🍎", n:"RED APPLE", c:1, f:"Noto Color Emoji"},
      {cp:0x1F347, ch:"🍇", n:"GRAPES", c:1, f:"Noto Color Emoji"},
      {cp:0x1F40D, ch:"🐍", n:"SNAKE", c:1, f:"Noto Color Emoji"},
      {cp:0x1F48E, ch:"💎", n:"GEM STONE", c:1, f:"Noto Color Emoji"},
      {cp:0x1F4A5, ch:"💥", n:"COLLISION SYMBOL", c:1, f:"Noto Color Emoji"},
      {cp:0x1F525, ch:"🔥", n:"FIRE", c:1, f:"Noto Color Emoji"},
      {cp:0x1F47E, ch:"👾", n:"ALIEN MONSTER", c:1, f:"Noto Color Emoji"},
      {cp:0x1F480, ch:"💀", n:"SKULL", c:1, f:"Noto Color Emoji"},
      {cp:0x1F3AE, ch:"🎮", n:"VIDEO GAME", c:1, f:"Noto Color Emoji"},
      {cp:0x1F300, ch:"🌀", n:"CYCLONE", c:1, f:"Noto Color Emoji"},
      {cp:0x1F52B, ch:"🔫", n:"PISTOL", c:1, f:"Noto Color Emoji"},
      {cp:0x1F6C1, ch:"🛁", n:"BATHTUB", c:1, f:"Noto Color Emoji"},
    ] },
    { id:"nerd", label:"NERD FONT — icons from JetBrainsMono NF", note:"private use: only JetBrainsMono Nerd Font has these; names are the font's own post table", cells:[
      {cp:0xF04B, ch:"", n:"fa-play", c:2, f:"JetBrainsMono Nerd Font"},
      {cp:0xF04C, ch:"", n:"fa-pause", c:2, f:"JetBrainsMono Nerd Font"},
      {cp:0xF04D, ch:"", n:"fa-stop", c:2, f:"JetBrainsMono Nerd Font"},
      {cp:0xF11B, ch:"", n:"fa-gamepad", c:2, f:"JetBrainsMono Nerd Font"},
      {cp:0xF1B0, ch:"", n:"fa-paw", c:2, f:"JetBrainsMono Nerd Font"},
      {cp:0xF0E7, ch:"", n:"fa-flash", c:2, f:"JetBrainsMono Nerd Font"},
      {cp:0xF140, ch:"", n:"fa-bullseye", c:2, f:"JetBrainsMono Nerd Font"},
      {cp:0xF192, ch:"", n:"fa-dot_circle_o", c:2, f:"JetBrainsMono Nerd Font"},
      {cp:0xF21E, ch:"", n:"fa-heartbeat", c:2, f:"JetBrainsMono Nerd Font"},
      {cp:0xF185, ch:"", n:"fa-sun_o", c:2, f:"JetBrainsMono Nerd Font"},
      {cp:0xF06C, ch:"", n:"fa-leaf", c:2, f:"JetBrainsMono Nerd Font"},
      {cp:0xF188, ch:"", n:"fa-bug", c:2, f:"JetBrainsMono Nerd Font"},
      {cp:0xF0EB, ch:"", n:"fa-lightbulb_o", c:2, f:"JetBrainsMono Nerd Font"},
      {cp:0xF075, ch:"", n:"fa-comment", c:2, f:"JetBrainsMono Nerd Font"},
      {cp:0xF00C, ch:"", n:"fa-check", c:2, f:"JetBrainsMono Nerd Font"},
      {cp:0xF0C9, ch:"", n:"fa-reorder", c:2, f:"JetBrainsMono Nerd Font"},
      {cp:0xF0C0, ch:"", n:"fa-users", c:2, f:"JetBrainsMono Nerd Font"},
      {cp:0xF072, ch:"", n:"fa-plane", c:2, f:"JetBrainsMono Nerd Font"},
      {cp:0xF074, ch:"", n:"fa-shuffle", c:2, f:"JetBrainsMono Nerd Font"},
      {cp:0xE71F, ch:"", n:"dev-ghost", c:2, f:"JetBrainsMono Nerd Font"},
      {cp:0xE795, ch:"", n:"dev-terminal", c:2, f:"JetBrainsMono Nerd Font"},
      {cp:0xEA85, ch:"", n:"cod-terminal", c:2, f:"JetBrainsMono Nerd Font"},
      {cp:0xE227, ch:"", n:"fae-mushroom", c:2, f:"JetBrainsMono Nerd Font"},
      {cp:0xE22D, ch:"", n:"fae-pizza", c:2, f:"JetBrainsMono Nerd Font"},
      {cp:0xE251, ch:"", n:"fae-hotdog", c:2, f:"JetBrainsMono Nerd Font"},
      {cp:0xE24D, ch:"", n:"fae-hamburger", c:2, f:"JetBrainsMono Nerd Font"},
      {cp:0xE261, ch:"", n:"fae-chess_pawn", c:2, f:"JetBrainsMono Nerd Font"},
      {cp:0xE26E, ch:"", n:"fae-crown", c:2, f:"JetBrainsMono Nerd Font"},
      {cp:0xE27F, ch:"", n:"fae-atom", c:2, f:"JetBrainsMono Nerd Font"},
      {cp:0xE23A, ch:"", n:"fae-real_heart", c:2, f:"JetBrainsMono Nerd Font"},
      {cp:0xE370, ch:"", n:"weather-stars", c:2, f:"JetBrainsMono Nerd Font"},
      {cp:0xE3BF, ch:"", n:"weather-fire", c:2, f:"JetBrainsMono Nerd Font"},
      {cp:0xE658, ch:"", n:"seti-firefox", c:2, f:"JetBrainsMono Nerd Font"},
      {cp:0xE73C, ch:"", n:"dev-python", c:2, f:"JetBrainsMono Nerd Font"},
    ] },
  ]

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
        textFormat: Text.PlainText
        // currentFont, never the alias: "already in monospace" is a fontconfig
        // *query*, and answering a coverage question with an alias hides which
        // face the answer came from (here it resolves to Adwaita Mono).
        // The verdicts are measured against probeFont, not against whatever chip
        // is selected: switching the shelf to Noto Color Emoji does not change
        // which glyphs Adwaita Mono has.
        text: lab.catalog[lab.groupIndex].note
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
