#!/bin/bash
# Observes an already-running VolumeMixer without restarting it.
#
# The app must be launched from Finder or Spotlight, not from a terminal: TCC
# attributes audio capture to the process that launched the app, so a terminal
# launch is measured against Terminal's permissions and reports silence even
# when the GUI-launched app is capturing fine.
#
# Streams os_log, which is where the app writes when it was not started with
# VM_DEBUG_LOG=1. Prints buffer health on demand via SIGINT.
set -uo pipefail

SECONDS_TO_WATCH=${1:-30}
OUT=${2:-/tmp/volume-mixer-observe.log}

echo "Launch VolumeMixer from Finder or Spotlight now."
echo "Watching os_log for ${SECONDS_TO_WATCH}s. Play your audio during that time."
echo "Log: $OUT"
echo

log stream --predicate 'process == "VolumeMixer"' --style compact >"$OUT" 2>&1 &
STREAM_PID=$!

sleep "$SECONDS_TO_WATCH"

# SIGINT makes `log stream` flush and exit cleanly; a kill would truncate the
# tail, which is where the shutdown statistics land.
kill -INT "$STREAM_PID" 2>/dev/null
wait "$STREAM_PID" 2>/dev/null

echo
echo "Relevant lines:"
grep -iE "starved|low-water|mixer started|promoting|attached|silence|preflight|released|stalled" "$OUT" \
    || echo "(nothing matched -- app may not have been running)"
echo
echo "Full log: $OUT"
