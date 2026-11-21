#!/usr/bin/env bash
# package.sh — make the release archive. It never publishes, tags or installs anything.
#
#   scripts/package.sh                 Developer ID build (build.sh --release), notarized by Apple and stapled
#   scripts/package.sh --self-signed   local build (build.sh): your local identity or ad-hoc, NOT notarized
#   scripts/package.sh --allow-dirty   package although tracked files differ from HEAD (not for a real release)
#
# Output:
#   dist/Headroom-<version>-macos-arm64.zip           the archive
#   dist/Headroom-<version>-macos-arm64.zip.sha256    its checksum, in `shasum -a 256 -c` form
#   dist/Headroom-macos-arm64.zip                     the same archive under a name without the version. Attached to
#                                                     every release, it gives one link that always serves the newest:
#                                                     github.com/agenttools/headroom/releases/latest/download/Headroom-macos-arm64.zip
#
# The archive holds one folder, Headroom-<version>/:
#   Headroom.app      the signed app (with the notarization ticket stapled, unless --self-signed)
#   scripts/          install.sh, uninstall.sh and their helpers, the same files as in the repository
#   INSTALL.txt       how to install, and what this build is (version, commit, signature)
#   LICENSE
# install.sh finds the Headroom.app next to scripts/, so the steps are the same as from source.
#
# The version is `HeadroomEnv.version` in Sources/HeadroomContracts/Env.swift. The archive is made from a clean
# tree, so that it matches the commit named in INSTALL.txt.
#
# Notarization, once per Mac:
#   1. A "Developer ID Application" certificate in your keychain
#      (Xcode ▸ Settings ▸ Accounts ▸ your team ▸ Manage Certificates ▸ + ▸ Developer ID Application).
#   2. Credentials for Apple's notary service, stored in your keychain under a profile name:
#        xcrun notarytool store-credentials headroom-notary --apple-id <you> --team-id <TEAMID>
#      It asks for an app-specific password (appleid.apple.com ▸ Sign-In and Security ▸ App-Specific Passwords).
#
# Environment:
#   NOTARY_PROFILE           the notarytool keychain profile (default headroom-notary)
#   SIGN_ID, SIGN_KEYCHAIN   passed to build.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

NOTARIZE=1; ALLOW_DIRTY=0
for a in "$@"; do
  case "$a" in
    --self-signed) NOTARIZE=0 ;;
    --allow-dirty) ALLOW_DIRTY=1 ;;
    -h|--help) sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 1 ;;
  esac
done
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# --- Checks before building ---------------------------------------------------------------------
VERSION="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/HeadroomContracts/Env.swift)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "no x.y.z version in Sources/HeadroomContracts/Env.swift (found \"$VERSION\")"
COMMIT="$(git rev-parse --short=12 HEAD)"
DIRTY=""
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  [[ $ALLOW_DIRTY == 1 ]] || die "tracked files differ from HEAD. Commit first, or pass --allow-dirty for a trial archive."
  DIRTY=" + uncommitted changes"
fi

PROFILE="${NOTARY_PROFILE:-headroom-notary}"
if [[ $NOTARIZE == 1 ]]; then
  # Fail before the build when the notary credentials are missing or wrong. (build.sh --release checks the certificate.)
  xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
    || die "notarytool has no working keychain profile \"$PROFILE\". See the header of this script (or pass --self-signed)."
fi

NAME="Headroom-$VERSION"
ARCHIVE="$ROOT/dist/$NAME-macos-arm64.zip"
STABLE="$ROOT/dist/Headroom-macos-arm64.zip"
APP="$ROOT/build/Headroom.app"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# --- 1. Build and sign ----------------------------------------------------------------------------
if [[ $NOTARIZE == 1 ]]; then scripts/build.sh --release; else scripts/build.sh; fi
BUILT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$BUILT" == "$VERSION" ]] || die "build/Headroom.app is version $BUILT, expected $VERSION"
SIGNER="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"

# --- 2. Notarize and staple -----------------------------------------------------------------------
if [[ $NOTARIZE == 1 ]]; then
  echo "submitting to Apple's notary service (profile $PROFILE); this usually takes a few minutes…"
  ditto -c -k --keepParent "$APP" "$WORK/notarize.zip"
  xcrun notarytool submit "$WORK/notarize.zip" --keychain-profile "$PROFILE" --wait --output-format json \
    >"$WORK/notary.json" || { cat "$WORK/notary.json" >&2; die "notarytool submit failed"; }
  STATUS="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status",""))' "$WORK/notary.json")"
  if [[ "$STATUS" != "Accepted" ]]; then
    ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' "$WORK/notary.json")"
    [[ -z "$ID" ]] || xcrun notarytool log "$ID" --keychain-profile "$PROFILE" >&2 || true
    die "Apple did not accept the build (status \"$STATUS\"); its log is above"
  fi
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute -vv "$APP" 2>&1 | sed 's/^/  gatekeeper: /'
  spctl --assess --type execute "$APP" || die "Gatekeeper does not accept the stapled app"
  KIND="signed with a Developer ID ($SIGNER) and notarized by Apple"
