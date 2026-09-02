#!/bin/bash
# Builds NeoStat and assembles a double-clickable NeoStat.app bundle.
set -euo pipefail
cd "$(dirname "$0")"

APP="NeoStat.app"

echo ">> building (release)"
swift build -c release 2>&1 | grep -vE "ld: warning: search path" || true

echo ">> assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp .build/release/NeoStat "${APP}/Contents/MacOS/NeoStat"

cat > "${APP}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>NeoStat</string>
    <key>CFBundleDisplayName</key>       <string>NeoStat</string>
    <key>CFBundleIdentifier</key>        <string>com.neostat.hud</string>
    <key>CFBundleExecutable</key>        <string>NeoStat</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <!-- Agent app: floating HUD with no Dock icon and no menu bar. -->
    <key>LSUIElement</key>               <true/>
    <!-- Broadcast mode serves the dashboard to phones on the same Wi-Fi. -->
    <key>NSLocalNetworkUsageDescription</key>
    <string>NeoStat serves its dashboard to your phone, tablet and watch on this network.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_http._tcp</string>
    </array>
</dict>
</plist>
PLIST

# Ad-hoc signature so macOS launches it locally without a developer cert.
codesign --force --deep --sign - "${APP}" 2>/dev/null || echo "   (codesign skipped)"

echo ">> done: $(pwd)/${APP}"
