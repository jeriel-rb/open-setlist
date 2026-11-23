#!/usr/bin/env bash
# Builds the Release app and packs it into dist/Setlist.dmg (the app plus a shortcut to Applications).
#
#   scripts/make-dmg.sh            # signed the way the Xcode project signs it: for your own Mac
#   NOTARIZE=1 scripts/make-dmg.sh # Developer ID signed and notarized: opens on anyone's Mac
#
# NOTARIZE=1 goes through the Apple account that is signed in to Xcode (Settings > Accounts), which
# needs the right to make Developer ID certificates. Xcode signs with a certificate it manages and
# uploads the app to Apple's notary service, so no certificate or password has to be set up by hand.
set -euo pipefail
cd "$(dirname "$0")/.."

for tool in yt-dlp ffmpeg fpcalc; do
  [ -x "bin/$tool" ] || { echo "bin/$tool is missing: run scripts/fetch-tools.sh first" >&2; exit 1; }
done

xcodegen generate >/dev/null
BUILD=build-release
ARCHIVE="$BUILD/Setlist.xcarchive"
rm -rf "$ARCHIVE" "$BUILD/export" "$BUILD/notarized"
xcodebuild -project Setlist.xcodeproj -scheme Setlist -configuration Release -derivedDataPath "$BUILD" \
  -archivePath "$ARCHIVE" archive | grep -E "error:|ARCHIVE" || true
APP="$ARCHIVE/Products/Applications/Setlist.app"
[ -d "$APP" ] || { echo "the build did not produce $APP" >&2; exit 1; }

if [ -n "${NOTARIZE:-}" ]; then
  # The bundled tools are programs of their own. Notarization wants each to have the hardened runtime,
  # and Xcode keeps these flags and entitlements when it signs them with the Developer ID. yt-dlp
  # unpacks and loads its own Python libraries, which the hardened runtime only allows with these.
  BIN="$APP/Contents/Resources/bin"
  ENTITLEMENTS="$BUILD/tool.entitlements"
  cat > "$ENTITLEMENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.cs.disable-library-validation</key><true/>
  <key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
  <key>com.apple.security.cs.allow-jit</key><true/>
</dict>
</plist>
PLIST
  codesign --force --sign - --options runtime --entitlements "$ENTITLEMENTS" "$BIN/yt-dlp"
  codesign --force --sign - --options runtime "$BIN/ffmpeg" "$BIN/fpcalc"

  TEAM=$(xcodebuild -project Setlist.xcodeproj -scheme Setlist -configuration Release -showBuildSettings 2>/dev/null \
    | awk '/ DEVELOPMENT_TEAM = /{print $3; exit}')
  [ -n "$TEAM" ] || { echo "no DEVELOPMENT_TEAM: set it in Local.xcconfig" >&2; exit 1; }
  OPTIONS="$BUILD/export-notarize.plist"
  cat > "$OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>destination</key><string>upload</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$TEAM</string>
</dict>
</plist>
PLIST
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$BUILD/export" -exportOptionsPlist "$OPTIONS" \
    -allowProvisioningUpdates 2>&1 | grep -E "error|EXPORT|Uploaded" || true

  echo "waiting for Apple to notarize the app"
  for _ in $(seq 1 40); do
    rm -rf "$BUILD/notarized"
    xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath "$BUILD/notarized" >/dev/null 2>&1 || true
    [ -d "$BUILD/notarized/Setlist.app" ] && break
    sleep 30
  done
  APP="$BUILD/notarized/Setlist.app"
  [ -d "$APP" ] || { echo "notarization did not finish: see Xcode > Window > Organizer" >&2; exit 1; }
fi
codesign --verify --deep --strict "$APP"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp LICENSE "$STAGE/LICENSE.txt"
cp THIRD-PARTY-NOTICES.md "$STAGE/"

mkdir -p dist
DMG="dist/Setlist.dmg"
rm -f "$DMG"
hdiutil create -volname "Setlist $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

echo
echo "$DMG  ($(du -h "$DMG" | cut -f1), version $VERSION)"
spctl --assess --type execute -v "$APP" 2>&1 | sed 's/^/Gatekeeper: /' || true
