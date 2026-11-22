#!/bin/bash
# Double-click to build BRIR Convolver, run its DSP self-test, and install it to /Applications.
cd "$(dirname "$0")"
{
  echo "=== $(date) ==="
  sw_vers; xcrun swiftc --version 2>&1 | head -2
  ./build.sh --test ../BRIR_True_Stereo.wav && ./build.sh --install
  echo "EXIT: $?"
} 2>&1 | tee build.log
echo; echo "Done — you can close this window."
