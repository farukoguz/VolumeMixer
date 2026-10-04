#!/bin/bash
# Captures a VolumeMixer debug log for diagnosis.
#
# Starts the app with stdout logging enabled, waits while you play audio, then
# stops it. The shutdown path prints per-channel buffer health, which is the
# only place that can be read safely: the audio thread itself cannot log.
set -uo pipefail

APP=/Applications/VolumeMixer.app/Contents/MacOS/VolumeMixer
OUT=${1:-/tmp/volume-mixer-diag.log}
SECONDS_TO_RUN=${2:-25}

if [[ ! -x "$APP" ]]; then
  echo "VolumeMixer is not installed at /Applications/VolumeMixer.app" >&2
  exit 1
fi

pkill -x VolumeMixer 2>/dev/null
sleep 1

echo "Recording to $OUT for ${SECONDS_TO_RUN}s."
echo "Play your audio NOW, loudly enough that it is obviously playing."
echo

VM_DEBUG_LOG=1 "$APP" >"$OUT" 2>&1 &
APP_PID=$!
sleep "$SECONDS_TO_RUN"

# SIGTERM lets the app run its shutdown path, which is where the buffer
# statistics are printed. A hard kill would lose them.
kill -TERM "$APP_PID" 2>/dev/null
wait "$APP_PID" 2>/dev/null
pkill -x VolumeMixer 2>/dev/null

echo "Done. Relevant lines:"
grep -E "starved|mixer started|promoting|attached|silence|stalled" "$OUT" || echo "(nothing matched -- full log below)"
echo
echo "Full log: $OUT"