else
  echo "warning: --self-signed: this archive is NOT notarized. macOS refuses to open a downloaded copy until its" >&2
  echo "         quarantine mark is removed (install.sh offers to do that)." >&2
  if [[ -n "$SIGNER" ]]; then KIND="signed with a self-signed certificate ($SIGNER), not notarized by Apple"
  else KIND="ad-hoc signed, not notarized by Apple (macOS asks for the Automation permissions again after each update)"; fi
fi

# --- 3. Assemble ----------------------------------------------------------------------------------
STAGE="$WORK/$NAME"
mkdir -p "$STAGE/scripts"
ditto "$APP" "$STAGE/Headroom.app"
for f in install.sh uninstall.sh _common.sh dock-tile.py extension-id.sh; do
  cp -p "scripts/$f" "$STAGE/scripts/$f"
done
cp -p LICENSE "$STAGE/LICENSE"
cat >"$STAGE/INSTALL.txt" <<EOF
Headroom $VERSION (commit $COMMIT$DIRTY)
For Apple Silicon Macs with macOS 15 or later.

Install, from this folder, in Terminal:

    scripts/install.sh          asks before each step; add --dock to pin Headroom in the Dock

It copies Headroom.app to ~/Applications, sets up the Chrome helper files and links the
\`headroom\` command into ~/bin. Then open Headroom from ~/Applications.

Uninstall:

    scripts/uninstall.sh

This build is $KIND.

Everything else (the Chrome helper extension, permissions, keys, the CLI, troubleshooting):
https://github.com/agenttools/headroom#readme
EOF

# --- 4. Archive, then check the archive itself ----------------------------------------------------
mkdir -p "$ROOT/dist"
rm -f "$ARCHIVE" "$ARCHIVE.sha256" "$STABLE"
# No extended attributes or resource forks: nothing in the folder needs them (the notarization ticket is a file
# inside the app), and without them `unzip` gives the same folder as Finder, with no "._" files.
ditto -c -k --norsrc --noextattr --noacl --keepParent "$STAGE" "$ARCHIVE"
ditto -x -k "$ARCHIVE" "$WORK/check"
CHECK="$WORK/check/$NAME"
codesign --verify --deep --strict "$CHECK/Headroom.app" || die "the app in the archive fails codesign --verify"
[[ $NOTARIZE == 0 ]] || xcrun stapler validate "$CHECK/Headroom.app" >/dev/null || die "the app in the archive lost its notarization ticket"
for f in install.sh uninstall.sh dock-tile.py extension-id.sh; do
  [[ -x "$CHECK/scripts/$f" ]] || die "scripts/$f in the archive is not executable"
done
(cd "$ROOT/dist" && shasum -a 256 "$(basename "$ARCHIVE")" >"$(basename "$ARCHIVE").sha256")
cp -p "$ARCHIVE" "$STABLE"

echo
echo "packaged $ARCHIVE"
echo "  and as:   $STABLE (the same file)"
echo "  version:  $VERSION (commit $COMMIT$DIRTY)"
echo "  build:    $KIND"
echo "  size:     $(du -h "$ARCHIVE" | awk '{print $1}')"
echo "  sha256:   $(awk '{print $1}' "$ARCHIVE.sha256")"
echo "Nothing was published. To release: tag v$VERSION, push the tag, then attach the three files in dist/ to the GitHub release."
