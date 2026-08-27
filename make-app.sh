#!/bin/sh
# Build LayerBar.app and install it to ~/Applications.
set -e
cd "$(dirname "$0")"

swift build -c release

APP="$HOME/Applications/LayerBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cp .build/release/LayerBar "$APP/Contents/MacOS/LayerBar"

cat > "$APP/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>dev.ephemera.LayerBar</string>
    <key>CFBundleName</key>
    <string>LayerBar</string>
    <key>CFBundleExecutable</key>
    <string>LayerBar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

codesign --force -s - "$APP"
echo "installed: $APP"
