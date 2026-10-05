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
# The separator is an underscore, NOT a dash, and that is load-bearing: Qt derives
# a component's type name from the file's base name, and `-` is not legal in a QML
# identifier. `Overlay-6099905284bf.qml` was measured failing with
# `WARN scene: … File name case mismatch` and then `QQmlVMEMetaObject: Internal
# error - attempted to evaluate a function in an invalid context`, which the host
# reports through its own broken error path (`WARN scene: @shell.qml[1357:-1]:
# ReferenceError: errorString is not defined`) so no window ever appeared and the
# bar button looked dead. Not one .qml under /usr/share/omarchy/shell has a dash
# in its name — a QML file name has to be an identifier.
STAMP="$(printf '%s' "$(sha256sum "$SRC/Overlay.qml" | cut -c1-12)" | tr -dc '[:alnum:]')"
ENTRY="Overlay_${STAMP}.qml"

# The record and the card's settings are the user's, not the build's: carry them
# across the swap so neither a reinstall nor a --fresh can cost anyone a high score.
SAVED=""
if [[ -d $DEST ]]; then
  SAVED="$(mktemp -d)"
  for f in highscore setup; do
    if [[ -f $DEST/$f ]]; then cp -p "$DEST/$f" "$SAVED/$f"; fi
  done
fi
cleanup_saved() {
  if [[ -n $SAVED && -d $SAVED ]]; then rm -rf "$SAVED"; fi
}
trap cleanup_saved EXIT

if (( FRESH )); then
  if [[ -d $DEST ]]; then omarchy-plugin-remove "$ID" --yes >/dev/null; fi
fi

# Every write in here is a `close_write` the shell watches (PluginRegistry.qml:663)
# and each one asks for a full plugin reload, so a file whose bytes already match
# is left strictly alone — an unchanged install should barely touch the folder.
copy_if_changed() {
  local src="$1" dest="$2" mode="$3"
  if [[ -f $dest ]] && cmp -s "$src" "$dest"; then return 0; fi
  install -m "$mode" "$src" "$dest"
}

mkdir -p "$DEST"
chmod 0755 "$DEST"
copy_if_changed "$SRC/snake" "$DEST/snake" 0755
copy_if_changed "$SRC/Overlay.qml" "$DEST/$ENTRY" 0644
copy_if_changed "$SRC/BarWidget.qml" "$DEST/BarWidget.qml" 0644
copy_if_changed "$SRC/GlyphLab.qml" "$DEST/GlyphLab.qml" 0644
copy_if_changed "$SRC/README.md" "$DEST/README.md" 0644

# The manifest points at this content's URL. Built here, never committed: a plain
# checkout still carries "Overlay.qml" as its entry point.
jq --arg entry "$ENTRY" '.entryPoints.overlay = $entry' "$SRC/manifest.json" >"$DEST/manifest.json.tmp"
mv -f "$DEST/manifest.json.tmp" "$DEST/manifest.json"
chmod 0644 "$DEST/manifest.json"

# Old entries would otherwise pile up in the watched folder forever — including
# any dashed one left by the version of this script that thought `-` was legal.
find "$DEST" -maxdepth 1 \( -name 'Overlay_*.qml' -o -name 'Overlay-*.qml' \) \
  ! -name "$ENTRY" -delete

for f in highscore setup; do
  if [[ -n $SAVED && -f $SAVED/$f ]]; then
    install -m 0600 "$SAVED/$f" "$DEST/$f"
  fi
done

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
