#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_DIR="$SCRIPT_DIR/app"
APP_NAME="ClaudeHub"
APP_DIR="/Applications/$APP_NAME.app"
LAUNCH_AGENT_DIR="$HOME/Library/LaunchAgents"
LAUNCH_AGENT="$LAUNCH_AGENT_DIR/com.claudehub.app.plist"

NODE_PATH=$(command -v node 2>/dev/null || true)
if [ -z "$NODE_PATH" ]; then
    echo "Error: Node.js not found. Please install Node.js first."
    exit 1
fi
NODE_BIN_DIR=$(dirname "$NODE_PATH")

echo "Installing gateway dependencies..."
cd "$SCRIPT_DIR/gateway"
npm install --silent

echo "Bundling gateway sources for cloud Docker image..."
mkdir -p "$PKG_DIR/Sources/Resources/gateway"
cp "$SCRIPT_DIR/gateway/index.js" "$PKG_DIR/Sources/Resources/gateway/index.js"
cp "$SCRIPT_DIR/gateway/package.json" "$PKG_DIR/Sources/Resources/gateway/package.json"

echo "Building $APP_NAME..."
cd "$PKG_DIR"
swift build -c release 2>&1

echo "Creating app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp ".build/release/ClaudeHub" "$APP_DIR/Contents/MacOS/ClaudeHub"

# Copy SPM resource bundle (gateway sources) so Bundle.module can find them
if [ -d ".build/release/ClaudeHub_ClaudeHub.bundle" ]; then
    cp -R ".build/release/ClaudeHub_ClaudeHub.bundle" "$APP_DIR/Contents/MacOS/"
fi
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
    <string>com.claudehub.app</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Applications/ClaudeHub.app/Contents/MacOS/ClaudeHub</string>
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
