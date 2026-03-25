#!/bin/bash
# Package SessionNoticer.app into a zip for sharing
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Build first
"$SCRIPT_DIR/build-app.sh"

# Create zip
cd "$PROJECT_DIR/.build"
ZIP_PATH="$PROJECT_DIR/SessionNoticer.zip"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "SessionNoticer.app" "$ZIP_PATH"

echo ""
echo "✅ Packaged: $ZIP_PATH"
echo "   Size: $(du -h "$ZIP_PATH" | cut -f1)"
echo ""
echo "Share this file. Recipient instructions:"
echo "  1. unzip SessionNoticer.zip -d /Applications/"
echo "  2. Right-click SessionNoticer.app → Open"
echo "  3. Grant Accessibility permission when prompted"
echo "  4. Restart Claude Code sessions to start tracking"
