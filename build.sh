#!/bin/zsh
# Builds the menu-bar app next to this script, then `open Brightlink.app`.
# To rename the app, change APP_NAME here and rebuild; the Swift code reads the name from the bundle.
set -e
APP_NAME="Brightlink"
BUNDLE_ID="com.anam.${APP_NAME:l}"

cd "$(dirname "$0")"
APP="$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 MenuBarApp.swift -o "$APP/Contents/MacOS/$APP_NAME"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF
codesign --force --sign - "$APP"
echo "Built $APP"
