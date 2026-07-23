#!/bin/bash
# Build manuale di CallT.app (swiftc) — non richiede xcodebuild.
# Uso: scripts/build.sh [--universal]
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME=CallT
BUNDLE_ID=com.werootbox.callt
VERSION=1.0.0
BUILD_DIR=build.noindex   # .noindex: Spotlight/Launchpad ignorano le build
APP="$BUILD_DIR/$APP_NAME.app"
SDK=$(xcrun --show-sdk-path --sdk macosx)
TOOLCHAIN=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain
XCODE_BUILD=$(defaults read /Applications/Xcode.app/Contents/version.plist ProductBuildVersion 2>/dev/null || echo 17F113)
UNIVERSAL=${1:-}

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD_DIR/obj"

# ── Icona ────────────────────────────────────────────
if [ ! -f Resources/AppIcon.icns ]; then
  swift scripts/make_icon.swift Resources
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# ── Localizzazioni ───────────────────────────────────
for LPROJ in Resources/*.lproj; do
  [ -d "$LPROJ" ] && cp -R "$LPROJ" "$APP/Contents/Resources/"
done
mkdir -p "$APP/Contents/Resources/en.lproj"   # base: le chiavi sono in inglese

# ── Sorgenti ─────────────────────────────────────────
find Sources -name '*.swift' | sort > "$BUILD_DIR/sources.txt"

compile() {
  local arch=$1 out=$2 constvals=$3
  xcrun swiftc \
    -swift-version 6 \
    -target "$arch-apple-macos26.0" \
    -sdk "$SDK" \
    -O -wmo \
    -module-name "$APP_NAME" \
    -emit-const-values-path "$constvals" \
    -Xfrontend -const-gather-protocols-file -Xfrontend scripts/protocols.json \
    -o "$out" \
    @"$BUILD_DIR/sources.txt"
}

echo "→ Compilazione arm64…"
compile arm64 "$BUILD_DIR/obj/$APP_NAME-arm64" "$BUILD_DIR/obj/$APP_NAME.swiftconstvalues"

if [ "$UNIVERSAL" = "--universal" ]; then
  echo "→ Compilazione x86_64…"
  compile x86_64 "$BUILD_DIR/obj/$APP_NAME-x86_64" "$BUILD_DIR/obj/$APP_NAME-x86_64.swiftconstvalues"
  lipo -create -output "$APP/Contents/MacOS/$APP_NAME" \
    "$BUILD_DIR/obj/$APP_NAME-arm64" "$BUILD_DIR/obj/$APP_NAME-x86_64"
else
  cp "$BUILD_DIR/obj/$APP_NAME-arm64" "$APP/Contents/MacOS/$APP_NAME"
fi

# ── Info.plist ───────────────────────────────────────
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleLocalizations</key><array><string>en</string><string>it</string></array>
	<key>CFBundleDisplayName</key><string>$APP_NAME</string>
	<key>CFBundleExecutable</key><string>$APP_NAME</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>$APP_NAME</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>26.0</string>
	<key>LSUIElement</key><true/>
	<key>NSMicrophoneUsageDescription</key><string>CallT uses the microphone to record your voice during calls.</string>
	<key>NSHumanReadableCopyright</key><string>© 2026 werootbox</string>
	<key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

# ── Metadati App Intents ─────────────────────────────
echo "→ Estrazione metadati App Intents…"
echo "$BUILD_DIR/obj/$APP_NAME.swiftconstvalues" > "$BUILD_DIR/constvals.txt"
xcrun appintentsmetadataprocessor \
  --toolchain-dir "$TOOLCHAIN" \
  --module-name "$APP_NAME" \
  --sdk-root "$SDK" \
  --xcode-version "$XCODE_BUILD" \
  --platform-family macOS \
  --deployment-target 26.0 \
  --target-triple arm64-apple-macos26.0 \
  --binary-file "$APP/Contents/MacOS/$APP_NAME" \
  --output "$APP/Contents/Resources" \
  --source-file-list "$BUILD_DIR/sources.txt" \
  --swift-const-vals-list "$BUILD_DIR/constvals.txt" 2>&1 | grep -v '^$' | tail -3

test -f "$APP/Contents/Resources/Metadata.appintents/extract.actionsdata" \
  || { echo "❌ Metadata.appintents mancante"; exit 1; }

# ── Firma ────────────────────────────────────────────
# Preferisce il certificato locale stabile (i permessi TCC sopravvivono
# agli aggiornamenti); altrimenti firma ad-hoc. Vedi make-signing-cert.sh.
IDENTITY=${CODESIGN_IDENTITY:-}
if [ -z "$IDENTITY" ] && security find-identity -v -p codesigning | grep -q "CallT Local Signing"; then
  IDENTITY="CallT Local Signing"
fi
codesign --force --deep --sign "${IDENTITY:--}" "$APP"
codesign --verify --strict "$APP"
echo "→ Firma: ${IDENTITY:-ad-hoc}"

echo "✅ Build completata: $APP"
