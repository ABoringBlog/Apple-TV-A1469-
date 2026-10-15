#!/bin/zsh
# Build Folia Direct for jailbreak Apple TV 3 (ARMv7/iOS 8).
set -euo pipefail
ROOT="${0:A:h:h}"
if [[ "$#" -ne 1 ]]; then
  echo "Usage: $0 MAC_LAN_IPV4" >&2
  exit 2
fi
MAC_IP="$1"
/usr/bin/python3 - "$MAC_IP" <<'PY'
import ipaddress,sys
try:
  ipaddress.IPv4Address(sys.argv[1])
except ValueError:
  raise SystemExit("Invalid Mac IPv4")
PY
OUT="$ROOT/build/FoliaDirect.frappliance"
mkdir -p "$ROOT/build"
rm -rf "$OUT"
cp -R "$ROOT/ATV/FoliaDirect.frappliance" "$OUT"
export FOLIA_ATV3_OUT_PLIST="$OUT/Info.plist"
export FOLIA_ATV3_MAC_HOST="$MAC_IP"
/usr/bin/python3 - <<'PY'
import os,plistlib,pathlib
p=pathlib.Path(os.environ['FOLIA_ATV3_OUT_PLIST'])
d=plistlib.loads(p.read_bytes())
d['FoliaBridgeHost']=os.environ['FOLIA_ATV3_MAC_HOST']
p.write_bytes(plistlib.dumps(d,fmt=plistlib.FMT_XML,sort_keys=False))
PY
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CLANG="$(xcrun --find clang)"
"$CLANG" -target armv7-apple-ios8.0 -isysroot "$SDK" -fno-objc-arc -O2 -dynamiclib \
  -Wl,-install_name,/Applications/FoliaDirect.frappliance/FoliaDirect \
  -framework Foundation -framework UIKit -framework AVFoundation \
  -framework CoreMedia -framework QuartzCore -framework AudioToolbox \
  "$ROOT"/ATV/Sources/{FoliaDirect.m,FoliaDirectRemote.m,FoliaDirectStream.m,FoliaDirectAudio.m} \
  -o "$OUT/FoliaDirect"
SIGNER="${LDID_BIN:-ldid}"
if ! command -v "$SIGNER" >/dev/null; then
  echo "Missing ldid; set LDID_BIN to a working signing tool." >&2
  exit 3
fi
"$SIGNER" -S "$OUT/FoliaDirect"
chmod 755 "$OUT/FoliaDirect"
echo "Created $OUT; configured Mac IP $MAC_IP."
