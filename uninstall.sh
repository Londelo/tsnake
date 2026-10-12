#!/usr/bin/env bash
# omarchy:summary=Remove tsnake from the Omarchy shell and take its record with it
# omarchy:group=plugin
# omarchy:args=[--keep-state] [--yes]
#
# The removal half of ./install.sh. This is the command that removes tsnake, because it is the
# only one that knows where all of tsnake is:
#
#   omarchy-plugin-remove takes the CODE. It has no idea the record exists — grep the whole of
#   /usr/share/omarchy for a lifecycle hook and there is none (no `uninstall`, no `purge`, no
#   `dataDir`/`stateDir` field a plugin could declare), and the manifest schema has nowhere to
#   name one. So it cannot delete what it cannot be told about; it disables the plugin, and for
#   a plain folder it does not even delete it — it renames it to plugins/.$ID.bak.<timestamp>
#   (lines 106-114) and leaves it in the watched tree. Three of those sat here after my
#   installs, two still holding a stale `highscore: 4`: that is what "state in the plugin
#   folder" actually becomes — not a lifecycle, litter, with the authoritative number living
#   somewhere else entirely.
#
#   This script takes the DATA as well: $XDG_STATE_HOME/tsnake/{highscore,setup}. Deleting the
#   record is a deliberate act, which is exactly the host's own convention — the first-party
#   plugins that keep state put the delete behind their own confirmation, in their own code
#   (clipboard/Clipboard.qml:104 confirmClearHistory ← :416 onConfirmed,
#    notifications/Service.qml:588 clearHistory ← :887) — and the same rule every package
#   manager follows (pacman -R vs -Rns, apt remove vs --purge). Removal of code and deletion
#   of a player's history are two different requests; this script is where both are asked.
#
# Why the state does NOT live in the plugin folder so that `plugin remove` could sweep it
# automatically — two independent reasons, both from the host's own scripts:
#
#   1. The watcher. ~/.config/omarchy/plugins is inotify-watched for
#      close_write,create,delete,move (services/PluginRegistry.qml:663), and the record is
#      written the instant it is beaten. A save in there is a panel reload pulled out from
#      under the player, which is the reason saving was ever deferred and the reason deferring
#      lost every high score. See .claude/CLAUDE.md.
#   2. The update path. omarchy-plugin-update requires a git checkout and runs
#      `merge --ff-only` with a `reset --hard ORIG_HEAD` fallback (:67,:73), and
#      omarchy-plugin-remove `rm -rf`s a git checkout outright (:103) — which is how Omarchy
#      means plugins to be shipped (omarchy-plugin-clone, `clonedFrom`). A record living in the
#      folder therefore dies on a routine update, not just on removal.
#
# 11 of the host's own plugins keep their persistent files under ~/.local/state/omarchy and
# none under their plugin folder (clipboard-history.json, settings/weather.json, toggles/,
# indicators/, agents/usage). notifications/Service.qml:22-24 states the rule for all of them:
# "History + DND live under XDG_STATE_HOME: they're persistent user state ... not regeneratable
# cache that a `rm -rf ~/.cache` should wipe." This script just unwrites what they all do.
#
# It can also be run BY HAND from the dev checkout, and when it is, it unwrites everything
# `./install.sh` wrote — the folder, the two state files, and whatever install.sh did to
# ~/.config/omarchy/extensions/omarchy-menu.jsonc: a file it wrote whole (or found byte-
# identical to its own) goes away, a file it REPLACED comes back from the .orig copy, and a
# live custom menu it was told to leave ALONE is left alone here too. The receipt file
# beside the menu names which, and is the second half of the same pair.
#
# Three things had to be true before this script could delete anything, all measured: that the
# state root is this user's and not `/tsnake`; that the menu file is tsnake's own, byte for
# byte, or that its .orig is intact; and that no answer means no deletion. So a wrong guess
# costs an orphan, never an irreversible edit to something that was never tsnake's.
#
#   --keep-state  remove the plugin, keep the record and the card's settings for a later reinstall
#   --yes         no confirmation (required non-interactively, as the host's own scripts do)
#   -i            plain y/N prompt instead of gum's picker, so nothing in here needs a terminal
#
# Nothing in here may depend on where it was launched from, because `bash -c` does NOT eat the
# `cd` in "cd somedir && ./uninstall.sh": a row whose action is a whole pipeline keeps its own
# cwd and hands the cd to a subshell (a plain `cd x && y` in $() does scope, and that is the
# shell's private business, not menu code worth trusting). So the paths below are absolute.
#
# Nor may anything be found through "$0/.." or "$SCRIPT_DIR", which is why there is no
# SCRIPT_DIR, and why install.sh copies this file rather than symlinking it: coreutils resolves a
# script's symlink against the real file, so `ln -s ~/projects/tsnake/uninstall.sh
# ~/.config/omarchy/plugins/<id>/uninstall.sh` would resolve to this very dev checkout and let
# one edit here silently change what the menu row runs. Absolute + literal, every time.

