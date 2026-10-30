# RetroReel3 / Jellyfin ATV3 v0.5.102-public1

**Independent, unofficial native Jellyfin client for jailbroken Apple TV 3 (A1469 / AppleTV3,2). Not affiliated with Apple or Jellyfin.**

## Changes / 更新内容

- Four Library covers per row / 每行四个 Library, with matching horizontal/vertical focus, native images, and selection animation.
- Integrates newer browser, remote-navigation, subtitle and playback-exit lifecycle source updates from the Mac development tree.
- The developer's LAN endpoints are not embedded in released sources or binaries. Diagnostic probe URLs are loopback-only.
- No media library contents, login data, pairing key, private local preferences, personal logs, or private Mac audio daemon are distributed.

## Audio is NOT standalone / 声音依赖 Mac

**Apple TV 3 handles native UI/video, but this build's audible playback depends on a separate Mac running the compatible ATV3 Audio Bridge.** This is not a standalone HDMI-audio solution. Keep the Mac awake, ensure compatible bridge software is running, and complete private pairing on a trusted LAN. Neither the privately deployed Mac bridge program nor its keys/credentials are included in the public repository or GitHub release. Without the bridge, video may work but the intended Mac audio will not.

**ATV3 本机负责 UI 和视频，声音依靠另一台 Mac 上的 ATV3 Audio Bridge 运行和输出。** 需要正常运行的 Mac、兼容服务和有效配对。公开安装包不包含私人桥接服务、配对密钥、Jellyfin 账户或媒体。仅安装 DEB 不保证有声音；音画同步和长期稳定性尚未量化保证。

### Mac audio endpoint setup / 桥接地址

On your own ATV3 create /var/mobile/Library/Preferences/org.jellyfin.atv3.bridge.plist containing ONLY a configurable address:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>AudioBridgeURL</key><string>http://192.168.1.10:8899</string>
</dict></plist>
```

Replace the example with your Mac's reachable private IPv4 and bridge port; do not add pairing secrets. Only RFC1918 IPv4/loopback endpoints are allowed by the fast transport. If missing or invalid, the client uses http://127.0.0.1:8899, not the developer's network. Pairing must be completed separately; this release does not supply a general-purpose bridge installer. Never expose the bridge port to the public internet.

## Installation

1. Back up your existing device appliance and preferences.
2. Download org.jellyfin.atv3_0.5.102-public1_iphoneos-arm.deb and SHA256SUMS from the release and verify the digest.
3. Transfer to your own jailbroken Apple TV 3 and install with dpkg -i. Restart the AppleTV process safely when idle.
4. Log in to your own Jellyfin server. Configure your own compatible paired Mac Bridge for sound.

Package ID org.jellyfin.atv3 is kept for upgrades. Other Apple TV generations and system versions are not validated. The public build is experimental: no claim of verified multi-hour stability, independently measured A/V synchronization, or fully portable audio-bridge compatibility is made.

## Privacy, copyright and legal

MIT license covers original code authored for this project. Proprietary Apple firmware, SDKs, and system binaries are not included. Apple, Jellyfin, third-party trademarks/logos and their copyrights remain with their holders; the project is unofficial. Use only media you are authorized to access, honor license obligations, and comply with relevant rules on modifications to your own devices. No representation that redistribution carries zero legal risk is made. Do not disclose your device logs or pairing files in public bug reports.
