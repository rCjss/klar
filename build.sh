#!/bin/zsh
# Baut Klar.app und installiert sie nach /Applications (Fallback: ~/Applications).
#   ./build.sh            bauen + installieren
#   ./build.sh --open     bauen + installieren + starten
#   ./build.sh --no-install
#   ./build.sh --dist     Release-Archiv build/Klar-<Version>.zip (ad hoc signiert, nicht installieren)
set -e
cd "$(dirname "$0")"

./fetch-whisper.sh   # whisper.cpp-Framework für die Whisper-Erkennung (einmaliger Download)

swift build -c release 2>&1 | grep -E "error|warning: unre|Compiling|Build complete" | tail -20

APP=build/Klar.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Klar "$APP/Contents/MacOS/Klar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
echo -n "APPL????" > "$APP/Contents/PkgInfo"

# Whisper: Hilfsprozess unter Contents/Helpers, whisper.cpp-Framework unter Contents/Frameworks.
# Nur die Architektur dieses Macs wird mitgenommen.
WHISPER="$APP/Contents/Frameworks/whisper.framework"
HELPER="$APP/Contents/Helpers/KlarWhisper"
mkdir -p "$APP/Contents/Frameworks" "$APP/Contents/Helpers"
cp .build/release/KlarWhisper "$HELPER"
ditto Vendor/whisper.xcframework/macos-arm64_x86_64/whisper.framework "$WHISPER"
rm -rf "$WHISPER/Headers" "$WHISPER/Modules" "$WHISPER/Versions/A/Headers" "$WHISPER/Versions/A/Modules"
lipo "$WHISPER/Versions/A/whisper" -thin "$(uname -m)" -output "$WHISPER/Versions/A/whisper"

# Signatur: mit lokalem Zertifikat „Klar Dev“ (siehe sign-setup.sh) bleiben die
# Systemfreigaben über Neubauten hinweg erhalten. Sonst – und für Release-Archive – ad hoc.
# Reihenfolge von innen nach außen: Framework, Helfer, dann die App (sie versiegelt beide mit).
SIGN_ARGS=(--force --options runtime --entitlements Resources/Klar.entitlements --identifier de.felixsiebrasse.klar)
HELPER_ARGS=(--force --options runtime --entitlements Resources/KlarWhisper.entitlements --identifier de.felixsiebrasse.klar.whisper)
if [ "$1" != "--dist" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q "Klar Dev"; then
  codesign --force --options runtime --sign "Klar Dev" "$WHISPER" 2>&1 | grep -v "replacing existing" || true
  codesign "${HELPER_ARGS[@]}" --sign "Klar Dev" "$HELPER" 2>&1 | grep -v "replacing existing" || true
  codesign "${SIGN_ARGS[@]}" --sign "Klar Dev" "$APP" 2>&1 | grep -v "replacing existing" || true
  echo "Signiert mit: Klar Dev"
else
  codesign --force --options runtime --sign - "$WHISPER" 2>&1 | grep -v "replacing existing" || true
  codesign "${HELPER_ARGS[@]}" --sign - "$HELPER" 2>&1 | grep -v "replacing existing" || true
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
