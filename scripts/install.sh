#!/usr/bin/env bash
# install.sh — install build/Headroom.app for the current user (SPEC §8.4). Each step asks first.
#
#   scripts/install.sh                 install (asks before each step)
#   scripts/install.sh --dock          ...and add Headroom to the Dock (backs up the Dock first)
#   scripts/install.sh --yes           answer yes to every question (needed without a terminal)
#   scripts/install.sh --app <path>    install another bundle (default: build/Headroom.app, or the Headroom.app
#                                      next to scripts/ in a release package)
#
# What it does, everything under $HOME:
#   1. ~/Applications/Headroom.app                          copy of the built app (ditto; old copy replaced).
#      If the copy carries macOS's quarantine mark (a download) and Gatekeeper would refuse the app (it is not
#      notarized), it offers to remove the mark from the installed copy.
#   2. ~/Library/Application Support/Headroom/ChromeExtension/   stable folder for chrome://extensions ▸ Load unpacked
#   3. ~/Library/Application Support/Google/Chrome/NativeMessagingHosts/dev.adder.headroom.json
#   4. ~/bin/headroom  ->  ~/Applications/Headroom.app/Contents/Helpers/headroom   (the CLI)
#   5. --dock: Dock tile (backup in ~/Library/Application Support/Headroom/dock-backup-install-<ts>.plist)
#   6. AeroSpace rule so the Headroom window floats (only if you use AeroSpace and the rule is missing)
#
# Tests: HOME=<scratch> scripts/install.sh --yes --dock with DOCK_PLIST=<copied plist>. With a scratch
# HOME the live Dock is never touched (Dock steps need DOCK_PLIST), and nothing is written outside HOME.
# Undo everything with scripts/uninstall.sh.
set -euo pipefail
# shellcheck source=_common.sh
source "$(dirname "$0")/_common.sh"

DOCK=0
# A source checkout builds the app into build/. A release package (scripts/package.sh) has it next to scripts/.
APP_SRC="$REPO_DIR/build/Headroom.app"
[[ -d "$APP_SRC" || ! -d "$REPO_DIR/Headroom.app" ]] || APP_SRC="$REPO_DIR/Headroom.app"
# shellcheck disable=SC2034  # ASSUME_YES is read by ask() in _common.sh
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dock) DOCK=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --app) APP_SRC="${2:?--app needs a path}"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

# --- Checks before touching anything ------------------------------------------------------------
[[ -d "$APP_SRC" ]] || die "no app at $APP_SRC. Build it first (scripts/build.sh), or name one with --app <path>"
APP_SRC="$(cd "$APP_SRC" && pwd -P)"
[[ -x "$APP_SRC/Contents/MacOS/Headroom" ]] || die "$APP_SRC is not a Headroom build (no Contents/MacOS/Headroom)"
[[ -x "$APP_SRC/Contents/Helpers/headroom-host" ]] || die "$APP_SRC has no Contents/Helpers/headroom-host"
codesign --verify --deep --strict "$APP_SRC" 2>/dev/null || die "$APP_SRC fails codesign --verify; rebuild it with scripts/build.sh"
[[ "$APP_SRC" != "$(cd "$(dirname "$INSTALL_APP")" 2>/dev/null && pwd -P)/Headroom.app" ]] \
  || die "$APP_SRC is already the installed copy"

EXT_ID="$(/usr/libexec/PlistBuddy -c 'Print :HeadroomExtensionID' "$APP_SRC/Contents/Info.plist" 2>/dev/null || true)"
EXT_SRC="$APP_SRC/Contents/Resources/ChromeExtension"
if [[ -z "$EXT_ID" && -f "$EXT_SRC/manifest.json" ]]; then
  EXT_ID="$("$SCRIPTS_DIR/extension-id.sh" "$EXT_SRC/manifest.json" 2>/dev/null || true)"
fi

SIGNER="$(codesign -dvv "$APP_SRC" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
say "Installing Headroom for $(id -un)"
say "  from   $APP_SRC"
say "  signed ${SIGNER:-ad-hoc}"
[[ -n "$SIGNER" ]] || say "         (ad-hoc: macOS asks for Chrome/Ghostty permission again after each rebuild; see scripts/make-signing-cert.sh)"
say "  HOME   $HOME$(home_is_real || printf '   (scratch HOME: a test install)')"

running="$(headroom_running_from "$INSTALL_APP")"
if [[ -n "$running" ]]; then
  warn "Headroom is running from $(tilde "$INSTALL_APP") (pid $running)."
  ask "Replace it anyway? It keeps running the old version until you quit it." || die "quit Headroom (⌘Q), then run this again"
