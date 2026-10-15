# Setup and build

**Developer preview.** These scripts configure and build the open ATV receiver and Mac native encoder/supervisor. They **do not** independently build the required modified Folia desktop app. First read [Mac/INTEGRATION.md](Mac/INTEGRATION.md).

## 1. Prerequisites

- Apple TV 3 A1469 (AppleTV3,2), software 7.9 / 12H1006, jailbroken with root SSH.
- macOS machine with Xcode/iPhoneOS SDK, command-line `clang`, and your installed `ldid` tool.
- A separate dedicated patched Folia 0.7.18 desktop app. The ordinary Folia app is not sufficient.
- A trusted home LAN. Example only: Mac 192.168.1.20; Apple TV 192.168.1.30.
- For Mac auto-resume, the Mac user must be logged in, the Mac must stay awake, and the login launch agent must be running.

## 2. Build the ATV native appliance

```sh
cd Folia
./Scripts/build_atv.sh 192.168.1.20
```

`build/FoliaDirect.frappliance/Info.plist` contains the chosen Mac IP under `FoliaBridgeHost`. A local build creates and signs the ARMv7 binary after setting this IP. No prebuilt ATV executable is published in this source preview.

**Install only after you have a working Mac bridge.** Example for a test device with `root` SSH access:

```sh
ATV_IP=192.168.1.30
scp -r build/FoliaDirect.frappliance root@"$ATV_IP":/var/tmp/
ssh root@"$ATV_IP" '
  mkdir -p /Applications/FoliaDirect.frappliance
  cp -R /var/tmp/FoliaDirect.frappliance/. /Applications/FoliaDirect.frappliance/
  ln -sfn /Applications/FoliaDirect.frappliance \
    /Applications/AppleTV.app/Appliances/FoliaDirect.frappliance
  killall AppleTV
'
```

Back up an existing `/Applications/FoliaDirect.frappliance` before installing. Restart only the AppleTV application host; do not erase AppleTV global icon caches.

## 3. Build the Mac VideoToolbox encoder

```sh
./Scripts/build_mac_encoder.sh
```

The output is `Mac/Bridge/folia_native_vt1080_encoder` (macOS, **not** ARMv7). It reads 1280×720 BGRA, scales to 1920×1080 and emits length-prefixed AVCC H.264 access units. The paired `atv3EncoderWorker.cjs` expects **framed AVCC**, not older Annex-B-only output.

## 4. Install the Mac on-demand supervisor

After creating/configuring your **separate modified Folia Electron app**:

```sh
./Scripts/install_mac_supervisor.sh \
  192.168.1.20 192.168.1.30 \
  "$HOME/Applications/FoliaATV3.app"
```

The script configures a per-user launchd LaunchAgent and exports `FOLIA_ATV3_MAC_HOST`, `FOLIA_ATV3_ATV_IP`, `FOLIA_ATV3_APP`, and `FOLIA_ATV3_NATIVE_ENCODER`.

Local read-only diagnostic:

```sh
curl --fail http://192.168.1.20:18783/status
```

Lifecycle:
- ATV Folia entry -> `/start?session=...` -> resume suspended Folia process tree or cold start.
- ATV exit -> `/suspend?session=...` -> SIGSTOP verified dedicated Folia process family (never entire macOS process group).
- Reopening -> SIGCONT and stream reconnect. Session IDs prevent delayed stale requests from wrongly waking Folia.
- When the app crashes or the Mac is restarted, its process memory is gone; the next open cold-starts a new instance.

## 5. Build/runtime limitations

The Mac's dedicated Folia executable must integrate the Bridge, background/offscreen window, renderer navigation and audio capture described in [Mac integration](Mac/INTEGRATION.md). This source preview contains components, **not an automatic upstream patcher** and not a full corresponding source archive of the customized Folia desktop executable. The Mac bridge streams only while that dedicated application and its encoder are running.

Never publish filled-in configuration, logs, Electron user data, music service login tokens or personalized ASAR bundles. Keep `18782-18787` firewalled from untrusted networks.
