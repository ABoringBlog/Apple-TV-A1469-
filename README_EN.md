# Apple TV 3 Modernization

[← Bilingual README](README.md) · [Clock English README](Clock/README_EN.md) · [Weather English README](Weather/README_EN.md) · [Radio English README](Radio/README_EN.md) · [CloudTune English README](CloudTune/README_EN.md) · [Phone Remote & Text Input](PhoneRemoteInput/README_EN.md)

Independent open-source applications for **jailbroken Apple TV 3 (A1469 / AppleTV3,2)**.

Each application is independently installable, has its own package ID and release, and is completely free. Sponsorship through GitHub Sponsors is optional and does not unlock paid features.

## Available applications

| App | Description | Current release |
| --- | --- | --- |
| **RetroReel3** | Independent, unofficial native Jellyfin client | [v0.5.85-brand1](https://github.com/ABoringBlog/Apple-TV-A1469-Jellyfin-Client-and-some-plugins/releases/tag/v0.5.85-brand1) |
| **Clock** | Native standalone Apple TV 3 clock | [clock-v0.1.5](https://github.com/ABoringBlog/Apple-TV-A1469-Jellyfin-Client-and-some-plugins/releases/tag/clock-v0.1.5) |
| **Weather** | Native weather in English or Chinese; requires Mac ATV3Bridge 24/7 | [weather-v1.0.0-public2](https://github.com/ABoringBlog/Apple-TV-A1469-Jellyfin-Client-and-some-plugins/releases/tag/weather-v1.0.0-public2) |
| **Radio** | Native Internet Radio in English or Chinese; requires Mac ATV3Bridge Radio | [radio-v0.3.1-public2](https://github.com/ABoringBlog/Apple-TV-A1469-Jellyfin-Client-and-some-plugins/releases/tag/radio-v0.3.1-public2) |
| **CloudTune** | Independent music client; 1.1 adds phone-input search integration | [cloudtune-v1.1.0-public2](https://github.com/ABoringBlog/Apple-TV-A1469-Jellyfin-Client-and-some-plugins/releases/tag/cloudtune-v1.1.0-public2) |
| **[Folia for Apple TV 3 (Mac Bridge)](Folia/)** | Unofficial ATV3 receiver; **requires a separately modified Folia desktop app on an awake Mac**; not standalone | [Source preview](Folia/) |
| **Phone Remote & Text Input** | iPhone Control Center Remote + keyboard input for ATV3 | [phone-remote-input-v1.0.0-public1](https://github.com/ABoringBlog/Apple-TV-A1469-Jellyfin-Client-and-some-plugins/releases/tag/phone-remote-input-v1.0.0-public1) |

> **Weather runtime requirement:** the current Weather app requires a Mac running ATV3Bridge continuously (24/7) for fresh live data.

> **Radio runtime requirement:** the current Radio app requires a Mac running ATV3Bridge Radio continuously for station directory, search, favorites, and recent-history data.

> **CloudTune runtime requirement:** CloudTune 1.1 requires a Mac running CloudTune Bridge continuously plus a compatible local upstream API. iPhone Remote keyboard/search integration uses the separate Phone Remote & Text Input module.

> **Phone Remote & Text Input runtime:** the Mac emulates a Companion Link target and relays input to the ATV3 through an SSH tunnel and a loopback-only MobileSubstrate injector. Core remote and text-input paths have physical-device verification.

## RetroReel3

![RetroReel3 original app icon](Jellyfin.frappliance/AppIcon.png)

**RetroReel3 is an independent, unofficial native Jellyfin client for jailbroken Apple TV 3.**

It is built for the legacy BackRow environment and is not an AirPlay receiver, browser wrapper, or tvOS application. The project is not affiliated with or endorsed by Jellyfin or Apple.

### Compatibility

Tested target:

- Apple TV 3 A1469
- AppleTV3,2
- Apple TV Software 7.9
- Build 12H1006
- iOS 8.4.4 base system

The native playback baseline was verified on physical hardware. The rebranded 0.5.85-brand1 package has been independently rebuilt and tested offline, but that exact rebranded package has not yet completed a separate physical-device acceptance test.

Other Apple TV models, firmware builds, and jailbreak environments are not validated.

### Features

- Jellyfin server login
- Movie and TV library navigation
- Native Apple TV playback
- DirectPlay
- DirectStream / remux
- Server transcoding
- Playback controls
- Progress reporting and resume
- Audio-track selection
- Server-rendered subtitles
- External SRT support through the playback pipeline
- Internal subtitle handling through Jellyfin transcoding when required

Selecting subtitles may cause the server to transcode video depending on media and subtitle format.

### Download

Download the package and SHA256SUMS from:

**[RetroReel3 v0.5.85-brand1](https://github.com/ABoringBlog/Apple-TV-A1469-Jellyfin-Client-and-some-plugins/releases/tag/v0.5.85-brand1)**

### Installation

Requires:

- Jailbroken Apple TV 3
- Root SSH access
- dpkg
- A modern Mac or Linux computer for downloading the package

The legacy Apple TV 3 HTTPS stack may fail to connect directly to modern GitHub servers, so download the package on a computer and transfer it over SCP.

    scp org.jellyfin.atv3_0.5.85-brand1_iphoneos-arm.deb root@APPLE_TV_IP:/var/root/
    ssh root@APPLE_TV_IP 'dpkg -i /var/root/org.jellyfin.atv3_0.5.85-brand1_iphoneos-arm.deb && launchctl stop com.apple.frontrow && launchctl start com.apple.frontrow'

Replace APPLE_TV_IP with the local IP address of your Apple TV.

The package ID remains org.jellyfin.atv3, and the existing internal bundle path, principal class, and saved-session keys remain unchanged for upgrade compatibility.

### Build from source

Requires macOS, Xcode Command Line Tools, Python 3, and a compatible Theos/iPhoneOS SDK. Proprietary Apple SDKs are not distributed in this repository.

    make shell
    Scripts/package.sh build/iPhoneOS11.4.sdk-ios8.0/Jellyfin.frappliance build/package-local
    JF_PACKAGE=build/package-local/org.jellyfin.atv3_0.5.85-brand1_iphoneos-arm.deb make test-offline test-asan

Use a fresh output directory for every package build.

### Developer probes

Optional legacy network and presentation probes are disabled unless explicitly enabled. They do not contain a personal LAN address.

Specialized probe experiments can use the root-owned device configuration file:

    /var/root/.jellyfin-atv3-probe-origin

Normal Jellyfin playback does not require this file.

## Clock

The repository also includes a completely independent native Clock appliance.

See the dedicated English documentation:

**[Clock for Apple TV 3 — English README](Clock/README_EN.md)**

Clock has its own package ID, org.atv3.clock, and does not replace or modify RetroReel3.

## License and third-party rights

Original RetroReel3 and Clock source code and project documentation authored by **ABoringBlog** are released under the [MIT License](LICENSE).

The MIT license does not relicense Apple system software, frameworks, firmware or SDKs; Jellyfin trademarks, name or logo; Apple trademarks; or third-party artwork and intellectual property.

No proprietary Apple SDK or system binary is distributed in this repository.

## Sponsorship

Development is free and open source. Sponsorship is optional and does not provide exclusive features, paid access, or guaranteed development work.

[Support ABoringBlog on GitHub Sponsors](https://github.com/sponsors/ABoringBlog)
