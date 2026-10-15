#!/bin/zsh
# Baut Klar.app und installiert sie nach /Applications (Fallback: ~/Applications).
#   ./build.sh            bauen + installieren
#   ./build.sh --open     bauen + installieren + starten
#   ./build.sh --no-install
#   ./build.sh --dist     Release-Archiv build/Klar-<Version>.zip (ad hoc signiert, nicht installieren)
set -e
cd "$(dirname "$0")"

swift build -c release 2>&1 | grep -E "error|warning: unre|Compiling|Build complete" | tail -20

APP=build/Klar.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Klar "$APP/Contents/MacOS/Klar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
echo -n "APPL????" > "$APP/Contents/PkgInfo"

# Signatur: mit lokalem Zertifikat „Klar Dev“ (siehe sign-setup.sh) bleiben die
# Systemfreigaben über Neubauten hinweg erhalten. Sonst – und für Release-Archive – ad hoc.
SIGN_ARGS=(--force --options runtime --entitlements Resources/Klar.entitlements --identifier de.felixsiebrasse.klar)
if [ "$1" != "--dist" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q "Klar Dev"; then
  codesign "${SIGN_ARGS[@]}" --sign "Klar Dev" "$APP" 2>&1 | grep -v "replacing existing" || true
  echo "Signiert mit: Klar Dev"
else
  codesign "${SIGN_ARGS[@]}" --sign - "$APP" 2>&1 | grep -v "replacing existing" || true
  if [ "$1" = "--dist" ]; then
    echo "Signiert: ad hoc (Release-Archiv)"
  else
    echo "Signiert: ad hoc (Freigaben gehen bei jedem Neubau verloren – einmal ./sign-setup.sh ausführen)"
  fi
fi

if [ "$1" = "--dist" ]; then
  ZIP="build/Klar-$VERSION.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "Archiv: $ZIP"
  exit 0
fi

TARGET=/Applications/Klar.app
if [ -w /Applications ]; then :; else TARGET="$HOME/Applications/Klar.app"; mkdir -p "$HOME/Applications"; fi

if [ "$1" != "--no-install" ]; then
  pkill -x Klar 2>/dev/null || true
  rm -rf "$TARGET"
  ditto "$APP" "$TARGET"
  echo "Installiert: $TARGET"
  [ "$1" = "--open" ] && open "$TARGET"
fi
