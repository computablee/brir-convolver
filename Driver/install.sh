#!/bin/bash
# Installs the BRIR Convolver Surround audio device and restarts Core Audio.
# Usage: sudo Driver/install.sh [path/to/BRIRConvolverSurround.driver]
# (Without a path, the copy inside build/BRIR Convolver.app or /Applications/BRIR Convolver.app is used.)
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="${1:-}"
if [[ -z "$SRC" ]]; then
    for c in "build/BRIR Convolver.app/Contents/Resources/BRIRConvolverSurround.driver" \
             "/Applications/BRIR Convolver.app/Contents/Resources/BRIRConvolverSurround.driver"; do
        [[ -d "$c" ]] && SRC="$c" && break
    done
fi
[[ -d "$SRC" ]] || { echo "Driver bundle not found; run ./build.sh first." >&2; exit 1; }
DST=/Library/Audio/Plug-Ins/HAL
mkdir -p "$DST"
rm -rf "$DST/BRIRConvolverSurround.driver"
cp -R "$SRC" "$DST/"
echo "Installed $DST/BRIRConvolverSurround.driver"
launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null || killall coreaudiod
echo "Core Audio restarted."
