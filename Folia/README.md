# Folia for Apple TV 3 (A1469) — v44 source preview

[中文说明](README_ZH.md) · [Upstream Folia](https://github.com/chthollyphile/folia-major)

> **Mac Bridge required — NOT a standalone Apple TV music client.** The Apple TV 3 does **not** execute Folia/Electron. A **separately patched, dedicated Folia instance running on a Mac** renders the original Folia interface and streams H.264 video and PCM audio over the local network. The Apple TV 3 only presents/decodes this stream and sends remote actions back to the Mac. Installing the ATV appliance alone produces no working UI.

## Status and limitations

- Source snapshot: **v44 / 2026-10-15**, based on the Folia 0.7.18 Mac adaptation.
- Verified on **jailbroken Apple TV 3 Rev A / A1469 / AppleTV3,2, Apple TV Software 7.9 (12H1006)** with a Mac running the dedicated patched Folia desktop app.
- Real-hardware validation: opening Folia, displaying 1080p30 H.264, leaving to ATV Home and suspending **the same Mac process**, then reopening/resuming were verified.
- **Public configuration and build artifacts are not yet independently tested on another machine.** This is a developer-source preview, **not a plug-and-play release**.
- The Mac must be powered on, logged in and awake on the same trusted LAN. This does not work when the Mac is off or asleep.
- Folia's original visible desktop app is distinct from the dedicated Mac bridge instance. This repository does **not** distribute a signed/notarized Folia desktop app, its patched `app.asar`, a full ready-made Electron build, login state, copyrighted Apple SDKs or personal binaries.
- Native video is TCP H.264 Main L4.0, **1920×1080 at 30 fps**, scaled from Folia's 1280×720 renderer. **Not AirPlay, HLS, a web wrapper, or native Folia rendering on ATV.**
- Audio is sent via a dedicated FA01 PCM channel; depends on the required Folia-side WebAudio capture hooks.
- The implementation is experimental and tied to old private BackRow APIs. No support is promised for other Apple TV hardware or firmware.

## Components

| Directory | Responsibility |
| --- | --- |
| `ATV/Sources/` | Native BackRow FRAppliance, media decode, audio, remote input, lifecycle |
| `ATV/FoliaDirect.frappliance/` | App metadata + artwork; **edit `FoliaBridgeHost`** before deploying |
| `Scripts/build_atv.sh` | Locally compiles/signs a configurable ARMv7 appliance; no prebuilt executable published |
| `Mac/Bridge/` | Electron Direct streaming, AVCC worker, VideoToolbox C encoder, navigation/audio hooks |
| `Mac/Supervisor/` | On-demand Mac lifecycle service; `SIGSTOP` suspend / `SIGCONT` resume and cold-start |
| `Scripts/` | Build ATV appliance and Mac native encoder, configure launchd supervisor |

## Prerequisites

1. Jailbroken Apple TV 3 A1469 with root SSH, ability to install a native `.frappliance`, and a compatible BackRow host.
2. A Mac with the **dedicated, patched Folia 0.7.18 Electron application**, built separately from [Folia upstream](https://github.com/chthollyphile/folia-major). **Stock Folia cannot serve this plugin.**
3. Same trusted LAN: Mac IPv4, Apple TV IPv4, and accessible TCP **18782** (control), **18783** (supervisor), **18786** (FV01 H.264), **18787** (FA01 PCM).
4. To build ARMv7: macOS with Xcode iPhoneOS SDK and a compatible `ldid` signing tool; to build native encoder: macOS VideoToolbox/Accelerate frameworks.

## Building and deployment

See [SETUP.md](SETUP.md). Basic overview:

```sh
# From Folia/
./Scripts/build_atv.sh 192.168.1.20
./Scripts/build_mac_encoder.sh
# Install a separately patched dedicated Mac Folia app before doing this:
./Scripts/install_mac_supervisor.sh 192.168.1.20 192.168.1.30 "$HOME/Applications/FoliaATV3.app"
```

The first argument is **your Mac LAN IPv4**, second is **your Apple TV LAN IPv4**; these addresses are examples, not defaults or addresses of the author. The ATV build output is `build/FoliaDirect.frappliance`. The `install_mac_supervisor.sh` command only installs the small supervisor/encoder; it does **not** generate or patch the Electron app. Read [Mac integration](Mac/INTEGRATION.md) first.

When Folia is opened on ATV, it calls the Mac supervisor's `/start` endpoint. The supervisor resumes the preserved Folia process if suspended, otherwise starts the dedicated app. On leaving to Home it issues `/suspend`, pausing the Mac Folia process tree instead of terminating it. A disabled Mac or a missing patched Folia app cannot be compensated for on the Apple TV.

## Privacy and security

This public directory intentionally excludes personal addresses, account cookies, passwords, SSH keys, recordings, local runtime logs, crash dumps, saved sessions and user-profile data. LAN IPs are supplied locally during setup; **never commit populated configuration files or logs**. The control protocol is intended only for a **trusted LAN**. It uses an IP allowlist and is **not** an internet-safe authenticated service: **do not port-forward** TCP 18782/18783/18786/18787 or expose them to public networks.

## Credit and licensing

This is an **unofficial community integration**. Folia is developed by [chthollyphile and contributors](https://github.com/chthollyphile/folia-major) and distributed under **GNU AGPL-3.0**. This integration preserves upstream attribution and ships an AGPL-3.0 license copy (see [LICENSE](LICENSE)). Folia name, branding and original project remain with their respective owners. No affiliation, endorsement or official upstream support is implied.

This source preview includes only selected integration files; it is **not** a complete source archive for the modified dedicated Folia Electron application. If distributing a modified Folia desktop binary or providing the modified app as an AGPL-covered network service, you must also meet the AGPL corresponding-source obligations for that covered program. Do not distribute the private Mac app bundle or repacked ASAR as though it were a clean public release.
