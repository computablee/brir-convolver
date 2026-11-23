#!/bin/bash
# Builds "BRIR Convolver.app" with the Swift compiler from Xcode or the Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/BRIR Convolver.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling…"
xcrun swiftc -O -wmo -parse-as-library -swift-version 5 \
    -target arm64-apple-macos14.4 \
    -framework CoreAudio -framework AudioToolbox -framework Accelerate \
    -framework AppKit -framework SwiftUI -framework ServiceManagement \
    Sources/*.swift -o "$APP/Contents/MacOS/BRIRConvolver"

cp Info.plist "$APP/Contents/Info.plist"

# App icon: any square-ish Icon.png / Icon.jpg next to this script becomes the .icns
ICON_SRC=""
for f in Icon.png Icon.jpg Icon.jpeg Icon.heic; do [[ -f "$f" ]] && ICON_SRC="$f" && break; done
if [[ -n "$ICON_SRC" ]]; then
    ICONSET="build/AppIcon.iconset"
    rm -rf "$ICONSET"; mkdir -p "$ICONSET"
    sips -s format png "$ICON_SRC" --out build/icon_src.png >/dev/null
    for s in 16 32 128 256 512; do
        sips -z $s $s build/icon_src.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        sips -z $((s*2)) $((s*2)) build/icon_src.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
    echo "Icon: $ICON_SRC"
fi
codesign --force --sign - --timestamp=none "$APP" >/dev/null
echo "Built: $(pwd)/$APP"

if [[ "${1:-}" == "--test" ]]; then
    # Optional second argument: a BRIR WAV to test with. Without it a synthetic BRIR is used.
    "$APP/Contents/MacOS/BRIRConvolver" --selftest "${2:-}"
fi
if [[ "${1:-}" == "--install" ]]; then
    rm -rf "/Applications/BRIR Convolver.app"
    cp -R "$APP" /Applications/
    touch "/Applications/BRIR Convolver.app"   # nudge Finder/Dock to refresh the icon
    echo "Installed to /Applications/BRIR Convolver.app"
fi
