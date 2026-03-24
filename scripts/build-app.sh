#!/bin/bash
# Build SessionNoticer.app bundle
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/.build"
APP_NAME="SessionNoticer"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
BUNDLE_ID="com.sessionnoticer.app"

echo "Building $APP_NAME..."
cd "$PROJECT_DIR"
swift build -c release

echo "Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp "$BUILD_DIR/release/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy hook script
cp "$PROJECT_DIR/SessionNoticer/Resources/session-noticer-hook" "$APP_BUNDLE/Contents/Resources/"
chmod +x "$APP_BUNDLE/Contents/Resources/session-noticer-hook"

# Create Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo ""
echo "✅ Built: $APP_BUNDLE"
echo ""
echo "To install:"
echo "  cp -r $APP_BUNDLE /Applications/"
echo ""
echo "To run:"
echo "  open /Applications/$APP_NAME.app"
