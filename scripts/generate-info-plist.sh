#!/bin/zsh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
version=$(<"$root/VERSION")
build=$(git -C "$root" rev-list --count HEAD 2>/dev/null || true)
if [[ -z "$build" || "$build" == "0" ]]; then
  build=1
fi

cat > "$root/scripts/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Cloudflare Quota</string>
    <key>CFBundleIdentifier</key>
    <string>app.cloudflare-quota</string>
    <key>CFBundleName</key>
    <string>Cloudflare Quota</string>
    <key>CFBundleDisplayName</key>
    <string>Cloudflare Quota</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${version}</string>
    <key>CFBundleVersion</key>
    <string>${build}</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST
