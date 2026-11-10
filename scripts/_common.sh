# _common.sh — shared helpers for install.sh and uninstall.sh. Sourced, not run.
# shellcheck shell=bash disable=SC2034  # the variables are used by the scripts that source this

HEADROOM_BUNDLE_ID="dev.adder.headroom"
HEADROOM_HOST_NAME="dev.adder.headroom"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"

# Every path below is derived from $HOME, so `HOME=<scratch> scripts/install.sh` touches only <scratch>.
INSTALL_APP="$HOME/Applications/Headroom.app"
SUPPORT_DIR="$HOME/Library/Application Support/Headroom"
EXT_DEST="$SUPPORT_DIR/ChromeExtension"
CHROME_DIR="$HOME/Library/Application Support/Google/Chrome"
CLI_LINK="$HOME/bin/headroom"

REAL_HOME="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
[[ -n "$REAL_HOME" ]] || REAL_HOME="$(eval echo "~$(id -un)")"
home_is_real() { [[ "$(cd "$HOME" && pwd -P)" == "$(cd "$REAL_HOME" && pwd -P)" ]]; }

ASSUME_YES=0
say()  { printf '%s\n' "$*"; }
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# ask "question" -> 0 for yes. Enter means yes. --yes answers yes to everything.
ask() {
  if [[ $ASSUME_YES == 1 ]]; then say "$1 [Y/n] y (--yes)"; return 0; fi
  [[ -t 0 ]] || die "stdin is not a terminal; re-run with --yes to accept every step"
  local a; read -r -p "$1 [Y/n] " a
  [[ -z "$a" || "$a" == [yY]* ]]
}

# Refuse to write anywhere outside $HOME (protects scratch-HOME tests from inherited env such as
# XDG_CONFIG_HOME pointing at the real home).
inside_home() {
  local p="$1"
  case "$p" in "$HOME"/*) return 0 ;; esac
  warn "skipping $p: it is outside HOME ($HOME)"; return 1
}

# Pretty path for messages.
tilde() { local p="$1" t='~'; printf '%s' "${p/#"$HOME"/$t}"; }   # $t: a literal ~ would be expanded

headroom_running_from() { # $1 = app path; prints pids of a running Headroom from that bundle
  pgrep -f "$1/Contents/MacOS/Headroom" 2>/dev/null || true
}

# --- Dock -------------------------------------------------------------------------------------
# DOCK_PLIST=<file> makes every Dock step work on that file only (tests). Without it, the live Dock
# is exported with `defaults`, edited as a file and imported back, then Dock restarts. Because
# `defaults` always talks to the logged-in user's real preferences (not $HOME), a live edit is only
# allowed when HOME is the real home.
dock_source() { # prints a path to a readable copy of the Dock plist
  local tmp="$1"
  if [[ -n "${DOCK_PLIST:-}" ]]; then
    [[ -f "$DOCK_PLIST" ]] || die "DOCK_PLIST=$DOCK_PLIST does not exist"
    cp "$DOCK_PLIST" "$tmp"
  else
    home_is_real || die "refusing to edit the live Dock while HOME=$HOME is not your real home; set DOCK_PLIST=<copy> for tests"
    defaults export com.apple.dock "$tmp"
  fi
}

dock_backup() { # $1 = source copy, $2 = label (install | pre-uninstall | pre-restore); prints backup path
  # Labelled so `uninstall.sh --restore-dock` only ever restores an install-time backup.
  mkdir -p "$SUPPORT_DIR"
  local b; b="$SUPPORT_DIR/dock-backup-${2:?dock_backup needs a label}-$(date +%Y%m%d-%H%M%S).plist"
  cp "$1" "$b"
  printf '%s' "$b"
}

dock_apply() { # $1 = edited plist
  if [[ -n "${DOCK_PLIST:-}" ]]; then
    cp "$1" "$DOCK_PLIST"
    say "  updated $DOCK_PLIST (test mode: the real Dock was not touched)"
  else
    defaults import com.apple.dock "$1"
    killall Dock
    say "  Dock restarted"
  fi
}

# --- AeroSpace --------------------------------------------------------------------------------
AEROSPACE_MARK="# Headroom (added by scripts/install.sh)"
aerospace_config() { # prints the config path in use, if any
  local c
  for c in "$HOME/.aerospace.toml" "${XDG_CONFIG_HOME:-$HOME/.config}/aerospace/aerospace.toml"; do
    [[ -f "$c" ]] && { printf '%s' "$c"; return 0; }
  done
  return 1
}
