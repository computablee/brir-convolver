#!/bin/bash
# Removes the BRIR Convolver Surround audio device and restarts Core Audio.  Usage: sudo Driver/uninstall.sh
set -euo pipefail
rm -rf /Library/Audio/Plug-Ins/HAL/BRIRConvolverSurround.driver
echo "Removed /Library/Audio/Plug-Ins/HAL/BRIRConvolverSurround.driver"
launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null || killall coreaudiod
echo "Core Audio restarted."
