#!/bin/bash
# Builds Resonata.app without needing an Xcode project.
#   ./build.sh          build
#   ./build.sh run      build, then relaunch
set -euo pipefail

cd "$(dirname "$0")"
APP="Resonata.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -target "$(uname -m)-apple-macos14.0" \
    -o "$APP/Contents/MacOS/Resonata" \
    AudioSpectrum.swift Lyrics.swift NotchPanel.swift NotchShape.swift ResonataApp.swift \
    NotchView.swift NowPlaying.swift ScreenGeometry.swift

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>Resonata</string>
    <key>CFBundleExecutable</key>        <string>Resonata</string>
    <key>CFBundleIdentifier</key>        <string>com.local.resonata</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <!-- No Dock icon, no app switcher entry — it lives in the notch. -->
    <key>LSUIElement</key>               <true/>
    <!-- Required, or the AppleScript calls to Spotify/Music are killed on sight. -->
    <key>NSAppleEventsUsageDescription</key>
    <string>Resonata reads what you are currently playing.</string>
</dict>
</plist>
PLIST

# Sign with the stable "Resonata Dev" identity if setup-signing.sh has created
# it, otherwise ad-hoc.
#
# The difference matters more than it looks. An ad-hoc signature is a hash of
# the binary, so every rebuild is a brand-new identity to macOS — and
# permissions are tied to identity. With ad-hoc signing, every build silently
# revoked Automation and Screen Recording and the app looked broken until they
# were granted again. Without *any* signature, macOS refuses to grant them at
# all.
IDENTITY="Resonata Dev"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    codesign --force --deep --sign "$IDENTITY" "$APP"
else
    codesign --force --deep --sign - "$APP"
    echo "note: signed ad-hoc — permissions reset on every build."
    echo "      Run ./setup-signing.sh once to fix that."
fi

echo "Built $PWD/$APP"

if [ "${1:-}" = "run" ]; then
    pkill -x Resonata 2>/dev/null || true
    open "$APP"
    echo "Launched. Quit it later with: pkill -x Resonata"
fi
