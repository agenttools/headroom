#!/usr/bin/env bash
# build.sh — compile, assemble and sign build/Headroom.app (SPEC §8.2). It never installs anything.
#
#   scripts/build.sh            release build -> build/Headroom.app
#   scripts/build.sh --run      ...then open it (passes HEADROOM_DRY_RUN through if you set it)
#   scripts/build.sh --mock     ...then open it with the fixture world: HEADROOM_MOCK=1 HEADROOM_DRY_RUN=1
#
# Bundle layout:
#   Contents/MacOS/Headroom                 the app (SwiftPM product HeadroomApp)
#   Contents/Helpers/headroom-host          Chrome native-messaging host
#   Contents/Helpers/headroom               the CLI (install.sh symlinks ~/bin/headroom to it)
#   Contents/Resources/AppIcon.icns         drawn by scripts/mkicon.swift (cached in .build/icon/)
#   Contents/Resources/ChromeExtension/     copy of Extension/ (install.sh copies it to a stable folder)
#   Contents/Info.plist                     HeadroomExtensionID = id computed from the manifest's "key"
#
# Environment:
#   SIGN_ID        identity name or SHA-1. Default: "Headroom Local Signing" if the keychain has it, else ad-hoc.
#   SIGN_KEYCHAIN  keychain to search for the identity (default: the normal search list).
#   SCRATCH        SwiftPM scratch path (default .build/bundle).
#   OUT            output folder (default build).
#   BIN_DIR        skip compiling and package the HeadroomApp/headroom/headroom-host binaries in this folder.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

RUN=0; MOCK=0
for a in "$@"; do
  case "$a" in
    --run) RUN=1 ;;
    --mock) MOCK=1 ;;
    -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 1 ;;
  esac
done

