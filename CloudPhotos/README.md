# Cloud Photos Bridge for Apple TV 3 (A1469)

**Unofficial, self-hosted compatibility project.** This is not the Apple Photos app, not an iCloud service, and not affiliated with, endorsed by, or supported by Apple. Apple, Apple TV, iCloud and Photos are trademarks of their respective owners. No Apple copyrighted icon, firmware, SDK, login material or proprietary framework is included.

> **Architecture, important:** This is **not** a standalone ATV3 iCloud app. Its browser and photo rendering run on a **NAS Docker container**, video frames are transferred to the **Apple TV 3**, and **audio is separately captured by a Mac bridge and played through that Mac's speakers**. Without the NAS and Mac audio bridge, the ATV3 plugin cannot provide the complete experience. No iCloud credentials should ever be placed in this GitHub repository.

## System architecture

```text
Apple iCloud Photos website (user signs in interactively with their own Apple Account)
           |
NAS / OpenMediaVault / Debian
  Docker: linuxserver/chromium (persistent private browser profile)
  Chromium + Wayland -> pixelflux capture -> H.264 ingest -> NAS direct.py
  NAS server.py: browser CDP interaction, focus/navigation, native text input
           |                               |
           | H.264 FV01/TCP + controls     | PulseAudio output.monitor (s16le / 44100 Hz / stereo)
           v                               v
Apple TV 3 (A1469)                    NAS parec -> SSH -> Mac mac_icloud_audio_relay.py
BackRow CloudPhotos plugin                         -> native macOS AudioQueue PCM player
1080p video display + remote controls               -> Mac speakers (not ATV/HDMI audio)
```

The video signal and the audio signal follow **separate paths**. The NAS does the heavy browser, rendering and video encoding work; the A5 ATV3 receives a compatible stream and renders remote focus/navigation. The Mac performs audio output with its own clock and a bounded queue. No claims of perfect synchronization on other networks or devices are made.

## Hardware / requirements

* A jailbroken **Apple TV 3 Rev A A1469 / AppleTV3,2**, capable of installing a self-built BackRow `.frappliance`; compatible armv7 cross-compiler and legally obtained suitable SDK. We do **not** distribute an SDK, Apple frameworks, jailbreak tool or Apple binaries.
* A **NAS running Debian/OpenMediaVault and Docker** with persistent storage and sufficient CPU/network throughput for Chromium and H.264 encoding. Development environment used `lscr.io/linuxserver/chromium:latest`; pin your image to a tested digest in production.
* A **Mac** on the same trusted local network, running macOS with command line tools, Python 3, SSH client and working speakers; the reference output uses the Mac's native AudioQueue and **not** ATV HDMI or AirPlay.
* Working LAN connectivity; a user-owned Apple Account with access to iCloud Photos. Apple login and any required 2FA happen **in the NAS browser**, never in a repository script.
* Python modules on NAS: `websocket-client` (`import websocket`) and capture-specific `pixelflux`; Chromium DevTools Protocol; PulseAudio `pactl`/`parec`; H.264 encoding tools and associated libraries. Installation of `pixelflux` and the exact Docker/Wayland capture configuration are environment-specific and **not bundled**.

## Quick orientation / public repository layout

| Path | Runs on | Function |
|---|---|---|
| `Sources/CloudPhotos/` | ATV3 | Objective-C BackRow UI, native navigation and video receiver |
| `nas/server.py` | NAS host | Chromium CDP, remote navigation, auth/control bridge |
| `nas/direct.py` | NAS host | on-demand H.264 direct video service and connection health |
| `nas/video.py` | NAS host | legacy HLS path; direct stream is preferred |
| `nas/wayland_capture.py` | NAS/container capture environment | Wayland capture and H.264 ingest |
| `nas/pcm_source.sh` | Chromium Docker container | captures PulseAudio monitor raw PCM |
| `nas/cdp_proxy_private.py` | NAS Docker private network | private DevTools forwarding |
| `mac/mac_icloud_audio_relay.py` | Mac | supervises SSH PCM pipe and audio lifecycle |
| `mac/icloud_pcm_player.c` | Mac | native AudioQueue, bounded PCM playback and telemetry |
| `Resources/` | ATV3 bundle | package metadata, no Apple logo |

## How to deploy (reference integration, not a turnkey installer)

