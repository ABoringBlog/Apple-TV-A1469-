# RetroReel3 / Jellyfin ATV3 v0.5.101-public1

**Unofficial, independent open-source Jellyfin client for jailbroken Apple TV 3 A1469 / AppleTV3,2.** Not affiliated with or endorsed by Apple or Jellyfin. Existing bundle identifier `org.jellyfin.atv3` is retained for in-place upgrades.

## What's new / 更新内容

- Libraries selection is now **two wide cards per row**, including correct Apple Remote focus movement, navigation to Refresh/Sign out, and row scrolling.
- Initial movie / TV page publishes up to **10 items** promptly from a small 11-item lookahead request; remaining pages fill asynchronously without blocking selection or search. Explicit Refresh still queries Jellyfin.
- Native Core Animation poster / label scrolling with a shared 240 ms animation origin; title and year alignment fixed and no empty placeholder covers for short TV libraries.
- Posters fade in through native image layers (220 ms); title and year layers are reused instead of encoding another JPEG background on every row.
- On-device **maximum 1 GiB** persistent artwork + read-only catalog cache. Eviction priority: all cover images first, ordinary non-Archived backdrops second, Archived backdrops third, other metadata last. Album/video media files are not cached by this pool.
- Focus remains on selected Movies/TV library during background loading, and is held until the startup Restoring overlay has time to finish.
- Preserves V2 authenticated Mac audio control path, pause/resume/seek and video-buffer safety gating. Automatic AV synchronization is still being tuned separately; do not claim the physical ±40 ms goal has been measured or achieved.

## Real-device verification / 实机情况

The personal development variant was installed on AppleTV3,2 and its SHA-256 was checked against the built program. User accepted the animation, focus and loading behavior before two-column change. Two-column layout passed offline tests (579 UI, 269 unit/API, 461 session, 404 playback/subtitle assertions) and ARMv7 link/sign/build guard. **The public build differs from the tested private build only in its configurable bridge endpoint and its disabled diagnostic probe default, so it needs its own real-device validation.** No quantified frame-rate or physical AV-sync guarantee.

## Mac Audio Bridge requirement / 音频桥接依赖

The ATV3 client sends signed V2 audio control and timing to a separately deployed Mac audio service. **The service, pairing key, media files and runtime credentials are NOT included in this repository or release.** Video can run on the ATV3, but Mac audio requires a compatible bridge with valid pairing and 8899 listening. Installing the DEB alone does **not** magically provide Mac playback or sound.

The public build does NOT embed a real private-LAN host. Configure your own LAN Mac audio endpoint on ATV3 using a **credential-free** preferences plist:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>AudioBridgeURL</key><string>http://192.168.1.10:8899</string>
</dict></plist>
```

Save this as `/var/mobile/Library/Preferences/org.jellyfin.atv3.bridge.plist` with appropriate ATV3 permissions. Replace the example with your Mac's reachable IP and the audio server port. No password, pairing secret, or token belongs in this file. The fallback is `http://127.0.0.1:8899`, which intentionally does not target a developer's Mac. Pairing is configured separately by the bridge; there is no public one-click setup for that private integration.

## Install / 安装

1. Back up your currently working `.frappliance` directory and any local settings.
2. Download the ARMv7 `org.jellyfin.atv3_0.5.101-public1_iphoneos-arm.deb` and `SHA256SUMS` from this release, verify using `shasum -a 256 -c SHA256SUMS`.
3. Transfer the package with SCP to the jailbroken Apple TV 3, install with `dpkg -i /path/to/package.deb`, then restart the AppleTV process when not watching video. Do not install on unsupported Apple TV generations.
4. Sign in to your own Jellyfin server. Configure the optional Mac bridge separately as noted above. Both network services should be on a trusted LAN.

## Developer build / 编译

On a Mac with the appropriate Theos / legacy iOS SDK and the pinned project tools:

```sh
make test
make test-ui
make test-session
make test-playback
make shell
```

The source does not contain developer NAS mount paths, personal API credentials or a real LAN bridge address. It uses the original package identifier for upgrades. The optional diagnostic probe uses loopback-only origin by default.

## IP, legal and privacy notices / 法律与隐私

This is an independent implementation under the repository's **MIT license**; copyright and license notices in third-party components must continue to be observed. Apple trademarks, Jellyfin trademarks and logos remain the property of their respective owners, and this work is not official or endorsed. Users are responsible for permission to access Jellyfin media and for compliance with local copyright and device-software rules. No copyrighted movies, subtitles, Jellyfin server accounts, NAS paths, private logs or audio bridge pairing keys are distributed in this release. No statement of "zero legal risk" is made.
