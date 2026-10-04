#!/bin/bash
# Measures whether per-app gain actually changes what comes out of the speakers.
#
# Core Audio publishes no output meter, so the only way to check that moving a
# slider does something is to listen to the result. This plays a tone through the
# mixer and measures the system level with a global tap at unity, at half gain,
# muted, and restored again. A working gain path reads about -6 dB at half and
# silence when muted.
#
# It deliberately does NOT rebuild the app. An ad-hoc signed binary is identified
# by its code hash, so rebuilding makes macOS treat it as a different app and drops
# the Screen & System Audio Recording grant. Rebuild first, grant, then run this.
#
# Requires: Screen & System Audio Recording granted to build/VolumeMixer.app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/VolumeMixer.app"
LOG="${TMPDIR:-/tmp}/volumemixer-verify.log"
TONE="${TMPDIR:-/tmp}/volumemixer-verify-tone.wav"

if [ ! -d "$APP" ]; then
    echo "!! $APP not found. Run ./Scripts/build-app.sh first." >&2
    exit 1
fi

# A 440 Hz tone, generated rather than shipped, so the check has no asset.
if [ ! -f "$TONE" ]; then
    python3 - "$TONE" <<'PY'
import math, struct, sys
path, rate, seconds, hz = sys.argv[1], 48000, 30, 440
frames = bytearray()
for i in range(rate * seconds):
    env = min(1.0, i / (rate * 0.05), (rate * seconds - i) / (rate * 0.05))
    value = int(0.5 * env * 32767 * math.sin(2 * math.pi * hz * i / rate))
    frames += struct.pack('<hh', value, value)
data = bytes(frames)
header = (b'RIFF' + struct.pack('<I', 36 + len(data)) + b'WAVEfmt '
          + struct.pack('<IHHIIHH', 16, 1, 2, rate, rate * 4, 4, 16)
          + b'data' + struct.pack('<I', len(data)))
open(path, 'wb').write(header + data)
PY
fi

cleanup() {
    pkill -f "VolumeMixer.app/Contents/MacOS" 2>/dev/null || true
    pkill -f "$TONE" 2>/dev/null || true
}
trap cleanup EXIT
cleanup
sleep 1

echo "==> measuring (about 25s)"
VM_DEBUG_LOG=1 VM_SELFTEST=1 "$APP/Contents/MacOS/VolumeMixer" >"$LOG" 2>&1 &
disown
sleep 2
afplay "$TONE" &

for _ in $(seq 1 45); do
    if grep -q "self-test VERDICT" "$LOG" 2>/dev/null; then break; fi
    sleep 1
done

echo
grep -E "self-test" "$LOG" | sed 's/^\[log\] //; s/^\[error\] //'
echo
grep -E "taps deliver only silence" "$LOG" >/dev/null 2>&1 && \
    echo "!! capture was refused, so nothing was measured. Grant Screen & System" && \
    echo "   Audio Recording in System Settings > Privacy & Security, then re-run."
exit 0