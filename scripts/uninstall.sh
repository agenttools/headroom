#!/usr/bin/env bash
# uninstall.sh — undo scripts/install.sh (SPEC §8.4 step 6). Each step asks first.
#
#   scripts/uninstall.sh                   remove the app, bridge file, CLI link, Dock tile, AeroSpace rule
#   scripts/uninstall.sh --restore-dock    put back the whole Dock from the newest install.sh backup
#                                          (dock-backup-install-*.plist) instead of removing just the tile
#   scripts/uninstall.sh --purge           also delete ~/Library/Application Support/Headroom (logs,
#                                          Recently Closed, Dock backups). Without it that folder is kept.
#   scripts/uninstall.sh --yes             answer yes to every question
#
# It only removes things that are recognisably Headroom's: a ~/bin/headroom that is not a link into a
# Headroom.app, or a bridge file that points elsewhere, is left alone. The extension itself lives in
# Chrome's profile: remove it at chrome://extensions (this script cannot and does not touch Chrome).
set -euo pipefail
# shellcheck source=_common.sh
source "$(dirname "$0")/_common.sh"

RESTORE_DOCK=0; PURGE=0
# shellcheck disable=SC2034  # ASSUME_YES is read by ask() in _common.sh
while [[ $# -gt 0 ]]; do
  case "$1" in
    --restore-dock) RESTORE_DOCK=1; shift ;;
    --purge) PURGE=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

say "Uninstalling Headroom for $(id -un)"
say "  HOME   $HOME$(home_is_real || printf '   (scratch HOME: a test uninstall)')"
running="$(headroom_running_from "$INSTALL_APP")"
[[ -z "$running" ]] || die "Headroom is running (pid $running). Quit it (⌘Q), then run this again."

# --- Dock (first, while the app path still exists for matching) ---------------------------------
step "1. Dock"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
dock_available=1
if [[ -z "${DOCK_PLIST:-}" ]] && ! home_is_real; then
  dock_available=0
  say "  skipped: scratch HOME and no DOCK_PLIST (the live Dock is never edited in tests)"
fi
if [[ $dock_available == 1 && $RESTORE_DOCK == 1 ]]; then
  # Only install-time backups: uninstall and restore write their own (pre-uninstall / pre-restore) backups,
  # and restoring one of those would bring back a tile for a deleted app or undo an earlier restore.
  latest="$(ls -1t "$SUPPORT_DIR"/dock-backup-install-*.plist 2>/dev/null | head -1 || true)"
  if [[ -z "$latest" ]]; then
    warn "no install-time Dock backup in $(tilde "$SUPPORT_DIR"); removing only the Headroom tile instead"
    RESTORE_DOCK=0
  elif ask "Restore the whole Dock from $(tilde "$latest")? Changes made to the Dock since then are lost."; then
    dock_source "$TMP/dock.plist"
    safety="$(dock_backup "$TMP/dock.plist" pre-restore)"
    say "  saved the current Dock to $(tilde "$safety") first"
    dock_apply "$latest"
    say "  restored"
  else
    say "  skipped"
  fi
fi
if [[ $dock_available == 1 && $RESTORE_DOCK == 0 ]]; then
  dock_source "$TMP/dock.plist"
  if ! python3 "$SCRIPTS_DIR/dock-tile.py" has "$TMP/dock.plist" "$INSTALL_APP"; then
    say "  Headroom is not in the Dock"
  elif ask "Remove Headroom's Dock tile (the Dock restarts)?"; then
    backup="$(dock_backup "$TMP/dock.plist" pre-uninstall)"
    say "  backed up the Dock to $(tilde "$backup")"
    python3 "$SCRIPTS_DIR/dock-tile.py" remove "$TMP/dock.plist" "$INSTALL_APP" "$TMP/dock-new.plist"
    dock_apply "$TMP/dock-new.plist"
  else
    say "  skipped"
  fi
fi

