#!/bin/bash
# Build Afterclip as a proper .app bundle (menu-bar app) and ad-hoc code-sign it.
# A real app bundle is what gives ScreenCaptureKit a stable capture connection and its
# own "Afterclip" entry in Privacy & Security ▸ Screen & System Audio Recording.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "▸ Building release binary…"
swift build -c release

APP="$ROOT/Afterclip.app"
CONTENTS="$APP/Contents"
echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp ".build/release/Afterclip" "$CONTENTS/MacOS/Afterclip"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>           <string>Afterclip</string>
    <key>CFBundleIdentifier</key>           <string>com.afterclip.app</string>
    <key>CFBundleName</key>                 <string>Afterclip</string>
    <key>CFBundleDisplayName</key>          <string>Afterclip</string>
    <key>CFBundlePackageType</key>          <string>APPL</string>
    <key>CFBundleShortVersionString</key>   <string>0.1.0</string>
    <key>CFBundleVersion</key>              <string>1</string>
    <key>LSMinimumSystemVersion</key>       <string>15.0</string>
    <key>LSUIElement</key>                  <true/>
    <key>NSHighResolutionCapable</key>      <true/>
    <key>CFBundleIconFile</key>             <string>AppIcon</string>
    <key>NSMicrophoneUsageDescription</key> <string>Afterclip records game audio for your clips.</string>
</dict>
</plist>
PLIST

# App icon: drop a square PNG (ideally 1024×1024) at the project root as "icon.png" and it
# gets turned into AppIcon.icns automatically. No icon.png -> default generic icon (harmless).
if [ -f "$ROOT/icon.png" ]; then
    echo "▸ Generating app icon from icon.png…"
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for s in 16 32 128 256 512; do
        sips -z $s $s         "$ROOT/icon.png" --out "$ICONSET/icon_${s}x${s}.png"     >/dev/null
        sips -z $((s*2)) $((s*2)) "$ROOT/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"
fi

# Prefer the stable self-signed identity (so Screen Recording permission persists across
# rebuilds). It's untrusted, so we resolve it by its unique hash and sign by that (signing
# with an untrusted self-signed cert is fine and still yields a stable identity for TCC).
HASH="$(security find-identity -p codesigning 2>/dev/null | awk '/Afterclip Dev/{print $2; exit}')"
if [ -n "$HASH" ]; then
    echo "▸ Code signing with stable identity 'Afterclip Dev' ($HASH)…"
    codesign --force --deep --sign "$HASH" "$APP"
else
    echo "▸ Ad-hoc code signing (run scripts/setup-signing.sh for a stable signature)…"
    codesign --force --deep --sign - "$APP"
fi

echo ""
echo "✅ Built: $APP"
echo "   Launch with:  open \"$APP\""
echo "   First launch will ask for Screen Recording permission — grant it, then reopen."
