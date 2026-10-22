#!/bin/bash
# release.sh — build, sign, DMG, (optionally) notarize + staple Go Pray. Owner: lane C.
#
#   scripts/release.sh                 build Release, check signature + guards, make the DMG. Stops BEFORE notarizing.
#   scripts/release.sh --notarize      also submit to Apple, wait, staple, assess. Needs NOTARY_PROFILE.
#
# Env:
#   NOTARY_PROFILE   keychain profile name for `xcrun notarytool` (made once with
#                    `xcrun notarytool store-credentials <name>`). UNKNOWN today. Only read with --notarize.
#   OUT_DIR          where the build and DMG go (default: ./build/release, git-ignored)
#
# Never prints credentials. Notarization is a submit to Apple: it only runs with --notarize.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="Developer ID Application: Ahmed Elgazar (3BB4JMG8GR)"
OUT_DIR="${OUT_DIR:-$here/build/release}"
APP_NAME="Go Pray"
notarize=0
for a in "$@"; do
  case "$a" in
    --notarize) notarize=1 ;;
    *) echo "release: unknown argument $a" >&2; exit 2 ;;
  esac
done

version="$(grep -E '^\s*MARKETING_VERSION:' "$here/project.yml" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
[ -n "$version" ] || { echo "release: cannot read MARKETING_VERSION from project.yml" >&2; exit 1; }
app="$OUT_DIR/Build/Products/Release/$APP_NAME.app"
dmg="$OUT_DIR/GoPray-$version.dmg"

echo "== 1/6 guards (source)"
"$here/scripts/guard.sh" --strict

echo "== 2/6 build Release (signed: $IDENTITY, hardened runtime)"
rm -rf "$OUT_DIR"; mkdir -p "$OUT_DIR"
xcodebuild -project "$here/GoPray.xcodeproj" -scheme GoPray -configuration Release \
  -derivedDataPath "$OUT_DIR" -clonedSourcePackagesDirPath "$OUT_DIR/spm" \
  CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=3BB4JMG8GR \
  OTHER_CODE_SIGN_FLAGS="--timestamp" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  build >"$OUT_DIR/xcodebuild.log" 2>&1 || { tail -30 "$OUT_DIR/xcodebuild.log"; exit 1; }
[ -d "$app" ] || { echo "release: no app at $app" >&2; exit 1; }

echo "== 3/6 verify signature, hardened runtime, launch agent plist, release guard"
codesign --verify --deep --strict --verbose=2 "$app"
codesign -dv --verbose=4 "$app" 2>&1 | grep -E "Authority=Developer ID Application|flags=.*runtime|TeamIdentifier=3BB4JMG8GR" >/dev/null \
  || { echo "release: signature is not Developer ID + hardened runtime + team 3BB4JMG8GR" >&2; exit 1; }
# Apple's notary rejects a debug entitlement (seen 2026-10-22).
if codesign -d --entitlements :- "$app" 2>/dev/null | grep -q "get-task-allow"; then
  echo "release: the app carries com.apple.security.get-task-allow (debug entitlement); notarization would fail" >&2; exit 1
fi
[ -f "$app/Contents/Library/LaunchAgents/com.ahmedelgazar.gopray.agent.plist" ] \
  || { echo "release: launch agent plist is not in the bundle" >&2; exit 1; }
"$here/scripts/guard.sh" --release "$app"

echo "== 4/6 make the DMG"
stage="$(mktemp -d)"; trap 'rm -rf "$stage"' EXIT
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$stage" -ov -format UDZO "$dmg" >/dev/null
codesign --force --timestamp --sign "$IDENTITY" "$dmg"
echo "   $dmg"

if [ "$notarize" -ne 1 ]; then
  echo "== STOP: not notarized. Re-run with --notarize and NOTARY_PROFILE set to submit."
  exit 0
fi

NOTARY_PROFILE="${NOTARY_PROFILE:-se-notarize}"
echo "== 5/6 notarize (submits $dmg to Apple, waits)"
xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait

echo "== 6/6 staple and assess"
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
shasum -a 256 "$dmg"