set -euo pipefail

ID="io.github.londelo.tsnake"
# ---- whose home is this? ---------------------------------------------
# Measured, not assumed: `env -i bash -c 'echo [$HOME]'` prints `[]`. bash backfills PATH,
# SHELL and PWD from its own compiled-in defaults when it is handed an empty environment, but
# it does NOT backfill HOME, and the menu row that launches this script is exactly such a call
# (Quickshell.spawn.sync("bash", ["-c", ...]), Menu.qml:382). So every "$HOME/.config/..." and
# "${XDG_STATE_HOME:-$HOME/.local/state}" below would otherwise expand to
# "/.config/..." and "/.local/state/tsnake" -- and a script whose whole job is deleting is the
# one place on the machine where a silently empty HOME must never be allowed to reach an rm.
# Rebuild it from the passwd database rather than trusting the inherited value: getent is
# libc's own answer, so it cannot be poisoned by a stale exported HOME, and fall back to
# /etc/passwd only if getent is missing. $USER is deliberately not consulted -- under the same
# empty environment it is empty too (measured), and both paths below are absolute either way.
HOME_REAL=""
if [[ -n ${HOME:-} && $HOME != / && -d ${HOME:-} ]]; then
  HOME_REAL="$HOME"
else
  HOME_REAL="$(getent passwd "$UID" 2>/dev/null | cut -d: -f6)"
  [[ -n $HOME_REAL ]] || HOME_REAL="$(awk -F: -v u="$UID" '$3==u {print $6; exit}' /etc/passwd 2>/dev/null)"
  # Only accept what passwd returns if it looks like a real, personal home: passwd's root
  # entry is "/root" and a daemon's may be "/" or empty, and neither may be the root of a delete.
  [[ -n ${HOME_REAL:-} && $HOME_REAL != / ]] || HOME_REAL=""
fi
[[ -n $HOME_REAL ]] || fail "cannot work out whose home to clean: HOME is empty and passwd has nothing for uid $UID"
[[ -d $HOME_REAL && ! -L $HOME_REAL ]] || fail "refusing to treat this as home: $HOME_REAL"
# Exported, because omarchy-plugin-remove and omarchy-shell are separate processes and they
# resolve the same plugin folders from the same environment this script was handed.
export HOME="$HOME_REAL"