SCRATCH="${SCRATCH:-.build/bundle}"
OUT="${OUT:-build}"
[[ "$OUT" == /* ]] || OUT="$ROOT/$OUT"
APP="$OUT/Headroom.app"

# 1. Compile (release, arm64; Swift 6 language mode is set by the package).
if [[ -n "${BIN_DIR:-}" ]]; then
  BIN="$BIN_DIR"   # packaging-only run with binaries built elsewhere
  echo "using prebuilt binaries from $BIN"
else
  for product in HeadroomApp headroom headroom-host; do
    swift build -c release --arch arm64 --scratch-path "$SCRATCH" --product "$product"
  done
  BIN="$(swift build -c release --arch arm64 --scratch-path "$SCRATCH" --show-bin-path)"
fi
for f in HeadroomApp headroom headroom-host; do
  [[ -x "$BIN/$f" ]] || { echo "missing binary: $BIN/$f" >&2; exit 1; }
done

# 2. Icon (re-drawn only when mkicon.swift changes).
ICON_CACHE=".build/icon/AppIcon.icns"
if [[ ! -f "$ICON_CACHE" || scripts/mkicon.swift -nt "$ICON_CACHE" ]]; then
  mkdir -p "$(dirname "$ICON_CACHE")"
  swift scripts/mkicon.swift "$ICON_CACHE" >/dev/null
fi

# 3. Assemble.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/HeadroomApp" "$APP/Contents/MacOS/Headroom"
cp "$BIN/headroom-host" "$APP/Contents/Helpers/headroom-host"
cp "$BIN/headroom" "$APP/Contents/Helpers/headroom"
cp "$ICON_CACHE" "$APP/Contents/Resources/AppIcon.icns"

EXT_ID=""
if [[ -f Extension/manifest.json ]]; then
  # Everything Chrome needs; docs and dotfiles stay out of the bundle.
  rsync -a --exclude '.*' --exclude '*.md' Extension/ "$APP/Contents/Resources/ChromeExtension/"
  EXT_ID="$(scripts/extension-id.sh Extension/manifest.json)" || EXT_ID=""
  [[ -n "$EXT_ID" ]] || echo "warning: Extension/manifest.json has no \"key\"; the extension id is not fixed." >&2
else
  echo "warning: Extension/manifest.json not found; the bundle has no ChromeExtension folder." >&2
fi

# 4. Info.plist. No LSUIElement: Headroom is a normal Dock app.
VERSION="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/HeadroomContracts/Env.swift)"
BUILD_NUM="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
PL="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy \
  -c "Add :CFBundleName string Headroom" \
  -c "Add :CFBundleDisplayName string Headroom" \
  -c "Add :CFBundleIdentifier string dev.adder.headroom" \
  -c "Add :CFBundleExecutable string Headroom" \
  -c "Add :CFBundleIconFile string AppIcon" \
  -c "Add :CFBundlePackageType string APPL" \
  -c "Add :CFBundleInfoDictionaryVersion string 6.0" \
  -c "Add :CFBundleShortVersionString string ${VERSION:-0.1.0}" \
  -c "Add :CFBundleVersion string ${BUILD_NUM}" \
  -c "Add :LSMinimumSystemVersion string 15.0" \
  -c "Add :LSApplicationCategoryType string public.app-category.utilities" \
  -c "Add :NSHighResolutionCapable bool true" \
  -c "Add :NSPrincipalClass string NSApplication" \
  -c "Add :NSAppleEventsUsageDescription string 'Headroom lists and closes Chrome tabs when its helper extension isn\\'t set up, and brings the right Ghostty window forward when you jump to a Claude session.'" \
  "$PL" >/dev/null
if [[ -n "$EXT_ID" ]]; then
  /usr/libexec/PlistBuddy -c "Add :HeadroomExtensionID string $EXT_ID" "$PL" >/dev/null
fi
plutil -lint -s "$PL"

# 5. Sign: helpers first, then the app. No hardened runtime, no sandbox, no timestamp.
KC=()
[[ -n "${SIGN_KEYCHAIN:-}" ]] && KC=(--keychain "$SIGN_KEYCHAIN")
SIGN="${SIGN_ID:-}"
if [[ -z "$SIGN" ]]; then
  # No -v: a self-signed certificate is "not trusted" as a root, but codesign signs with it fine.
  # Use the SHA-1 so that two identities with the same name cannot make codesign fail as ambiguous.
  SIGN="$(security find-identity -p codesigning ${SIGN_KEYCHAIN:+"$SIGN_KEYCHAIN"} 2>/dev/null \
          | awk '/"Headroom Local Signing"/ { print $2; exit }')"
  if [[ -z "$SIGN" ]]; then
    SIGN="-"
    echo "Ad-hoc signed: macOS will ask for Chrome/Ghostty permission again after each rebuild. Run scripts/make-signing-cert.sh once." >&2
  fi
fi
sign() { # hides codesign's "replacing existing signature" note (the linker ad-hoc signs every binary)
  codesign --force --sign "$SIGN" ${KC[@]+"${KC[@]}"} --timestamp=none "$@" 2>&1 | { grep -v 'replacing existing signature' || true; } >&2
  return "${PIPESTATUS[0]}"
}
sign --identifier dev.adder.headroom.host "$APP/Contents/Helpers/headroom-host"
sign --identifier dev.adder.headroom.cli "$APP/Contents/Helpers/headroom"
sign "$APP"
codesign --verify --deep --strict "$APP"

echo "built $APP"
echo "  signed with:  $([[ "$SIGN" == "-" ]] && echo ad-hoc || echo "$SIGN")"
echo "  requirement:  $(codesign -d -r- "$APP" 2>&1 | sed -n 's/^#* *designated => //p')"
echo "  extension id: ${EXT_ID:-none}"

# 6. Launch.
if [[ $MOCK == 1 ]]; then
  echo "opening with HEADROOM_MOCK=1 HEADROOM_DRY_RUN=1"
  open -n --env HEADROOM_MOCK=1 --env HEADROOM_DRY_RUN=1 "$APP"
elif [[ $RUN == 1 ]]; then
  if [[ -n "${HEADROOM_DRY_RUN:-}" ]]; then
    echo "opening with HEADROOM_DRY_RUN=$HEADROOM_DRY_RUN"
    open -n --env "HEADROOM_DRY_RUN=$HEADROOM_DRY_RUN" "$APP"
  else
    echo "opening (live: closes are real)"
    open -n "$APP"
  fi
fi
