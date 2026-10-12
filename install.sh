#!/usr/bin/env bash
# omarchy:summary=Install tsnake into the Omarchy shell's plugin folder
# omarchy:group=plugin
# omarchy:args=[--fresh]
#
# Installs the plugin from this checkout into ~/.config/omarchy/plugins/<id>.
# Run it after changing snake.c or any .qml; then summon the overlay.
#
#   --fresh   uninstall first (omarchy-plugin-remove) and re-enable after, so the
#             shell tears the panel item down and builds it again. Use this when
#             the overlay on screen is not the code in this folder.
#
# The entry point is copied under its REAL name, Overlay.qml. (It used to be copied to a
# content-hashed name; see the note at ENTRY below for what that bought and why it is gone.)
#
# So cache staleness is handled the way the shell actually supports: whenever the QML or the
# binary in this checkout differ from the installed folder, this script takes the REMOVAL
# path (omarchy-plugin-remove → setPluginEnabled false + rescanPlugins at a quiet moment, and
# it says so: "was unloaded from omarchy-shell"), which is the one path proven to unload the
# live item and clear its cached component. --fresh forces that path even when nothing
# differs. Writing state into the watched folder is still forbidden (below) — this is about
# deploying code, not about saving.
#
# The record and the card's settings do NOT live in this folder, and must never again. They
# sit under $XDG_STATE_HOME (else ~/.local/state)/tsnake, which is where the overlay points
# the engine (--state/--setup, Overlay.qml:stateDir), and the reason is the watcher: the
# shell inotify-watches ~/.config/omarchy/plugins, so a save written there is a panel reload
# taken out from under the player — which is exactly why the engine used to defer its saves
# and why deferring them lost every one. Two consequences for this script: neither a reinstall
# nor --fresh can cost anyone a high score any more (there is nothing to park), and neither
# can erase one either — `omarchy-plugin-remove` leaves the state folder standing, on purpose,
# because the host has no lifecycle hook and no manifest field by which a plugin could name its
# data (proven: grep /usr/share/omarchy for uninstall|purge|dataDir|stateDir). So the removal
# half is ./uninstall.sh, which is the command that knows where all of tsnake is: it takes the
# code through omarchy-plugin-remove and the record with it, deliberately, the way the host's
# own plugins clear their own state behind their own confirmation.
#
# What IS left here is migration: installs before this change wrote $DEST/{highscore,setup},
# so those bytes are carried into the state dir (the record may only ever go UP, and the
# setup only ever fills a hole) before the folder they lived in is replaced. The state root is
# spelled the same way Overlay.qml spells it; the two have to agree or the card reads one
# file and this script migrates another.

set -euo pipefail

ID="io.github.londelo.tsnake"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGINS_DIR="${TSNAKE_PLUGINS_DIR:-$HOME/.config/omarchy/plugins}"
DEST="$PLUGINS_DIR/$ID"
FRESH=0

fail() { echo "tsnake-install: $*" >&2; exit 1; }

while (( $# > 0 )); do
  case "$1" in
  --fresh) FRESH=1; shift ;;
  -h | --help)
    echo "Usage: ./install.sh [--fresh]"
    exit 0
    ;;
  *) fail "unknown option: $1" ;;
  esac
done

