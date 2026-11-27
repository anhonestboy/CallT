#!/bin/bash
# Crea il DMG distribuibile (build universale arm64+x86_64, firma ad-hoc).
# Uso: scripts/package.sh
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build.sh --universal

rm -rf build.noindex/dmgroot build.noindex/Recap.dmg
mkdir -p build.noindex/dmgroot
cp -R build.noindex/Recap.app build.noindex/dmgroot/
cp README.txt LEGGIMI.txt build.noindex/dmgroot/
ln -s /Applications build.noindex/dmgroot/Applications
hdiutil create -volname Recap -srcfolder build.noindex/dmgroot -ov -format UDZO build.noindex/Recap.dmg
rm -rf build.noindex/dmgroot
echo "✅ DMG pronto: build.noindex/Recap.dmg"