1. **Prepare a private NAS Chromium Docker environment.** Create persistent container config on the NAS (do not commit it), enable browser UI/Wayland and PulseAudio, and open `https://www.icloud.com/photos` manually. Sign in interactively and complete 2FA. Keep its browser profile, cookies and authentication entirely in private storage. Never expose DevTools (CDP) to the public internet. See [NAS deployment notes](docs/NAS-DOCKER.md).
2. **Install the NAS bridges.** On the NAS place `nas/server.py` and `nas/direct.py` in a private system directory (the latter imports `Browser` and `SPATIAL_JS` from `server.py`). Install required Python modules. Configure fresh random API, input-encryption and capture secrets in root-restricted files outside the Git tree; configure the private Chromium DevTools endpoint and host/container network. Add host services supervised by systemd according to your environment, and restrict bridge ports by firewall to ATV and Mac only. Refer to [configuration and protocols](docs/CONFIGURATION.md).
3. **Arrange the Wayland video capture.** Configure `nas/wayland_capture.py` alongside the running Chromium Wayland display, with the supported `pixelflux` integration, H.264 encoder and the ingest port expected by `direct.py`. The reference uses about 15 FPS H.264 for ATV3 hardware compatibility. This is an experimental, host-specific integration, **not** a preconfigured Docker Compose that works on an arbitrary NAS.
4. **Configure and build the ATV app.** Copy `Sources/CloudPhotos/CloudPhotosPublicConfig.h.example` to the ignored `CloudPhotosPublicConfig.h` and put **locally generated** matching 64-hex NAS API and native-input encryption keys inside. Update `192.0.2.24` NAS and `192.0.2.15` Mac placeholder addresses in the public source (or in a private build working copy) to your local devices; do **not** commit values. Set `SDKROOT` to a legitimately available compatible SDK. Run `make SDKROOT=/path/to/sdk`. A personally created 282x159 `AppIcon.png` may be added to the build bundle; no Apple Photos icon is provided or licensed. See [ATV configuration](docs/CONFIGURATION.md).
5. **Configure Mac audio bridge.** Compile `mac/icloud_pcm_player.c` with the macOS system frameworks (example below); configure the script's NAS IP and SSH identity via environment variables; grant SSH access to invoke `docker exec` on the NAS only on your trusted network. Ensure the container provides `parec`/PulseAudio `output.monitor`; install and start the macOS LaunchAgent **only after adapting paths and user IDs**. The audio supervisor uses `/health` from the video bridge and does **not** automatically run unless configured. See [audio notes](docs/MAC-AUDIO.md).
6. **Validate locally.** Confirm NAS `/health` active and ATV connected, browser display visible, remote navigation, 1080p H.264 decoding, and Mac-only audio. Test photo/video pause/resume, seeking, app exit/re-entry, short network reconnections, audio lag and private login. No server-side login automation or downloaded iCloud images are required.

**Mac example:** `clang -O2 -std=c11 mac/icloud_pcm_player.c -framework AudioToolbox -framework CoreAudio -lm -o mac/icloud-pcm-player` (review your installed macOS compiler flags). Set `ATV_PHOTOS_NAS_IP` and `ATV_PHOTOS_SSH_KEY` when launching the relay. Adapt the player's binary path in the Python supervisor if you change its location.

**Known constraints:** No ready-to-use Compose file or generic installer is bundled; Wayland/pixelflux and network interface mapping are installation-specific. This snapshot documents one working architecture, not a security-reviewed cloud product. NAS is required for video; Mac is required for **audible audio**. The original deployments use private services/configuration not suitable for redistribution.

## Security / privacy

* The public tree contains **no Apple ID, password, 2FA codes, browser cookies, authentication profile, client key or captured photo/video/audio**.
* Generate unique secrets for each install, keep them in permissions-restricted private configuration. Avoid committing `.env`, token files, binaries that embed tokens, real addresses or telemetry. Rotate production credentials if previously copied into any published Git tree.
* Only expose needed ports on a trusted LAN. CDP gives broad control of the logged-in browser: never expose port 9222 or the CDP proxy to untrusted peers. Use TLS/VPN if crossing trusted boundaries.
* The ATV3-to-NAS legacy protocol uses static client keys embedded in the privately built client and HTTP over LAN; **do not treat this as internet-safe or resistant to compromise of the ATV client**. Use firewall rules and a dedicated isolated network.
* Actual Apple Account authentication takes place in the user-managed Chromium browser; the bridge is not an Apple credential provider. User should review Apple's current terms before using nonofficial integrations.

## Legal / attribution

This repository is an independent interoperability experiment. **No ownership or license to Apple's website, SDKs, artwork, trademarks, private frameworks or services is conveyed.** Nothing here guarantees that a user's build/usage complies with every applicable law or Apple service agreement. The original work in this folder is distributed subject to the repository's MIT license; independent third-party components (Chromium, FFmpeg, LinuxServer image, PulseAudio, pixelflux and other dependencies) retain **their own** licenses; install them from authorized sources. No copies are shipped here. A legal opinion and third-party provenance review may be needed before distributing binaries.

## Status

Experimental source-only release. Reported working on the author's privately configured hardware for browsing, video and Mac-speaker audio. Not an official Apple client and **not guaranteed portable**. See [limitations and verification](docs/STATUS.md).
