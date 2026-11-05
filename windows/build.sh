#!/bin/sh
# Baut die Windows-Fassung von Klar auf macOS oder Linux (Cross-Build, braucht nur das .NET-10-SDK).
#   ./build.sh           Tests + Paket dist/Klar-<Version>-win-x64.zip
#   ./build.sh --no-test nur das Paket
# Ausgeführt und getestet wird das Ergebnis unter Windows: Klar.exe --selftest
set -e
cd "$(dirname "$0")"
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1

if [ "$1" != "--no-test" ]; then
  dotnet test tests/Klar.Core.Tests -c Release --nologo -v q
fi

VERSION=$(sed -n 's/.*<Version>\(.*\)<\/Version>.*/\1/p' Directory.Build.props)
rm -rf dist
dotnet publish src/Klar -c Release -o dist/Klar --nologo -v q
find dist/Klar/runtimes -type d -empty -delete
rm -f dist/Klar/*.pdb

ZIP="Klar-$VERSION-win-x64.zip"
(cd dist && zip -qr "$ZIP" Klar)
echo "Paket: dist/$ZIP ($(du -h "dist/$ZIP" | cut -f1))"
