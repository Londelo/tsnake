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
# Why the entry point is copied to a CONTENT-HASHED name (Overlay-<hash>.qml)
# rather than staying Overlay.qml: Quickshell keeps the panel's Loader alive
# (shell.qml:1330 "holds onto the instance") and Qt caches a compiled component
# by URL, clearing that cache ONLY inside finishPluginReload (shell.qml:1472),
# which reloadPlugins (shell.qml:1452) skips entirely whenever
# pluginReloading || pluginRegistry.scanning — and the plugin folder is itself
# watched (services/PluginRegistry.qml:663), so an install's own writes are the
# busiest possible moment to be asking for that reload. The result, measured
# here: six installs, and the shell kept launching the pre-persistence QML.
# A new URL per content is the one lever fully in our own hands — a cached
# component can only ever answer for a URL it was asked about before.
#
# --fresh goes through the removal path because that is the one path proven to
# unload the live item (omarchy-plugin-remove calls setPluginEnabled false and
# rescanPlugins at a quiet moment, and says so: "was unloaded from omarchy-shell").
# The record and the card's settings live INSIDE the plugin folder, so --fresh
# parks them in a temp dir and restores them: a reinstall must never be able to
# lose the high score.

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

# The entry-point name is the cache key. Hash the bytes so identical content
# keeps the same URL (no needless reload) and any edit gets a brand-new one.
#
# The separator is NO separator: Qt derives a component's type name from the file's
# base name, and a QML identifier is [A-Za-z0-9_$] only. `Overlay-<hash>.qml` was
# measured failing to instantiate — `WARN scene: … File name case mismatch` then
# `QQmlVMEMetaObject: Internal error - attempted to evaluate a function in an
# invalid context` — which the host reports through its own broken panel
# onLoadFailed path (shell.qml:1357 references an undefined `errorString`), so no
# window appeared and the bar button looked dead. Not one .qml under
# /usr/share/omarchy/shell has anything but letters, digits and dots in its name;
# the hashed name stays inside that shape so the file name can never be the reason
# a load fails.
STAMP="$(printf '%s' "$(sha256sum "$SRC/Overlay.qml" | cut -c1-12)" | tr -dc '[:alnum:]')"
ENTRY="Overlay${STAMP}.qml"

# The record and the card's settings are the user's, not the build's: carry them
# across the swap so neither a reinstall nor a --fresh can cost anyone a high score.
SAVED=""
if [[ -d $DEST ]]; then
  SAVED="$(mktemp -d)"
  for f in highscore setup; do
    if [[ -f $DEST/$f ]]; then cp -p "$DEST/$f" "$SAVED/$f"; fi
  done
fi
STAGE=""
cleanup_saved() {
  if [[ -n $SAVED && -d $SAVED ]]; then rm -rf "$SAVED"; fi
  if [[ -n $STAGE && -d $STAGE ]]; then rm -rf "$STAGE"; fi
}
trap cleanup_saved EXIT

if (( FRESH )); then
  if [[ -d $DEST ]]; then omarchy-plugin-remove "$ID" --yes >/dev/null; fi
fi

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
  for f in BarWidget.qml GlyphLab.qml README.md; do
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

STAGE="$PLUGINS_DIR/.$ID.stage.$$"
rm -rf "$STAGE"
mkdir -m 0755 "$STAGE"
install -m 0755 "$SRC/snake" "$STAGE/snake"
install -m 0644 "$SRC/Overlay.qml" "$STAGE/$ENTRY"
install -m 0644 "$SRC/BarWidget.qml" "$STAGE/BarWidget.qml"
install -m 0644 "$SRC/GlyphLab.qml" "$STAGE/GlyphLab.qml"
install -m 0644 "$SRC/README.md" "$STAGE/README.md"

# The manifest points at this content's URL. Built here, never committed: a plain
# checkout still carries "Overlay.qml" as its entry point.
jq --arg entry "$ENTRY" '.entryPoints.overlay = $entry' "$SRC/manifest.json" \
  >"$STAGE/manifest.json"
chmod 0644 "$STAGE/manifest.json"
jq -e --arg entry "$ENTRY" '.entryPoints.overlay == $entry' "$STAGE/manifest.json" >/dev/null \
  || fail "generated manifest does not point at $ENTRY"

for f in highscore setup; do
  if [[ -n $SAVED && -f $SAVED/$f ]]; then install -m 0600 "$SAVED/$f" "$STAGE/$f"; fi
done

# Verified while the old install is still intact: a bad copy must never be the
# reason the working folder is gone.
cmp -s "$SRC/Overlay.qml" "$STAGE/$ENTRY" || fail "staged overlay does not match the repo"
for f in snake BarWidget.qml GlyphLab.qml README.md; do
  cmp -s "$SRC/$f" "$STAGE/$f" || fail "staged $f does not match the repo"
done

if [[ -d $DEST ]]; then rm -rf "$DEST"; fi
mv "$STAGE" "$DEST"

for f in snake BarWidget.qml GlyphLab.qml README.md; do
  cmp -s "$SRC/$f" "$DEST/$f" || fail "installed $f does not match the repo"
done
cmp -s "$SRC/Overlay.qml" "$DEST/$ENTRY" || fail "installed overlay does not match the repo"

if (( FRESH )) && [[ $(omarchy-shell shell listPlugins 2>/dev/null |
  jq -r --arg id "$ID" '.[] | select(.id == $id) | .enabled' 2>/dev/null) != "true" ]]; then
  omarchy-plugin-enable "$ID" >/dev/null
fi

omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true

echo "installed $ID -> $DEST"
echo "  overlay entry: $ENTRY"
if [[ -f $DEST/highscore ]]; then
  echo "  record kept:   $(tr -d '\n' <"$DEST/highscore")"
fi
echo "then:  omarchy-shell shell summon $ID"