PLUGINS_DIR="${TSNAKE_PLUGINS_DIR:-$HOME_REAL/.config/omarchy/plugins}"
MENU_DIR="${XDG_CONFIG_HOME:-$HOME_REAL/.config}/omarchy/extensions"
# The copy install.sh shipped beside the plugin, and the only thing that can prove a menu
# file is tsnake's own. Compared byte for byte, never name-matched: a file whose first line
# merely mentions tsnake is somebody else's file with one tsnake row in it.
MENU_REPO_COPY="${TSNAKE_PLUGINS_DIR:-$HOME_REAL/.config/omarchy/plugins}/io.github.londelo.tsnake/omarchy-menu.jsonc"
# Spelled exactly as Overlay.qml:stateDir spells it and as install.sh spells it. Three writings
# of one path, and they have to agree: find it from the script's own location instead and a
# reinstalled copy would go hunting through the wrong tree while the real record sat untouched.
STATE_ROOT="${XDG_STATE_HOME:-$HOME_REAL/.local/state}"
# A trailing slash here would make every "$STATE_ROOT/$f" below a double slash and the `rmdir`
# below a test against a path that is not the folder's name. Strip it, as Overlay.qml:121 does.
STATE_ROOT="${STATE_ROOT%/}/tsnake"
KEEP_STATE=0
ASSUME_YES=0

fail() { echo "tsnake-uninstall: $*" >&2; exit 1; }

while (( $# > 0 )); do
  case "$1" in
  --keep-state) KEEP_STATE=1; shift ;;
  --yes | -y) ASSUME_YES=1; shift ;;
  -i) FORCE_ASK=1; shift ;;
  -h | --help)
    echo "Usage: ./uninstall.sh [--keep-state] [--yes] [-i]"
    echo "  --keep-state  remove the plugin, keep the record and the card's settings"
    echo "  --yes         do not ask"
    echo "  -i            ask as a plain y/N prompt instead of gum's picker"
    exit 0
    ;;
  *) fail "unknown option: $1" ;;
  esac
done

