#!/usr/bin/env bash
# Build a distributable .app bundle from the Swift Package and wrap it in a
# DMG. No Xcode project / no signing identity / no notarization required —
# this produces an ad-hoc-signed app you can hand to other people on the
# same architecture.
#
# Usage:
#   scripts/build_dmg.sh                # produces build/FalMac-<version>.dmg
#   VERSION=1.2.3 scripts/build_dmg.sh  # override the embedded version

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-1.0.0}"
APP_NAME="FalMac"
BUNDLE_ID="ai.fal.FalMac"
MIN_OS="26.0"
BUILD_DIR="$ROOT/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
ICONSET_DIR="$BUILD_DIR/AppIcon.iconset"
DMG_STAGING="$BUILD_DIR/dmg-staging"
DMG_OUT="$BUILD_DIR/${APP_NAME}-${VERSION}.dmg"

echo "==> Cleaning build directory"
rm -rf "$APP_DIR" "$ICONSET_DIR" "$DMG_STAGING" "$DMG_OUT"
mkdir -p "$BUILD_DIR"

echo "==> Building release binary (this may take a minute)"
swift build -c release

# Resolve where SPM put the binary — varies a little by toolchain version.
BIN_DIR="$(swift build -c release --show-bin-path)"
EXE="$BIN_DIR/$APP_NAME"
RESOURCES_BUNDLE="$BIN_DIR/${APP_NAME}_${APP_NAME}.bundle"
if [[ ! -x "$EXE" ]]; then
    echo "!! Couldn't find release binary at $EXE"
    exit 1
fi
if [[ ! -d "$RESOURCES_BUNDLE" ]]; then
    echo "!! Couldn't find Bundle.module resource bundle at $RESOURCES_BUNDLE"
    exit 1
fi

echo "==> Staging $APP_NAME.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$EXE" "$APP_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"

# Bring the SPM resource bundle along so Bundle.module continues to work.
cp -R "$RESOURCES_BUNDLE" "$APP_DIR/Contents/Resources/"

echo "==> Generating AppIcon.icns"
ICON_SRC="Sources/$APP_NAME/Resources/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$ICONSET_DIR"
cp "$ICON_SRC/icon_16x16.png"       "$ICONSET_DIR/icon_16x16.png"
cp "$ICON_SRC/icon_16x16@2x.png"    "$ICONSET_DIR/icon_16x16@2x.png"
cp "$ICON_SRC/icon_32x32.png"       "$ICONSET_DIR/icon_32x32.png"
cp "$ICON_SRC/icon_32x32@2x.png"    "$ICONSET_DIR/icon_32x32@2x.png"
cp "$ICON_SRC/icon_128x128.png"     "$ICONSET_DIR/icon_128x128.png"
cp "$ICON_SRC/icon_128x128@2x.png"  "$ICONSET_DIR/icon_128x128@2x.png"
cp "$ICON_SRC/icon_256x256.png"     "$ICONSET_DIR/icon_256x256.png"
cp "$ICON_SRC/icon_256x256@2x.png"  "$ICONSET_DIR/icon_256x256@2x.png"
cp "$ICON_SRC/icon_512x512.png"     "$ICONSET_DIR/icon_512x512.png"
cp "$ICON_SRC/icon_512x512@2x.png"  "$ICONSET_DIR/icon_512x512@2x.png"
iconutil -c icns "$ICONSET_DIR" -o "$APP_DIR/Contents/Resources/AppIcon.icns"

echo "==> Writing Info.plist"
cat > "$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
    <key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict>
</plist>
EOF

# Ad-hoc sign so Gatekeeper allows it to launch at all (modern macOS
# refuses to run completely unsigned binaries on Apple silicon).
echo "==> Ad-hoc signing"
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --verbose=2 "$APP_DIR" || true

echo "==> Building DMG"
mkdir -p "$DMG_STAGING"
cp -R "$APP_DIR" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

hdiutil create \
    -volname "$APP_NAME $VERSION" \
    -srcfolder "$DMG_STAGING" \
    -ov \
    -format UDZO \
    "$DMG_OUT" >/dev/null

# Show final size + path.
SIZE=$(du -h "$DMG_OUT" | awk '{print $1}')
echo
echo "    ✓ $DMG_OUT  ($SIZE)"
echo
