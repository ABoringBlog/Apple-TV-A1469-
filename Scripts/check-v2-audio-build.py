#!/usr/bin/env python3
"""Fail builds missing the AVR3 paired Mac V2 audio bridge.

No secrets, filesystem writes, sockets or side effects. Checks the final
armv7 executable so a stale object/bundle cannot silently remove Mac audio.
"""
from pathlib import Path
import sys

NEEDED={
 b'V2_BIND_OK': 'native V2 pairing/binding',
 b'V2_COMMIT_POSITION': 'accurate two-phase audio commit',
 b'V2_NATIVE_PROGRESS': 'native LTAVPlayer heartbeat safety',
 b'V2_CLOCK_RECOVERED': 'signed clock refresh',
 b'V2_AUTO_SYNC state=': 'automatic synchronization feedback',
 b'V2_TERMINATION confirmed': 'audio session termination handling',
}
def check(path):
 data=Path(path).read_bytes()
 if not data.startswith(b'\xce\xfa\xed\xfe'):
  raise ValueError('not a little-endian Mach-O armv7 bundle')
 missing=[label for marker,label in NEEDED.items() if marker not in data]
 if missing:raise ValueError('missing required V2 audio: '+', '.join(missing))
 return True

if __name__=='__main__':
 if len(sys.argv)!=2:raise SystemExit('Usage: check-v2-audio-build.py <Jellyfin binary>')
 try:
  check(sys.argv[1])
 except (OSError,ValueError) as e:
  raise SystemExit('REJECTED V2 AUDIO GUARD: '+str(e))
 print('V2 AUDIO BUILD GUARD PASS')