[[ $ID =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "refusing a plugin id with anything odd in it: $ID"

interactive() { [[ -t 0 && -t 1 ]]; }

# A declined answer must leave a non-zero status behind, and it does: `set -e` makes this
# function's `return 1` fatal, so the script stops dead with nothing deleted. That is the whole
# reason the menu row's `action` cannot be a bare `… --yes || … -i` chain — see omarchy-menu.jsonc.
confirm() {
  (( ASSUME_YES )) && return 0
  if interactive; then
    gum confirm "$1" || return 1
  elif (( FORCE_ASK )); then
    # Measured, and all three of these failed, which is why the prompt is plain `read`:
    # `gum confirm` has no --stdin flag on this machine (it exits 80 on an unknown flag, and its
    # --help lists no way to redirect input — the only input-ish flags are --affirmative and
    # --negative), so gum cannot be fed an answer; Quickshell hands a row's `action` to
    # Quickshell.spawn.sync() as `bash -c` with no pty and no window, and `Process` never
    # consults `mergeEnvironment` (:1033) — so this runs with an EMPTY environment, without even
    # $HOME, and a non-tty stdin. `read` works with or without a terminal, so anything that is
    # not y/yes — including the silent no an unanswered prompt produces — deletes nothing.
    printf 'y/N — %s\n> ' "$1"
    local answer
    # `|| answer=` keeps the failure of an unanswered read (a closed stdin) from tripping
    # `set -e` before the comparison below ever runs, which is the difference between
    # "nothing happened" and "the script died mid-removal".
    read -r answer || answer=""
    case "${answer^^}" in Y | YES) return 0 ;; esac
    echo "left alone: nothing was removed."
    return 1
  else
    fail "refusing to continue without confirmation; pass --yes"
  fi
}

# Mirrors Overlay.qml:stateUsable. An empty or root-ish state root means the env was
# pathological, and a script whose whole job is deleting is the wrong place to guess.
if [[ $STATE_ROOT == "/tsnake" || $STATE_ROOT == "/." || $STATE_ROOT == "/" || $STATE_ROOT != /* ]]; then
  fail "refusing to treat this as the state root: $STATE_ROOT"
fi
# Never follow a link into someone else's tree while deleting.
[[ ! -L $STATE_ROOT ]] || fail "refusing to delete a symlink: $STATE_ROOT"

best_in() {
  if [[ ! -f $1 ]]; then echo "(none)"; return; fi
  local n
  n="$(tr -dc '0-9' <"$1" 2>/dev/null)"
  if [[ -n $n ]]; then echo "$((10#$n))"; else echo "(unreadable)"; fi
}

# ---- what is about to go ----
BEST=""
if (( ! KEEP_STATE )); then
  BEST="$(best_in "$STATE_ROOT/highscore")"
fi

if [[ ! -e "$PLUGINS_DIR/$ID" && ! -L "$PLUGINS_DIR/$ID" ]] &&
  ! ls -d "$PLUGINS_DIR/.$ID.bak."* >/dev/null 2>&1 &&
  [[ ! -d $STATE_ROOT ]]; then
  echo "nothing to remove: no plugin, no backups, no state at $STATE_ROOT"
  exit 0
fi

if (( KEEP_STATE )); then
  confirm "Remove '$ID' and keep the record at $STATE_ROOT?"
else
  confirm "Remove '$ID' AND erase its record (currently $BEST) and card settings? This cannot be undone."
fi

# ---- the code, by the shell's own removal path ----
# Hide first: unloading the panel item under a live engine leaves the child painting a surface
# that no longer exists, and its last frames land on a window Qt is already tearing down.
omarchy-shell shell hide "$ID" >/dev/null 2>&1 || true

if [[ -e "$PLUGINS_DIR/$ID" || -L "$PLUGINS_DIR/$ID" ]]; then
  # The host's script does the parts only it can do: setPluginEnabled false through the shell's
  # IPC, then its own backup-or-delete, then rescanPlugins. Asking IT to remove the plugin (and
  # not rm -rf'ing the folder myself) is what keeps the shell's plugin index honest.
  omarchy-plugin-remove "$ID" --yes || fail "omarchy-plugin-remove failed; nothing deleted"
  echo "removed plugin: $PLUGINS_DIR/$ID"
else
  echo "plugin folder already gone"
fi

# ---- the host's archives of our folder ----
# plugin-remove keeps a backup of a plain (non-git) folder rather than deleting it
# (omarchy-plugin-remove:106-114), and matching on `.$ID.bak.` means this can only ever touch
# backups of THIS plugin. They are copies of code we are on our way to deleting anyway, and a
# stale copy of the record is a lie sitting in the watched tree.
shopt -s nullglob
backups=("$PLUGINS_DIR/.$ID.bak."*)
shopt -u nullglob
if (( ${#backups[@]} > 0 )); then
  for d in "${backups[@]}"; do
    [[ -d $d && ! -L $d ]] || fail "refusing to delete an unexpected backup entry: $d"
    rm -rf -- "$d"
    echo "removed backup:  $d"
  done
fi

# ---- the data, by us ----
# No recursive delete anywhere in this script: the two file names are named exactly, then the
# directory goes only if nothing is left in it (rmdir refuses a non-empty folder). So the
# blast radius of a wrong STATE_ROOT above is two files, never a subtree.
if (( KEEP_STATE )); then
  echo "kept state:      $STATE_ROOT ($(best_in "$STATE_ROOT/highscore") recorded)"
elif [[ -d $STATE_ROOT ]]; then
  for f in highscore setup; do
    [[ -f "$STATE_ROOT/$f" || -L "$STATE_ROOT/$f" ]] || continue
    [[ ! -L "$STATE_ROOT/$f" ]] || fail "refusing to delete a symlink: $STATE_ROOT/$f"
    rm -f -- "$STATE_ROOT/$f"
    echo "erased:          $STATE_ROOT/$f"
  done
  if rmdir "$STATE_ROOT" 2>/dev/null; then
    echo "removed:         $STATE_ROOT"
  else
    # Something that is not ours lives there; say so rather than deleting it recursively.
    echo "left in place:   $STATE_ROOT (not empty, so nothing else was touched)"
  fi
else
  echo "no state to erase at $STATE_ROOT"
fi

# ---- the menu entry, by us ------------------------------------------------
# install.sh either WROTE this file whole, REPLACED a dead Examples-only file behind a
# .orig copy, found it already exact, or left a live custom menu ALONE and wrote no
# receipt. The receipt says which; the live file alone cannot tell you, because a
# replaced file and a left-alone one look identical afterwards -- see the comment
# beside the receipt in install.sh.
#
# This is a restoration, never a rewrite. Nothing here edits the user's menu in place, because
# Menu.qml:382 concatenates this file into one JSON array whose parse failure is answered with
# `echo "{}"` -- not "show the other rows" but "no rows at all", for the whole menu. So the only
# writes are (i) put the untouched .orig back, or (ii) take the whole file away, and both are
# followed by a re-read of what is actually on disk rather than a belief about it.
MENU_RECEIPT="$MENU_FILE.tsnake-install"
if [[ -f $MENU_RECEIPT ]]; then
  if grep -qx replaced "$MENU_RECEIPT" && [[ -f "$MENU_FILE.orig" ]]; then
    # tsnake's install REPLACED the file (its own header called the old rows "Examples"), so the
    # .orig IS the user's file and tsnake's copy is what must go. Back it up from, byte for byte.
    cp -p -- "$MENU_FILE.orig" "$MENU_FILE" && cmp -s -- "$MENU_FILE.orig" "$MENU_FILE" ||
      fail "could not restore $MENU_FILE from its .orig; nothing else was changed"
    echo "restored:        $MENU_FILE from $(basename "$MENU_FILE").orig"
  elif grep -qE '^written new|^already exact' "$MENU_RECEIPT"; then
    # Every row in this file is tsnake's own (install.sh wrote it whole, or found it
    # byte-identical to its own definition), so taking it away deletes nothing of anyone
    # else's. Guarded by a byte-compare anyway, because if the player or another plugin
    # added rows since, the file is no longer tsnake's to delete, and a menu the player
    # hand-edited outranks an uninstall.
    if cmp -s -- "$MENU_REPO_COPY" "$MENU_FILE"; then
      rm -f -- "$MENU_FILE"
      echo "removed:         $MENU_FILE (every row in it was tsnake's own)"
    else
      echo "left in place:   $MENU_FILE (has rows tsnake did not write; drop tsnake's two by hand)"
    fi
  else
    # An unknown receipt — a current install.sh records only the kinds routed above, so
    # this is a fallback, and the fallback for anything unrecognised is TOUCH NOTHING.
    # Deleting or editing lines from a file whose whole menu depends on parsing is the
    # exact way to turn a removal into a menu that opens onto nothing (Menu.qml:382's
    # fallback for an unparseable file is `echo "{}"` — no rows at all, not "the other
    # rows minus one").
    echo "left in place:   $MENU_FILE (its receipt names no change this script can safely undo)"
    if [[ -f "$MENU_FILE.orig" ]]; then
      echo "                 a copy of the file from before tsnake touched it is at $(basename "$MENU_FILE").orig"
    fi
  fi
  rm -f -- "$MENU_RECEIPT"
  [[ -f "$MENU_FILE.orig" ]] && rm -f -- "$MENU_FILE.orig"
elif [[ -f $MENU_FILE && -f $MENU_REPO_COPY ]] && cmp -s -- "$MENU_REPO_COPY" "$MENU_FILE"; then
  # No receipt, and the file is byte-identical to tsnake's own definition: an install from before
  # receipts existed, and one tsnake wrote whole. Same guard as above, same conclusion.
  rm -f -- "$MENU_FILE"
  echo "removed:         $MENU_FILE (identical to tsnake's own definition)"
else
  echo "menu:            nothing of tsnake's to take out of $MENU_FILE"
fi

omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true

echo "tsnake is gone. Relaunch it with ./install.sh, and the card starts fresh: wrap off, 55ms."