fi

# --- 1. The app ---------------------------------------------------------------------------------
step "1. Copy the app to $(tilde "$INSTALL_APP")"
if ask "Copy Headroom.app$( [[ -e "$INSTALL_APP" ]] && printf ' (replaces the installed copy)')?"; then
  mkdir -p "$(dirname "$INSTALL_APP")"
  # Copy to a new name, then swap. The old files are unlinked, not overwritten, so a headroom-host that
  # Chrome is still running keeps its (valid) code pages until Chrome restarts it.
  NEW="$INSTALL_APP.installing"
  rm -rf "$NEW"
  ditto "$APP_SRC" "$NEW"
  rm -rf "$INSTALL_APP"
  mv "$NEW" "$INSTALL_APP"
  codesign --verify --deep --strict "$INSTALL_APP" || die "the installed copy fails codesign --verify"
  say "  installed $(tilde "$INSTALL_APP")"
  # A copy that came through a browser carries macOS's quarantine mark, and ditto copies the mark. A notarized
  # build opens anyway (spctl accepts it). One that is not notarized is refused: the app, the CLI and the Chrome
  # helper would not start. Only then is the mark a problem, and only the installed copy is changed.
  if xattr -p com.apple.quarantine "$INSTALL_APP" >/dev/null 2>&1 \
     && ! spctl --assess --type execute "$INSTALL_APP" >/dev/null 2>&1; then
    say "  macOS marked this copy as downloaded (quarantine), and this build is not notarized by Apple."
    say "  With the mark, macOS refuses to open the app, the headroom command and the Chrome helper."
    if ask "Remove the quarantine mark from $(tilde "$INSTALL_APP") (this app only)?"; then
      xattr -dr com.apple.quarantine "$INSTALL_APP"
      say "  removed"
    else
      say "  kept. Later: xattr -dr com.apple.quarantine \"$INSTALL_APP\""
    fi
  fi
else
  say "  skipped"
fi
[[ -d "$INSTALL_APP" ]] || die "Headroom.app is not installed; the remaining steps need it"

# --- 2. Extension folder ------------------------------------------------------------------------
step "2. Chrome helper extension folder"
if [[ ! -f "$EXT_SRC/manifest.json" ]]; then
  warn "the build has no Contents/Resources/ChromeExtension; skipping (per-tab memory needs it)"
elif ask "Copy the extension to $(tilde "$EXT_DEST")?"; then
  mkdir -p "$EXT_DEST"
  # --delete keeps the folder identical to the build; Chrome reads it in place (reload it after an update).
  rsync -a --delete "$EXT_SRC/" "$EXT_DEST/"
  say "  copied (extension id ${EXT_ID:-unknown})"
else
  say "  skipped"
fi

# --- 3. Native messaging host manifest ----------------------------------------------------------
step "3. Chrome native-messaging bridge file"
HOST_JSON="$CHROME_DIR/NativeMessagingHosts/$HEADROOM_HOST_NAME.json"
if [[ -z "$EXT_ID" ]]; then
  warn "no extension id (Extension/manifest.json has no \"key\"); skipping the bridge file"
elif ask "Write $(tilde "$HOST_JSON")?"; then
  [[ -d "$CHROME_DIR" ]] || say "  note: $(tilde "$CHROME_DIR") does not exist yet (Chrome never ran for this user); creating it"
  mkdir -p "$(dirname "$HOST_JSON")"
  HOST_PATH="$INSTALL_APP/Contents/Helpers/headroom-host" EXT_ID="$EXT_ID" NAME="$HEADROOM_HOST_NAME" \
    python3 - "$HOST_JSON" <<'PY'
import json, os, sys
m = {
    "name": os.environ["NAME"],
    "description": "Headroom tab memory bridge",
    "path": os.environ["HOST_PATH"],
    "type": "stdio",
    "allowed_origins": [f"chrome-extension://{os.environ['EXT_ID']}/"],
}
tmp = sys.argv[1] + ".tmp"
with open(tmp, "w") as f:
    json.dump(m, f, indent=2)
    f.write("\n")
os.replace(tmp, sys.argv[1])
PY
  chmod 644 "$HOST_JSON"
  say "  wrote it (host $(tilde "$INSTALL_APP")/Contents/Helpers/headroom-host, origin chrome-extension://$EXT_ID/)"
else
  say "  skipped. The installed app writes it when you open Set up… on its Chrome card (and repairs it at launch)."
fi

