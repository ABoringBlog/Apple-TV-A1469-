# Integration of the dedicated Mac Folia application

**Important:** the Apple TV 3 application is a native **receiver**, not a full Folia port. It depends on a **dedicated patched Folia Electron desktop application running on the Mac**. The official Folia 0.7.18 installation alone does not include the frame capture, remote-control and PCM hooks used here. This directory is a source-component preview, not a downloadable complete patched Folia distribution.

## Required Mac runtime

- Source base: [Folia upstream](https://github.com/chthollyphile/folia-major) — 0.7.18-era Electron desktop application, licensed AGPL-3.0.
- A distinct dedicated Folia application bundle (e.g. `~/Applications/FoliaATV3.app`) separate from the normal Folia app, with its own Electron `userData` and single-instance profile. The normal `/Applications/Folia.app` need not be modified.
- Dedicated Electron window configured for offscreen capture: 1280×720 compositor, `webContents.on('paint', ...)` image readback, and the original Folia renderer with its visualizer/lyrics. Use the source component `atv3DirectBridge.cjs` from this directory.
- On app initialization, create the dedicated window and call:
  ```js
  const {startBridge} = require('./atv3DirectBridge.cjs');
  startBridge(dedicatedWindow, app, ipcMain);
  ```
  This is an **integration outline**, not a drop-in patch: Folia's Electron entrypoint and offscreen window initialization must be adapted to expose the required objects. Configure the correct input renderer, audio capture and IPC before invoking `startBridge`.
- The Bridge creates a `worker_threads` encoder (file name `atv3EncoderWorker.cjs`) which starts the native `folia_native_vt1080_encoder` configured via environment variable `FOLIA_ATV3_NATIVE_ENCODER`. The encoder produces **length-prefixed complete AVCC access units**, unlike the older Annex-B test encoders. Do not mix these formats.
- The renderer needs the Folia-specific navigation/focus hooks `atv3TvNavigation.js`, `atv3OriginalUIRemote.js`, and `atv3TvServiceMenu.js` integrated with its page lifecycle. The control handler invokes `window.__atv3TVNavigation` for directional/select/back operations. It cannot work if the renderer hooks were never installed.
- PCM output additionally requires installing `atv3DirectAudioCapture.js` as the correct WebAudio hook and forwarding samples to Electron `ipcMain` via `atv3-audio-pcm`; see the source and FA01 stream receiver. This is **separate** from the native FV01 video stream. A UI-only bridge may display a picture without sound.
- The Mac supervisor is a **separate** Python process managed by per-user launchd. It starts the dedicated app, sends SIGSTOP to verified Folia process and its child processes when exiting ATV, and sends SIGCONT to the same process on next entry. Mac sleeps/reboots erase this suspended process state; reopening then cold-starts a new dedicated Folia.

## Runtime/environment contract

Use these environment variables for the dedicated Folia app and Bridge:

| Environment variable | Role |
| --- | --- |
| `FOLIA_ATV3_MAC_HOST` | Mac IPv4 on trusted home LAN (bind address) |
| `FOLIA_ATV3_ATV_IP` | Apple TV IPv4 on the same LAN (allowlist) |
| `FOLIA_ATV3_NATIVE_ENCODER` | Absolute path to locally compiled Mac VideoToolbox encoder |
| `FOLIA_ATV3_DIRECT=1` | Enable the dedicated direct-stream mode |
| `FOLIA_ATV3_FORCE_PAINT=1` | Request offscreen paint updates |
| `FOLIA_ATV3_RENDER_FPS=45` | Target offscreen Folia UI frame cadence |
| `FOLIA_ATV3_CAPTURE_THROTTLE_MS=24` | Avoid unbounded capture CPU load |
| `FOLIA_ATV3_ENCODER_WORKER=1` | Use detached encoder worker |
| `FOLIA_ATV3_WORKER_NETWORK=1` | Worker owns FV01 video network server |
| `FOLIA_ATV3_NATIVE_VT=1` | Use low-latency VideoToolbox encoder |

`Mac/Supervisor/folia_supervisor.py` supplies these variables when it starts the dedicated app. The local Mac Folia build must have all bridge code integrated in its Electron main/renderer/preload scripts **before** the supervisor can make it ready.

`FoliaBridgeHost` in the installed ATV `Info.plist` must match `FOLIA_ATV3_MAC_HOST`. The ATV app calls `18783/start` and `18783/suspend`, receives FV01 H.264 over `18786`, FA01 PCM over `18787`, and POSTs remote commands to `18782/control`.

## What this snapshot does *not* claim

- It does **not** include a reproducible complete Folia Electron `app.asar` patch or a finished modified Folia desktop bundle. Rebuilding that requires integrating against the compatible upstream Folia source and producing corresponding modified source in compliance with AGPL.
- It does **not** guarantee that this public code runs unchanged on any Mac or arbitrary Folia release. Only one dedicated private Folia 0.7.18-based test app was physically verified.
- It does **not** authorize distribution of personal music credentials, session Cookies, media files, runtime logs, private keys, Apple private frameworks or SDK binaries.
- It does **not** make network control ports internet-safe: run exclusively on a trusted network. Add stronger authentication before using an untrusted LAN.

The original Folia source is maintained by [chthollyphile and contributors](https://github.com/chthollyphile/folia-major); this is an unofficial adaptation and does not imply upstream support.