# --- CLI link -----------------------------------------------------------------------------------
step "2. The headroom command"
if [[ -L "$CLI_LINK" && "$(readlink "$CLI_LINK")" == *"/Headroom.app/Contents/Helpers/headroom" ]]; then
  if ask "Remove the link $(tilde "$CLI_LINK")?"; then
    rm -f "$CLI_LINK"
    say "  removed"
    b="$(ls -1t "$CLI_LINK".pre-headroom-* 2>/dev/null | head -1 || true)"
    [[ -z "$b" ]] || say "  note: install.sh moved an older file to $(tilde "$b"); move it back yourself if you want it"
  else
    say "  skipped"
  fi
elif [[ -e "$CLI_LINK" || -L "$CLI_LINK" ]]; then
  say "  left $(tilde "$CLI_LINK") alone: it is not a link into Headroom.app"
else
  say "  not installed"
fi

# --- Bridge file --------------------------------------------------------------------------------
step "3. Chrome native-messaging bridge file"
HOST_JSON="$CHROME_DIR/NativeMessagingHosts/$HEADROOM_HOST_NAME.json"
if [[ ! -f "$HOST_JSON" ]]; then
  say "  not installed"
elif ! grep -q '/Headroom\.app/Contents/Helpers/headroom-host' "$HOST_JSON"; then
  say "  left $(tilde "$HOST_JSON") alone: it does not point into a Headroom.app"
elif ask "Delete $(tilde "$HOST_JSON")?"; then
  rm -f "$HOST_JSON"
  say "  deleted"
else
  say "  skipped"
fi

# --- App ----------------------------------------------------------------------------------------
step "4. The app"
if [[ ! -d "$INSTALL_APP" ]]; then
  say "  not installed"
elif ask "Delete $(tilde "$INSTALL_APP")?"; then
  # A headroom-host that Chrome is running keeps working from the unlinked file until Chrome stops it.
  rm -rf "$INSTALL_APP" "$INSTALL_APP.installing"
  say "  deleted"
else
  say "  skipped"
fi

# --- Extension folder and data ------------------------------------------------------------------
step "5. Extension folder and Headroom's data"
if [[ $PURGE == 1 && -d "$SUPPORT_DIR" ]]; then
  if ask "Delete $(tilde "$SUPPORT_DIR") (extension folder, actions log, Recently Closed, Dock backups)?"; then
    rm -rf "$SUPPORT_DIR"
    say "  deleted"
  else
    say "  skipped"
  fi
elif [[ -d "$EXT_DEST" ]]; then
  if ask "Delete the extension folder $(tilde "$EXT_DEST")? (Remove the helper at chrome://extensions first.)"; then
    rm -rf "$EXT_DEST"
    say "  deleted. Kept $(tilde "$SUPPORT_DIR") (logs and Dock backups); --purge deletes it."
  else
    say "  skipped"
  fi
else
  say "  nothing to delete"
fi

# --- AeroSpace ----------------------------------------------------------------------------------
step "6. AeroSpace"
if CONF="$(aerospace_config)" && grep -qF "$AEROSPACE_MARK" "$CONF"; then
  if inside_home "$CONF" && ask "Remove the Headroom rule that install.sh added to $(tilde "$CONF")?"; then
    cp -p "$CONF" "$CONF.pre-headroom-uninstall-$(date +%Y%m%d-%H%M%S)"
    # Drop the marker line and the three rule lines after it (exactly what install.sh wrote), plus the
    # blank line install.sh put before the marker.
    python3 - "$CONF" "$AEROSPACE_MARK" <<'PY'
import os, sys
path, mark = sys.argv[1], sys.argv[2]
lines = open(path).read().split("\n")
out, i = [], 0
while i < len(lines):
    if lines[i] == mark and lines[i + 1:i + 4] and "dev.adder.headroom" in "\n".join(lines[i + 1:i + 4]):
        if out and out[-1] == "":
            out.pop()
        i += 4
        continue
    out.append(lines[i])
    i += 1
real = os.path.realpath(path)
with open(real + ".tmp", "w") as f:
    f.write("\n".join(out))
os.replace(real + ".tmp", real)
PY
    say "  removed (backup next to it). Run: aerospace reload-config"
  else
    say "  skipped"
  fi
else
  say "  no rule added by install.sh; nothing to do"
fi

step "Done."
say "  Remove the helper extension yourself at chrome://extensions if you added it."
