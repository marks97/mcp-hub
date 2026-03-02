#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_DIR="$SCRIPT_DIR/app"
APP_NAME="ClaudeDesktopManager"
APP_DIR="/Applications/$APP_NAME.app"
LAUNCH_AGENT_DIR="$HOME/Library/LaunchAgents"
LAUNCH_AGENT="$LAUNCH_AGENT_DIR/com.claudedesktopmanager.app.plist"

NODE_PATH=$(command -v node 2>/dev/null || true)
if [ -z "$NODE_PATH" ]; then
    echo "Error: Node.js not found. Please install Node.js first."
    exit 1
fi
NODE_BIN_DIR=$(dirname "$NODE_PATH")

echo "Installing gateway dependencies..."
cd "$SCRIPT_DIR/gateway"
npm install --silent

echo "Building $APP_NAME..."
cd "$PKG_DIR"
swift build -c release 2>&1

echo "Creating app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp ".build/release/ClaudeDesktopManager" "$APP_DIR/Contents/MacOS/ClaudeDesktopManager"
cp Info.plist "$APP_DIR/Contents/Info.plist"
cp AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"

echo "Installing launch agent (start at login)..."
mkdir -p "$LAUNCH_AGENT_DIR"

cat > "$LAUNCH_AGENT" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.claudedesktopmanager.app</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Applications/ClaudeDesktopManager.app/Contents/MacOS/ClaudeDesktopManager</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$NODE_BIN_DIR</string>
    </dict>
</dict>
</plist>
EOF

launchctl unload "$LAUNCH_AGENT" 2>/dev/null || true
launchctl load "$LAUNCH_AGENT"

echo ""
echo "Installed to /Applications/$APP_NAME.app"
echo "Launch agent installed (starts at login)"
echo "Starting now..."

pkill -f "$APP_NAME" 2>/dev/null || true
sleep 0.5
open "$APP_DIR"
