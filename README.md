# Apple TV 3 Modernization
ALL WORK DONE BY CHATGPT
所有的工作都是ChatGPT完成的

[English-only README](README_EN.md)

Independent open-source applications for **jailbroken Apple TV 3 (A1469 / AppleTV3,2)**. Each app is independently installable, has its own version and release, and shares the same voluntary [GitHub Sponsors](https://github.com/sponsors/ABoringBlog) entry point.

面向已越狱 Apple TV 3 的独立开源应用集合。各应用分别构建、安装与发布，共享自愿赞助入口。

## Available applications / 已发布应用

| App | Description / 功能 | Release |
| --- | --- | --- |
| **[RetroReel3](#retroreel3-jellyfin-client)** | Independent, unofficial native client for Jellyfin / 非官方 Jellyfin 原生客户端 | [v0.5.101-public1](https://github.com/ABoringBlog/Apple-TV-A1469-Jellyfin-Client-and-some-plugins/releases/tag/v0.5.101-public1) |
| **[Clock](Clock/)** | Native standalone clock / 原生独立时钟 | [clock-v0.1.5](https://github.com/ABoringBlog/Apple-TV-A1469-Jellyfin-Client-and-some-plugins/releases/tag/clock-v0.1.5) |
| **[Weather](Weather/)** | Native weather, English + 中文; requires Mac ATV3Bridge 24/7 / 原生天气，依赖 Mac 24 小时桥接 | [weather-v1.0.0-public2](https://github.com/ABoringBlog/Apple-TV-A1469-Jellyfin-Client-and-some-plugins/releases/tag/weather-v1.0.0-public2) |
| **[Radio](Radio/)** | Native Internet Radio, English + 中文; requires Mac ATV3Bridge Radio / 原生网络电台，依赖 Mac Bridge | [radio-v0.3.1-public2](https://github.com/ABoringBlog/Apple-TV-A1469-Jellyfin-Client-and-some-plugins/releases/tag/radio-v0.3.1-public2) |
| **[CloudTune / 云律音乐](CloudTune/)** | Independent music client, English + 中文; phone-input search in 1.1 / 独立音乐客户端，1.1 已接入手机输入搜索 | [cloudtune-v1.1.0-public2](https://github.com/ABoringBlog/Apple-TV-A1469-Jellyfin-Client-and-some-plugins/releases/tag/cloudtune-v1.1.0-public2) |
| **[Folia for Apple TV 3 / Folia Mac 桥接](Folia/)** | Unofficial Apple TV 3 Folia receiver. **Requires a separate modified Folia app running on an awake Mac**, not a standalone ATV music app / 需要 Mac Bridge | [Source preview](Folia/) |
| **[Phone Remote & Text Input](PhoneRemoteInput/)** | iPhone Control Center Remote + keyboard input for ATV3 / iPhone 控制中心遥控器 + 手机文字输入 | [phone-remote-input-v1.0.0-public1](https://github.com/ABoringBlog/Apple-TV-A1469-Jellyfin-Client-and-some-plugins/releases/tag/phone-remote-input-v1.0.0-public1) |

**All apps are free and do not require sponsorship. / 所有应用免费，赞助完全自愿。**

> **Weather architecture note / Weather 架构说明：** the current Weather app requires a Mac running ATV3Bridge continuously (24/7) for fresh live data. / 当前 Weather 需要一台 Mac 24 小时运行 ATV3Bridge 才能持续获取实时天气。

> **Radio architecture note / Radio 架构说明：** the current Radio app requires a Mac running ATV3Bridge Radio continuously for directory/search/favorites/recent data. / 当前 Radio 需要一台 Mac 持续运行 ATV3Bridge Radio 才能正常浏览、搜索、收藏和读取最近播放。

> **CloudTune architecture note / 云律音乐架构说明：** CloudTune 1.1 requires a Mac running CloudTune Bridge continuously and a compatible local upstream API. iPhone Remote keyboard/search integration uses the separate Phone Remote & Text Input module. / CloudTune 1.1 需要 Mac 持续运行 CloudTune Bridge 和兼容的本地 API；iPhone 遥控和文字输入由独立 Phone Remote & Text Input 模块提供。

> **Phone Remote & Text Input note / 手机遥控与输入说明：** the module emulates a modern Companion Link target on the Mac and relays verified input to the ATV3 through a loopback-only MobileSubstrate injector plus an SSH tunnel. / 该模块由 Mac 提供 Companion Link，并通过仅回环监听的 ATV3 MobileSubstrate injector 与 SSH tunnel 转发遥控和文字输入；核心遥控与文字输入链路均已真机验证。

---

## RetroReel3 (Jellyfin client)

**Current ATV3 Jellyfin release: v0.5.101-public1.** Newly verified user-facing work includes progressive 10-item library first-screen, native animated poster/text scrolling, compact two-column Library selection, an up-to-1 GiB persistent image/catalog cache, and native cover fades. Public builds use a configurable Mac Audio Bridge endpoint. See [full release notes / 详细说明](docs/jellyfin-v0.5.101-public1.md) for requirements, limitations, and installation. Older development-phase notes below describe historical milestones, not the current device validation.

![RetroReel3 original app icon](Jellyfin.frappliance/AppIcon.png)

**An unofficial native Jellyfin client for jailbroken Apple TV 3 (A1469).**

**适用于已越狱 Apple TV 3（A1469）的独立第三方 Jellyfin 原生客户端。**

*Independent community project; not affiliated with or endorsed by Jellyfin or Apple.*

Native Jellyfin appliance for jailbroken **Apple TV 3 (A1469 / AppleTV3,2)**. Not an AirPlay receiver, browser wrapper, or tvOS application.

适用于已越狱 **Apple TV 3（A1469 / AppleTV3,2）** 的原生 Jellyfin 客户端，不依赖 AirPlay 或网页封装。

### Compatibility / 兼容性

- Tested hardware and firmware: **AppleTV3,2 / A1469, Apple TV Software 7.9, build 12H1006 (iOS 8.4.4)**.
- The native playback baseline was tested on physical hardware. The private 0.5.101 user interface was verified on physical hardware; the privacy-neutral public build has passed offline tests but has not undergone an independent physical-device acceptance test.
- Other models, firmware builds and jailbreak environments are not validated.

已在上述设备型号和系统版本完成原生播放基础版真机验证。当前品牌版本已完成构建和离线测试；不保证其他型号或固件兼容。

### Install / 安装

Download the `.deb` file and `SHA256SUMS` from the [RetroReel3 v0.5.101 Release](https://github.com/ABoringBlog/Apple-TV-A1469-Jellyfin-Client-and-some-plugins/releases/tag/v0.5.101-public1). On your Mac/Linux computer, verify the SHA256 listed in `SHA256SUMS`, then run:

从 RetroReel3 v0.5.101 Release 下载 `.deb` 和 `SHA256SUMS`，先校验哈希，再在 Mac/Linux 终端执行：

```sh
scp org.jellyfin.atv3_0.5.101-public1_iphoneos-arm.deb root@APPLE_TV_IP:/var/root/
ssh root@APPLE_TV_IP 'dpkg -i /var/root/org.jellyfin.atv3_0.5.101-public1_iphoneos-arm.deb && launchctl stop com.apple.frontrow && launchctl start com.apple.frontrow'
```

Replace `APPLE_TV_IP` with the target Apple TV's local address. Requires jailbreak, root SSH and `dpkg`. Restart only the FrontRow host, not the entire device.

把 `APPLE_TV_IP` 换成 Apple TV 的局域网地址。需要已越狱、SSH root 权限及 `dpkg`。只重启 FrontRow，不重启整机。

> The legacy Apple TV 3 curl/SSL stack may not connect to modern GitHub HTTPS. Download on a computer and transfer by SCP instead.
>
> ATV3 内置的旧版 curl/SSL 可能无法连接 GitHub HTTPS，建议电脑下载后通过 SCP 传入。

**Upgrade safety / 升级兼容：** Package ID (org.jellyfin.atv3), internal bundle path, principal class and saved session keys remain unchanged for existing installations. The current release updates the libraries UI and configurable bridge endpoint. / 本版本升级 Libraries 界面及可配置 Bridge 地址，包标识和路径不变。

### Features / 功能

- Jellyfin server login and media-library navigation / 登录、浏览电影与电视剧
- Native Apple TV player with DirectPlay, DirectStream/remux and server transcoding / 原生播放及三种播放协商
- Playback controls, progress reporting and resume / 播放控制、进度上报、断点续播
- Audio track selection and server-rendered subtitles / 音轨切换与服务器字幕处理

The current client may require server video transcoding when subtitles are selected. See [playback architecture](docs/playback-architecture.md) and [subtitle architecture](docs/subtitle-architecture.md).

当前选择字幕时可能需要服务器烧录字幕，详见播放与字幕架构说明。

### Build / 编译

Requires macOS, Xcode Command Line Tools, a compatible Theos/iPhoneOS SDK and Python 3.

```sh
make shell
Scripts/package.sh build/iPhoneOS11.4.sdk-ios8.0/Jellyfin.frappliance build/package-local
JF_PACKAGE=build/package-local/org.jellyfin.atv3_0.5.101-public1_iphoneos-arm.deb make test-offline test-asan
```

Use a fresh output directory for each `Scripts/package.sh` invocation. The project has no dependency on redistributing Apple system binaries or proprietary SDKs.

`Scripts/package.sh` 每次应指定不存在的新输出目录。不要将 Apple 系统二进制或专有 SDK 上传到公开仓库。

### Optional developer probes / 可选开发诊断

The legacy network/presentation probes are **disabled unless explicitly enabled**. They do not contain a personal LAN address. The public binary uses a loopback-only URL for diagnostic probes. Developers who need remote probe traffic must modify and rebuild the diagnostic origin. The standalone synthetic probe server is not distributed in this release. Normal Jellyfin playback does not use this setting.

开发诊断探针默认不启动；要运行专门的实验，需自行指定诊断服务器地址。普通播放不需要此配置。

### License and third-party rights / 许可证与第三方权利

The original RetroReel3 and Clock source code and project documentation authored by ABoringBlog are released under the [MIT License](LICENSE). Third-party assets, logos, trademarks, Apple system frameworks and the Jellyfin name or logo are not relicensed by this repository. This is an independent community client, not an official Jellyfin project. Check the rights to any included third-party graphics before reuse or redistribution.

ABoringBlog 原创的 RetroReel3、Clock 源码及项目文档采用 [MIT License](LICENSE)。MIT 授权不涵盖第三方素材、商标、Apple 系统框架及 Jellyfin 名称/标志。本项目为独立社区客户端，并非 Jellyfin 官方项目。复用或重新分发第三方图像前请确认授权。

### Project notes / 项目文档

The historical [PROGRESS.md](PROGRESS.md) and [docs](docs/) record development stages; older passages may describe pre-device prototypes and should not be interpreted as the current release status. See the [Releases](https://github.com/ABoringBlog/Apple-TV-A1469-Jellyfin-Client-and-some-plugins/releases) page for published versions.

历史开发记录可能描述早期尚未真机验证的状态，请以最新 Release 为准。
