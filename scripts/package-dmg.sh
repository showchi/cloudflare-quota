#!/bin/zsh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode-26.6.0.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode-26.6.0.app/Contents/Developer
fi

scripts/generate-info-plist.sh

# Check image-generation dependencies before building or replacing existing artifacts.
if ! python3 -c 'from PIL import Image, ImageDraw, ImageFont' >/dev/null 2>&1; then
  echo "Missing Pillow. Install scripts/requirements.txt in a Python virtual environment before packaging." >&2
  exit 1
fi

swift build -c release

bin="$(swift build -c release --show-bin-path)/QuotaBar"
resource_bundle="$(swift build -c release --show-bin-path)/cloudflare-quota_QuotaBar.bundle"
stage="$root/dist/stage"
app="$stage/Cloudflare Quota.app"
rm -rf "$stage"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/Cloudflare Quota"
chmod +x "$app/Contents/MacOS/Cloudflare Quota"
cp "$root/scripts/Info.plist" "$app/Contents/Info.plist"
cp "$root/assets/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
if [[ ! -d "$resource_bundle" ]]; then
  echo "Missing resource bundle: $resource_bundle" >&2
  exit 1
fi
cp -R "$resource_bundle" "$app/Contents/Resources/"

codesign --force --sign - "$app"

# The window shows the app on the left and Applications on the right.
ln -sfn /Applications "$stage/Applications"

background="$root/assets/dmg-background.png"
python3 "$root/scripts/make-dmg-background.py"

mount="/Volumes/Cloudflare Quota"
if [[ -d "$mount" ]]; then
  hdiutil detach "$mount" >/dev/null || diskutil eject "$mount" >/dev/null
fi

rw="$root/dist/CloudflareQuota-rw.dmg"
rm -f "$rw" "$root/dist/CloudflareQuota.dmg"
hdiutil create \
  -volname "Cloudflare Quota" \
  -srcfolder "$stage" \
  -fs HFS+ \
  -format UDRW \
  -ov \
  "$rw" >/dev/null

device="$(hdiutil attach -readwrite -noverify -noautoopen "$rw" | awk 'END {print $1}')"
mkdir -p "$mount/.background"
cp "$background" "$mount/.background/background.png"
bless --folder "$mount" || true

osascript <<'APPLESCRIPT'
tell application "Finder"
  tell disk "Cloudflare Quota"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 880, 520}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 112
    set background picture of viewOptions to file ".background:background.png"
    set position of item "Cloudflare Quota.app" of container window to {160, 180}
    set position of item "Applications" of container window to {500, 180}
    update without registering applications
    delay 2
    close
  end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$device" >/dev/null
hdiutil convert "$rw" -format UDZO -imagekey zlib-level=9 -o "$root/dist/CloudflareQuota.dmg" >/dev/null
rm -f "$rw"
rm -rf "$stage"
echo "dist/CloudflareQuota.dmg"
