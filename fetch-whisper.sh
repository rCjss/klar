#!/bin/zsh
# Lädt das fertige whisper.cpp-Framework (lokale Spracherkennung) nach Vendor/.
# Die Prüfsumme stellt sicher, dass genau die erwartete Datei ankommt.
set -e
cd "$(dirname "$0")"

TAG=b5454   # whisper.cpp v1.9.5
SHA=e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b
URL="https://github.com/ggml-org/whisper.cpp/releases/download/$TAG/whisper-$TAG-xcframework.zip"
DEST=Vendor/whisper.xcframework
STAMP=Vendor/.whisper-version

if [ -d "$DEST" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$TAG" ]; then exit 0; fi

mkdir -p Vendor
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
echo "Lade whisper.cpp ($TAG) …"
curl -fL --retry 3 --silent --show-error -o "$TMP/whisper.zip" "$URL"
if [ "$(shasum -a 256 "$TMP/whisper.zip" | cut -d' ' -f1)" != "$SHA" ]; then
  echo "Prüfsumme von whisper.cpp stimmt nicht – Abbruch." >&2
  exit 1
fi
ditto -x -k "$TMP/whisper.zip" "$TMP/out"
FOUND=$(find "$TMP/out" -maxdepth 3 -name "whisper.xcframework" -type d | head -1)
[ -n "$FOUND" ] || { echo "whisper.xcframework nicht im Archiv gefunden." >&2; exit 1; }
rm -rf "$DEST"
mv "$FOUND" "$DEST"
echo "$TAG" > "$STAMP"
echo "whisper.cpp bereit: $DEST"
