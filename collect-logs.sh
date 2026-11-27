#!/bin/bash
# Collects everything needed to debug an audio problem into logs/<timestamp>/.
# Usage: ./collect-logs.sh [minutes]   (default 5: run it right after reproducing the problem)
set -uo pipefail
cd "$(dirname "$0")"
M="${1:-5}"
OUT="logs/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

echo "Collecting the last $M minutes into $OUT …"
log show --last "${M}m" --style compact --info \
    --predicate 'subsystem == "com.phil.brirconvolver" OR subsystem == "com.phil.brirconvolver.device"' \
    > "$OUT/app-and-driver.log" 2>&1
log show --last "${M}m" --style compact \
    --predicate 'process == "coreaudiod" OR process CONTAINS "Core-Audio-Driver-Service" OR process == "BRIRConvolver" OR (process == "Music" AND category CONTAINS[c] "audio")' \
    > "$OUT/coreaudio.log" 2>&1

# Crash reports from the last $M minutes (ours, Core Audio's, and Music's).
for d in "$HOME/Library/Logs/DiagnosticReports" /Library/Logs/DiagnosticReports; do
    [[ -d "$d" ]] || continue
    find "$d" -maxdepth 1 -type f -mmin "-$M" \
        \( -iname '*coreaudio*' -o -iname '*Core-Audio*' -o -iname '*BRIRConvolver*' -o -iname 'Music*' \) \
        -exec cp {} "$OUT/" \; 2>/dev/null
done

system_profiler SPAudioDataType > "$OUT/audio-devices.txt" 2>&1
sw_vers > "$OUT/system.txt" 2>&1

echo "Done:"
ls -la "$OUT"
