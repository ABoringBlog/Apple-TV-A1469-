#!/usr/bin/env bash
# Private on-demand iCloud Photos audio capture for Mac.
# Run only through an authenticated NAS SSH session.
# No photo data, audio files, or credentials are ever written to disk.
# Bypass the inherited PULSE_RUNTIME_PATH=/defaults, whose root-owned
# permissions can cause PulseAudio to refuse creating a client runtime dir.
# Connect directly to the existing private Unix socket instead.
export PULSE_SERVER=unix:/defaults/native
exec -a ATV3iCloudPCM-parec /usr/bin/parec \
  --device=output.monitor --format=s16le --rate=44100 --channels=2 \
  --latency-msec=50 --process-time-msec=15 --raw
