#!/bin/zsh
# Lädt die fertigen Bibliotheken für die lokale Spracherkennung nach Vendor/:
#   whisper.cpp  (Whisper Large-v3 und Large-v3 Turbo)
#   sherpa-onnx  (NVIDIA Parakeet TDT 0.6B v3)
# Die Prüfsummen stellen sicher, dass genau die erwarteten Dateien ankommen.
#   ./fetch-whisper.sh          Mac (macOS-Teile)
#   ./fetch-whisper.sh --ios    zusätzlich das iPhone-Framework von sherpa-onnx
set -e
cd "$(dirname "$0")"
mkdir -p Vendor

# fetch <Name> <Version> <SHA-256> <URL> <Ordner im Archiv> <Ziel>
fetch() {
  local name=$1 version=$2 sha=$3 url=$4 inner=$5 dest=$6
  local stamp="$dest.version"
  if [ -d "$dest" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$version" ]; then return 0; fi
  local tmp=$(mktemp -d)
  echo "Lade $name ($version) …"
  curl -fL --retry 3 --silent --show-error -o "$tmp/archive.zip" "$url"
  if [ "$(shasum -a 256 "$tmp/archive.zip" | cut -d' ' -f1)" != "$sha" ]; then
    echo "Prüfsumme von $name stimmt nicht – Abbruch." >&2
    rm -rf "$tmp"; exit 1
  fi
  ditto -x -k "$tmp/archive.zip" "$tmp/out"
  local found=$(find "$tmp/out" -maxdepth 3 -name "$inner" -type d | head -1)
  [ -n "$found" ] || { echo "$inner nicht im Archiv von $name gefunden." >&2; rm -rf "$tmp"; exit 1; }
  rm -rf "$dest"
  mv "$found" "$dest"
  echo "$version" > "$stamp"
  rm -rf "$tmp"
  echo "$name bereit: $dest"
}

# whisper.cpp v1.9.5 (enthält macOS und iOS)
fetch whisper.cpp b5454 e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b \
  https://github.com/ggml-org/whisper.cpp/releases/download/b5454/whisper-b5454-xcframework.zip \
  whisper.xcframework Vendor/whisper.xcframework
# Alter Versionsstempel aus der Zeit vor sherpa-onnx
rm -f Vendor/.whisper-version

# sherpa-onnx 2.0.3, macOS: eine dynamische Bibliothek mit fest eingebautem onnxruntime
fetch sherpa-onnx-macos v2.0.3 006a23ffe954c5efb779950b6ed46843d0125eb7a0617f98e2598ee51c68529c \
  https://github.com/k2-fsa/sherpa-onnx/releases/download/xcframework/sherpa-onnx-v2.0.3-macos-shared-onnxruntime-static.xcframework.zip \
  sherpa-onnx.xcframework Vendor/sherpa-onnx-macos.xcframework

if [ "$1" = "--ios" ]; then
  fetch sherpa-onnx-ios v2.0.3 6e35088e42c7ccbacea6377d198cca5e0e05262b11f17c9225af445a5bbb5c5e \
    https://github.com/k2-fsa/sherpa-onnx/releases/download/xcframework/sherpa-onnx-v2.0.3-ios-shared-onnxruntime-static.xcframework.zip \
    SherpaOnnxC.xcframework Vendor/SherpaOnnxC-ios.xcframework
fi