command -v jq >/dev/null || fail "jq is required (the manifest is rewritten at install time)"
[[ $ID =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "refusing a plugin id with anything odd in it: $ID"

make -C "$SRC" snake >/dev/null
[[ -x $SRC/snake ]] || fail "build produced no ./snake"

# The entry point keeps its real name. No hashing, no decoration.
#
# What this script used to believe, and the measurement that killed it: the entry was copied
# to a content-hashed name (`Overlay-<hash>.qml`, then `Overlay<hash>.qml`) to dodge Qt's
# per-URL compiled-component cache, and a summon then failed with
# `WARN scene: file:///…/Overlay1ad023a598ab.qml[-1:-1]: File name case mismatch` plus the
# host's masked `@shell.qml[1357]: ReferenceError: errorString is not defined` (the host's own
# error handler is broken, so the message that would have explained it was swallowed). The
# conclusion drawn then — that Qt objects to the NAME — was wrong: renaming the entry back to
# plain `Overlay.qml` produced the identical warning, and what actually fixed the summon was
# `omarchy-restart-shell`. Read the warning as "this shell process can no longer resolve
# anything in this folder", not as a comment on the file name: churning the plugin folder
# under a running shell poisons its type/directory index, a rescan does not clear it, and only
# a restart does. That is also why installs here go through the removal path (below).
#
# The hashed name stays gone on its own merits: it was never once proven to load, and all 102
# .qml files under /usr/share/omarchy/shell are named with letters and dots alone.
ENTRY="Overlay.qml"

# ---- the player's two files: out of the watched folder, into the state root ----
# Spelled exactly the way Overlay.qml:stateDir spells it, because the engine reads what the
# overlay names and this script must carry the old bytes to that same name.
STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}"
STATE_ROOT="${STATE_ROOT%/}/tsnake"

# The digits in a record file, or 0 for anything unreadable or unparseable. This script is
# not a writer of records — it never lowers one and never invents one; it only refuses to
# lose one that is already on disk.
best_in() {
  if [[ ! -f $1 ]]; then echo 0; return; fi
  local n
  n="$(tr -dc '0-9' <"$1" 2>/dev/null)"
  if [[ -n $n ]]; then echo "$((10#$n))"; else echo 0; fi
}

# Installs before this change kept {highscore,setup} inside $DEST, which the uninstall and
# every reinstall deletes — so move them first, BEFORE anything (including --fresh's
# omarchy-plugin-remove) can take the folder out from under them. Then drop the copies:
# two `delete` events to the watcher, once, on a machine that still has the old layout.
migrate_state() {
  [[ -d $DEST ]] || return 0
  mkdir -p "$STATE_ROOT" 2>/dev/null && chmod 700 "$STATE_ROOT" 2>/dev/null
  # If the state root cannot be built, say so and keep going: the engine mkdir -p's its own
  # parent chain on the first save (snake.c:ensure_parent_dir), so a failed migration here
  # is a lost legacy number, not a game that can never save.
  local f old new
  for f in highscore setup; do
    old="$DEST/$f"
    new="$STATE_ROOT/$f"
    [[ -f $old ]] || continue
    if [[ $f == highscore ]]; then
      if (( $(best_in "$old") > $(best_in "$new") )); then
        install -m 0600 "$old" "$new" 2>/dev/null || true
      fi
    elif [[ ! -s $new ]]; then                     # the live setup wins; this only fills a hole
      install -m 0600 "$old" "$new" 2>/dev/null || true
    fi
    rm -f "$old"
  done
  return 0
}
migrate_state

STAGE=""
cleanup_stage() {
  if [[ -n $STAGE && -d $STAGE ]]; then rm -rf "$STAGE"; fi
}
trap cleanup_stage EXIT

REMOVED=0
take_the_removal_path() {
  [[ -d $DEST ]] || return 0
  (( REMOVED )) && return 0
  # Bring the window down first: unloading the panel item under a live engine leaves the
  # child's last frames painting a surface that no longer exists.
  omarchy-shell shell hide "$ID" >/dev/null 2>&1 || true
  # The removal path is the shell's own documented unload: it sets the plugin disabled and
  # rescans at a quiet moment, which is what clears the Instantiator's delegates and Qt's
  # cached compiled component for this URL. Every "the overlay on screen is not the code in
  # this folder" report this project has had ended here, and nowhere else.
  omarchy-plugin-remove "$ID" --yes >/dev/null 2>&1 || true
  REMOVED=1
}

# Build the whole folder OUTSIDE the watched tree, then move it in as one rename.
#
# Every create/close_write under ~/.config/omarchy/plugins is a reload request
# (services/PluginRegistry.qml:663), and reloadPlugins (shell.qml:1452) answers a
# request that lands while one is already in flight by latching pluginReloadPending
# and returning — after shell.unloadPanels() has already set panelEntries = [].
# Nothing restores it but an onScanFinished that never comes, so the Instantiator at
# shell.qml:1322 has no delegates, no panel Loaders exist, and summon answers "ok"
# while loading nothing: a dead bar button with a live-looking widget in the bar.
# Measured: seven files written one at a time = 18 "Local plugin changed, reloading"
# lines in one second, and the overlay never loaded again until the shell restarted.
#
# A dot-prefixed path is dropped outright by localPluginIdForPath
# (PluginRegistry.qml:728-740, "Hidden entries are not plugins: clone staging dirs,
# remove backups") — the watcher never even asks for a reload — so staging there is
# silent and the swap itself costs two events instead of eighteen.
# A no-op install must be literally silent: if every byte is already what the repo
# says, the folder is not touched at all, so the watcher sees nothing and the shell
# is never asked to reload for nothing.
already_installed() {
  [[ -d $DEST ]] || return 1
  cmp -s "$SRC/snake" "$DEST/snake" || return 1
  cmp -s "$SRC/Overlay.qml" "$DEST/$ENTRY" || return 1
  local f
  for f in BarWidget.qml GlyphLab.qml data/glyphs.json docs/decisions.md docs/protocol.md; do
    cmp -s "$SRC/$f" "$DEST/$f" || return 1
  done
  jq -e --arg entry "$ENTRY" '.entryPoints.overlay == $entry' "$DEST/manifest.json" \
    >/dev/null 2>&1 || return 1
  [[ -z $(find "$DEST" -maxdepth 1 \( -name 'Overlay[a-z0-9]*.qml' -o \
    -name 'Overlay_*.qml' -o -name 'Overlay-*.qml' \) ! -name "$ENTRY" -print -quit) ]] || return 1
  return 0
}

if (( ! FRESH )) && already_installed; then
  echo "already installed, nothing written: $DEST"
  echo "then:  omarchy-shell shell summon $ID"
  exit 0
fi

# Getting here means the installed folder is not what this checkout says (or --fresh was
# asked for), which is exactly the situation where the shell can still be holding the OLD
# compiled component for this URL. Unload it through the shell's removal path before
# replacing the bytes; staging over a live item leaves the live item on screen.
take_the_removal_path

STAGE="$PLUGINS_DIR/.$ID.stage.$$"
rm -rf "$STAGE"
mkdir -m 0755 "$STAGE"
install -m 0755 "$SRC/snake" "$STAGE/snake"
install -m 0644 "$SRC/Overlay.qml" "$STAGE/$ENTRY"
install -m 0644 "$SRC/BarWidget.qml" "$STAGE/BarWidget.qml"
install -m 0644 "$SRC/GlyphLab.qml" "$STAGE/GlyphLab.qml"
mkdir -p "$STAGE/data" "$STAGE/docs"
install -m 0644 "$SRC/data/glyphs.json" "$STAGE/data/glyphs.json"
install -m 0644 "$SRC/docs/decisions.md" "$STAGE/docs/decisions.md"
install -m 0644 "$SRC/docs/protocol.md" "$STAGE/docs/protocol.md"
# Both copies are data the plugin folder carries, not code it loads. uninstall.sh because the
# row that runs it says `cd "$HOME/.config/omarchy/plugins/io.github.londelo.tsnake" &&
# ./uninstall.sh -i` and a menu row runs from an arbitrary working directory; omarchy-menu.jsonc
# because ~/.config/omarchy/extensions/ is USER config that predates tsnake, so the merge below
# reads the live file and this copy is kept beside it as the record of what tsnake declares.
install -m 0755 "$SRC/uninstall.sh" "$STAGE/uninstall.sh"
install -m 0644 "$SRC/omarchy-menu.jsonc" "$STAGE/omarchy-menu.jsonc"

# The manifest points at this content's URL. Built here, never committed: a plain
# checkout still carries "Overlay.qml" as its entry point.
jq --arg entry "$ENTRY" '.entryPoints.overlay = $entry' "$SRC/manifest.json" \
  >"$STAGE/manifest.json"
chmod 0644 "$STAGE/manifest.json"
jq -e --arg entry "$ENTRY" '.entryPoints.overlay == $entry' "$STAGE/manifest.json" >/dev/null \
  || fail "generated manifest does not point at $ENTRY"

# Verified while the old install is still intact: a bad copy must never be the
# reason the working folder is gone.
#
# WHY $STAGE IS NOT THE REPO: it is built beside the live install, under
# $XDG_STATE_HOME/omarchy/scratch (or the system /tmp), and only `mv`'d into the watched
# plugins folder once the whole folder is ready, because `mv` inside one filesystem is atomic —
# the shell sees the new folder all at once, and the folder has no `.git`, so a removal leaves
# no litter to undo a `git pull`. A symlink to the repo is not in play either: coreutils
# resolves a script's symlink against the real file, so a linked install.sh would have resolved
# to this dev checkout — an edit here would silently change what an installed shell ran.
#
# So every file in the bundle is a COPY, and $STAGE holds exactly what $DEST will hold, nothing
# more. The rule that used to govern that list — "anything the host globs for must NOT appear
# among the installed files, and the way to honour that is to build a clean copy" — was written
# when the bundle was one `bar-widget` and `inotifywait … -e create` made a loose `test_*` an
# event per test binary. tsnake's own kinds are now `overlay` and `bar-widget`, which nothing
# globs for, so that rule does not bite here any more; the clean copy stays because `make`
# leaves ./snake, ./test_hunt and ./test_game in the repo root, and a bundle of loose
# executables is a folder full of copies of code that gets loaded from disk.
# Verified while the old install is still intact: a bad copy must never be the
# reason the working folder is gone.
cmp -s "$SRC/Overlay.qml" "$STAGE/$ENTRY" || fail "staged overlay does not match the repo"
for f in snake BarWidget.qml GlyphLab.qml data/glyphs.json docs/decisions.md docs/protocol.md uninstall.sh omarchy-menu.jsonc; do
  cmp -s "$SRC/$f" "$STAGE/$f" || fail "staged $f does not match the repo"
done

if [[ -d $DEST ]]; then rm -rf "$DEST"; fi
mv "$STAGE" "$DEST"

for f in snake BarWidget.qml GlyphLab.qml data/glyphs.json docs/decisions.md docs/protocol.md; do
  cmp -s "$SRC/$f" "$DEST/$f" || fail "installed $f does not match the repo"
done
cmp -s "$SRC/Overlay.qml" "$DEST/$ENTRY" || fail "installed overlay does not match the repo"

if (( REMOVED )) && [[ $(omarchy-shell shell listPlugins 2>/dev/null |
  jq -r --arg id "$ID" '.[] | select(.id == $id) | .enabled' 2>/dev/null) != "true" ]]; then
  omarchy-plugin-enable "$ID" >/dev/null
fi

omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true

echo "installed $ID -> $DEST"
echo "  overlay entry: $ENTRY"
# The player's files, reported from where they actually live now — outside the watched
# folder, so the engine can write them at any moment without reloading the panel.
# ------------------------------------------------------------- the menu, if we are installed
# ONE FILE FEEDS THE WHOLE MENU, WHICH IS WHY A LIVE FILE IS NEITHER SPLICED NOR REPLACED.
#
# Measured on this machine, citations included:
#   * Menu.qml:51 — `menuData: menuProviders.concat(commandProviders).concat(providerMenu)
#     .concat(providerCommands)`, fed to :382's `Quickshell.spawn.sync("bash", ["-c", …])`.
#     Four concatenated sources into ONE array with ONE parser, and the card shows eight
#     rows at a time (`maxRowsHeight`; `RowNav.focusIndex` scrolls, :1032, :1270-1271).
#   * A single malformed row is a syntax error for the WHOLE array, and Menu.qml:382's
#     fallback for an unparseable file is `echo "{}"` — not "lose the bad row" but "no
#     rows at all", the host's own `remove` and `setup.plugin` menus included (they are
#     provider-driven, :25, :168 — an extensions file that omits them while listing its
#     own rows buries BOTH). Splicing tsnake's 2 rows into somebody's live catalogue
#     risks exactly that, for a shortcut to a snake game.
#   * Quickshell has no `parse-args` subcommand on this machine (it rejects the word
#     outright, exit 109, before looking at any file), so there is NO oracle here for
#     "does this spliced file still parse". Do not write one and do not trust a report
#     that ran one.
#
# So the three answers below are: no live file → WRITE ours; a live file whose non-comment
# content is only braces and whitespace → REPLACE it (that is what this machine's live file
# is — commented-out EXAMPLES, dead text the shell never renders — and the once-per-file
# .orig copy keeps even that); a live file with REAL rows → LEAVE IT ALONE, touch nothing,
# write no receipt. A machine left alone loses nothing: tsnake stays reachable there
# through its bar widget and the host's own `omarchy-menu-plugin remove` picker.
MENU_LIVE="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/extensions"
MENU_FILE="$MENU_LIVE/omarchy-menu.jsonc"
MENU_REPO="$SRC/omarchy-menu.jsonc"
MENU_KIND=""
MENU_TOUCHED=0
if [[ -f $MENU_REPO && -f $DEST/Overlay.qml ]]; then
  [[ -d $MENU_LIVE ]] || mkdir -p "$MENU_LIVE"
  if [[ ! -f $MENU_FILE ]]; then
    # Nothing to merge into. A copy is a copy then, and there is no earlier file to betray.
    cp -p "$MENU_REPO" "$MENU_FILE"
    MENU_KIND="written new (nothing was there to merge into)"
    MENU_TOUCHED=1
  elif cmp -s "$MENU_REPO" "$MENU_FILE"; then
    # Byte-identical to ours — this machine already carries tsnake's rows, from an earlier
    # run of this script or from a hand-copy. Nothing to do; the receipt below still tells
    # uninstall.sh the file is wholly tsnake's, so it may go whole on uninstall.
    MENU_KIND="already exact — this machine already declares tsnake's own rows"
    MENU_TOUCHED=1
  else
    # A live file that is NOT ours. If every non-comment line is braces or whitespace, its
    # "rows" are commented-out EXAMPLES — dead text the shell never renders — so replacing
    # it buries nothing real, and the .orig copy (made once, beside the file) keeps even
    # that. Anything else is somebody's custom menu: LEAVE IT ALONE — no splice, no
    # replace, no receipt (see the WHY block above this if; tsnake stays reachable there
    # through its bar widget and `omarchy-menu-plugin remove`).
    if grep -vE '^[[:space:]]*(//.*)?$' "$MENU_FILE" | grep -qvE '^[[:space:]]*[{}]*[[:space:]]*$'; then
      echo "  menu:          $MENU_FILE — left ALONE (it carries live rows of its own; tsnake's rows were NOT added to it)"
    else
      if [[ ! -e "$MENU_FILE.orig" ]]; then
        cp -p "$MENU_FILE" "$MENU_FILE.orig"
        echo "  menu:          whole file copied to $(basename "$MENU_FILE").orig before touching it"
      fi
      cp -p "$MENU_REPO" "$MENU_FILE"
      MENU_KIND="replaced (its rows were commented-out Examples — dead text the shell never renders)"
      MENU_TOUCHED=1
      echo "  menu:          $MENU_FILE — REPLACED with tsnake's rows (what was there before is beside it as .orig)"
    fi
  fi

  # ---- leave a receipt, so ./uninstall.sh does not have to guess ----------------
  # Written ONLY when this script TOUCHED the live file (or found it byte-identical to
  # ours): written-new and already-exact mean the file is wholly tsnake's and may go
  # whole on uninstall; replaced means the .orig comes back. A file LEFT ALONE gets no
  # receipt — nothing is tsnake's there, and uninstall.sh's no-receipt path compares the
  # file against its own copy and touches nothing when they differ, which is exactly the
  # right answer for somebody else's menu. Why a sibling file and not an edit of the live
  # one: Menu.qml:51 resolves userMenuPath to ONE exact filename, so a file named
  # anything else in that folder is never opened. The .orig name needs no host precedent
  # to be harmless; an earlier draft invented one (a "Menu.qml:1069") and that citation
  # was deleted rather than kept decorative.
  if (( MENU_TOUCHED )); then
    printf '%s\n' "$MENU_KIND" >"$MENU_FILE.tsnake-install"
    if [[ -e "$MENU_FILE.orig" ]]; then echo replaced >>"$MENU_FILE.tsnake-install"; fi
  fi
fi

echo "  state:         $STATE_ROOT"
if [[ -f $STATE_ROOT/highscore ]]; then
  echo "  record:        $(best_in "$STATE_ROOT/highscore")"
fi
if [[ -s $STATE_ROOT/setup ]]; then
  # digits and the space between them, nothing else: this is a file on disk being printed
  echo "  card:          wrap tick_ms = $(tr -dc '0-9 ' <"$STATE_ROOT/setup")"
fi
# Discoverability, so nobody hunts for the record: the host's remover cannot reach this folder,
# so erasing it is ./uninstall.sh's job.
echo "  removal:       ./uninstall.sh takes the plugin AND this folder (plugin remove alone cannot)"
echo "then:  omarchy-shell shell summon $ID"
# The one failure this script cannot fix from the outside: a shell process whose plugin
# type/directory index was poisoned by folder churn answers summon with "ok" and loads
# nothing — the log says `File name case mismatch` against a file that plainly exists — and no
# rescan clears it. Only a restart does. That is also why every real install here takes the
# removal path rather than writing over a live item.
echo "  if that prints ok and no window appears: /usr/share/omarchy/bin/omarchy-restart-shell"
