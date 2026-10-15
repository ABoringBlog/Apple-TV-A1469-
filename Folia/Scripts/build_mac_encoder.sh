#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="$ROOT/Mac/Bridge/folia_native_vt1080_encoder"
xcrun clang -O2 -Wall -Wno-unused-function \
  "$ROOT/Mac/Bridge/folia_native_vt1080_encoder.c" \
  -framework VideoToolbox -framework CoreVideo -framework CoreMedia \
  -framework Accelerate -framework CoreFoundation -o "$OUT"
chmod 755 "$OUT"
echo "Built Mac native encoder: $OUT"
