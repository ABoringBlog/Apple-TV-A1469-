# Configuration and build

## Keys: never commit real values

Copy `Sources/CloudPhotos/CloudPhotosPublicConfig.h.example` to ignored `CloudPhotosPublicConfig.h`. Replace both `REPLACE_WITH_...` values using **independently generated 64-character hex strings**, matching the NAS secret files. Use Python's `secrets.token_hex(32)` locally; do not print keys in shared logs.

* The API key matches `ATV_PHOTOS_SECRET_FILE` for `server.py`, `/etc/atv3-icloud-photos/api.token` for `direct.py`/`video.py`. Ensure these references point to the same private credential in your deployment.
* Native input key matches `ATV_PHOTOS_INPUT_SECRET_FILE` (default `/etc/atv3-icloud-photos/input_crypto.key`). Only send native input on a trusted local network with strict ACLs. No public exposure or credential interception support is intended.
* `direct.py` capture access also supports `/etc/atv3-icloud-photos/capture.key`, generated independently.
* Copy the example header **only locally**: any privately built ATV binary embeds the key. Do not distribute this binary with live secrets, and do not rely on obscurity of the embedded key as strong authentication.

## IP addresses and ports

The checked-in source uses RFC 5737 documentation-only example addresses (`192.0.2.24`, `192.0.2.15`, `192.0.2.41`). Replace the NAS, Mac and ATV example addresses with local IPs in a **private working copy**, or adapt the application for runtime configuration. Keep real topology out of Git history. NAS API and direct service use ports 18790/18793, H.264 direct stream uses 18792, optional HLS 18791, capture ingest 18794. Mac audio uses SSH and the same video health endpoint.

## Build assets and proprietary SDK

`make SDKROOT=/path/to/a/compatible/legally-obtained/sdk` produces an armv7 `.frappliance` in `build/`. This repository does **not** contain Apple's SDK, headers from closed/private frameworks, firmware, jailbreak binaries or official Apple Photos icon. The Makefile does not ship an installation utility. Generate an independently created `.png` icon for your own install, if desired. Reuse of BackRow private APIs and installation on modified Apple TV systems are experimental; verify your applicable law and any agreements separately.