# --- 4. CLI -------------------------------------------------------------------------------------
step "4. The headroom command"
CLI_TARGET="$INSTALL_APP/Contents/Helpers/headroom"
if [[ ! -x "$CLI_TARGET" ]]; then
  warn "the app has no Contents/Helpers/headroom; skipping"
elif [[ -L "$CLI_LINK" && "$(readlink "$CLI_LINK")" == "$CLI_TARGET" ]]; then
  say "  $(tilde "$CLI_LINK") already points at the installed app"
elif ask "Link $(tilde "$CLI_LINK") -> $(tilde "$CLI_TARGET")?"; then
  mkdir -p "$(dirname "$CLI_LINK")"
  if [[ -e "$CLI_LINK" || -L "$CLI_LINK" ]]; then
    if [[ -L "$CLI_LINK" && "$(readlink "$CLI_LINK")" == *"/Headroom.app/Contents/Helpers/headroom" ]]; then
      rm -f "$CLI_LINK"   # an older Headroom link (for example to a build folder)
    else
      b="$CLI_LINK.pre-headroom-$(date +%Y%m%d-%H%M%S)"
      mv "$CLI_LINK" "$b"
      say "  moved the existing $(tilde "$CLI_LINK") to $(tilde "$b")"
    fi
  fi
  ln -s "$CLI_TARGET" "$CLI_LINK"
  say "  linked"
  case ":$PATH:" in
    *":$(dirname "$CLI_LINK"):"*) ;;
    *) home_is_real && say "  note: $(tilde "$(dirname "$CLI_LINK")") is not on your PATH" ;;
  esac
else
  say "  skipped"
fi

# --- 5. Dock ------------------------------------------------------------------------------------
step "5. Dock"
if [[ $DOCK == 1 ]]; then
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  dock_source "$TMP/dock.plist"
  if python3 "$SCRIPTS_DIR/dock-tile.py" has "$TMP/dock.plist" "$INSTALL_APP"; then
    say "  Headroom is already in the Dock"
  elif ask "Add Headroom to the end of the Dock's app list (the Dock restarts)?"; then
    backup="$(dock_backup "$TMP/dock.plist" install)"
    say "  backed up the Dock to $(tilde "$backup")"
    python3 "$SCRIPTS_DIR/dock-tile.py" add "$TMP/dock.plist" "$INSTALL_APP" "$TMP/dock-new.plist"
    dock_apply "$TMP/dock-new.plist"
    say "  added. To undo: scripts/uninstall.sh (or scripts/uninstall.sh --restore-dock)"
  else
    say "  skipped"
  fi
else
  say "  Open Headroom, then right-click its Dock icon ▸ Options ▸ Keep in Dock."
  say "  (Or run this again with --dock.)"
fi

# --- 6. AeroSpace -------------------------------------------------------------------------------
step "6. AeroSpace"
if CONF="$(aerospace_config)"; then
  if grep -q "dev\.adder\.headroom" "$CONF"; then
    say "  $(tilde "$CONF") already has a Headroom rule"
  elif inside_home "$CONF" && ask "Add a rule to $(tilde "$CONF") so the Headroom window floats?"; then
    cp -p "$CONF" "$CONF.pre-headroom-$(date +%Y%m%d-%H%M%S)"
    # The file may be a symlink (dotfiles); >> appends to the file it points at.
    lead=$'\n'; [[ -z "$(tail -c1 "$CONF")" ]] || lead=$'\n\n'   # end the last line, then one blank line
    { printf '%s%s\n' "$lead" "$AEROSPACE_MARK"
      printf '%s\n' "[[on-window-detected]]" "if.app-id = 'dev.adder.headroom'" "run = 'layout floating'"
    } >>"$CONF"
    say "  added (backup next to it). Run: aerospace reload-config"
  else
    say "  skipped"
  fi
else
  say "  no AeroSpace config found; nothing to do"
fi

# --- Next steps ---------------------------------------------------------------------------------
step "Done. Next:"
cat <<EOF
  • Open Headroom from $(tilde "$(dirname "$INSTALL_APP")") (or the Dock). Claude sessions and leftovers work at once.
  • Per-tab Chrome memory (once per Chrome profile):
      chrome://extensions ▸ turn on Developer mode ▸ Load unpacked ▸ ⌘⇧G ▸ paste:
        $EXT_DEST
      The helper's id must be ${EXT_ID:-<unknown>}. Chrome may show a developer-mode notice; that is expected.
  • Without the extension: click [Allow…] on Headroom's Chrome card to grant Automation ▸ Google Chrome.
  • CLI: headroom list · headroom suggest · headroom close <ids…> · headroom undo --last
EOF
