# NAS + Docker deployment details

**The NAS is the application host.** ATV3 does not host the iCloud website. The reference NAS is Debian/OpenMediaVault, running a persistent `lscr.io/linuxserver/chromium:latest` Docker container on an isolated private Docker network. Its Chromium signs in to `icloud.com/photos`; the desktop is captured from Wayland, encoded as H.264, and bridged to ATV over the LAN. The NAS web/CDP bridge additionally translates ATV3 remote actions to browser navigation.

## Services and data flow

1. Docker Chromium: official website, private persistent browser profile, native audio through PulseAudio. Keep host bind mounts and credentials **outside** the public repository. Do not expose KasmVNC/browser management to the internet.
2. Private CDP proxy: container's CDP 9222 is forwarded only through an isolated address and host-local forwarding; `server.py` connects with `websocket-client`. Exposing CDP permits reading session information, so IP firewalling alone is not a complete threat model.
3. NAS `server.py`: remote navigation, cursor placement, viewer input and page state. It reads API secret and native-input decryption secret from restricted files, not this repository.
4. NAS `direct.py`: health/control API default 18793, direct H.264 TCP default 18792, private capture ingest default 18794. It uses `from server import Browser, SPATIAL_JS`, so install `server.py` as that exact module in same directory. No HLS required for direct playback.
5. Capture `wayland_capture.py` and its `pixelflux` dependency: captures the Wayland display, encodes H.264, sends to the ingest socket. This dependency and the exact display/video/input setup must be installed and configured for your host/container version. It is not bundled, and reproducibility on other NAS setups is not yet verified.
6. PCM audio: container PulseAudio `output.monitor` → `parec` via `pcm_source.sh` → SSH stdout to Mac AudioQueue. The Mac, not NAS or ATV, drives the physical speakers.

## Reference port map (configure firewall; do not blindly publish)

| Port | Purpose | Trust boundary |
|---|---|---|
| 18790/TCP | NAS browser navigation/input HTTP API | ATV and Mac only, API token |
| 18792/TCP | direct H.264 TCP stream | ATV only / trusted LAN |
| 18793/TCP | direct video control/health | ATV and Mac / trusted LAN |
| 18794/TCP | private encoded-frame ingest | Docker to NAS only |
| 9222/TCP | Chromium DevTools Protocol | container private / loopback **only** |
| 22/TCP | SSH PCM transport command | Mac to NAS on private LAN |

Legacy 18791/TCP HLS may exist in the `video.py` implementation but is **not** needed in the default direct H.264 path. No public WAN exposure is recommended.

## Setup caveats

There is deliberately **no fabricated one-click `docker-compose.yml`**: the reference installation depends on a specific browser image, custom networking, Wayland socket, pixelflux module, H.264 ingest integration and audio sink. Verify Docker image's existing command/entrypoint and environment before changing anything. Install dependencies legally and independently; protect Apple Account cookies, stored browser profile and NAS keys. A user must provide their own network IPs and credentials.

The NAS is required to browse or render photos; this is not an ATV3-local photo engine.
