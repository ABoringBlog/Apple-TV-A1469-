# Folia Apple TV 3 移植（A1469）— v44 源码预览

[English](README.md) · [Folia 官方项目](https://github.com/chthollyphile/folia-major)

> **必须有 Mac Bridge。Folia 并非独立运行在 Apple TV 3 上。** Apple TV 3 只负责接收、硬件解码和显示 Mac 发来的 H.264 视频及 PCM 音频，并将遥控操作发回 Mac。真正的 Folia/Electron 界面、歌词动画和播放功能仍由 **Mac 上经过专门修改的 Folia 应用**执行。只安装 ATV 插件会无法显示正常画面。

## 已验证的版本

- ATV：越狱 Apple TV 3 Rev A（A1469 / AppleTV3,2），Apple TV Software 7.9（12H1006）。
- Mac：专用的 Folia 0.7.18 修改版本，不是普通的官方 Folia 安装包。
- 视频：Mac 使用 VideoToolbox 编码为 H.264 Main L4.0 1920×1080/30fps（原始 UI 是 1280×720）；ATV 硬件解码；不是 AirPlay、HLS 或 tvOS 应用。
- 音频：单独的 FA01 PCM 通道，需要 Folia Electron 端的 WebAudio 抓取适配。
- 功能：ATV 打开时 Mac 检查是否有挂起进程，有则恢复，无则启动；ATV 退出时挂起 Mac 上的 Folia 进程树并保存内存状态。2026-10-15 已用真机验证打开、挂起、再次恢复且进程 PID 不变。
- **通用公开构建尚未在别人的设备独立验证，属于开发者源码预览，不是开箱即用安装包。**

## 运行所需条件

需要 Mac 开机、登录且保持唤醒，与 ATV 处于可信任局域网。Mac 端必须是**独立的、已经适配 Bridge 的 Folia 实例**；官方普通客户端无法直接与该 ATV 插件配合使用。Mac 不在家、断电或睡眠时，ATV 无法独立播放 Folia。

网络端口：`18782`（控制）、`18783`（启动/挂起）、`18786`（FV01 视频）、`18787`（FA01 音频）。所有连接仅用于本地网络；禁止公网端口映射。

## 文件说明

- `ATV/Sources/`：FoliaDirect 原生 FRAppliance 源码，含显示、遥控、音频和生命周期。
- `ATV/FoliaDirect.frappliance/`：Info.plist 和图标，必须配置 **FoliaBridgeHost 为 Mac 的局域网 IPv4**。
- `Scripts/build_atv.sh`：在本地编译、签名 ARMv7 插件；公开仓库不直接分发编译完成的程序。
- `Mac/Bridge/`：Mac 视频编码、远程导航及声音接入相关源代码。
- `Mac/Supervisor/`：保留进程内存的按需启动/挂起/恢复管理器。
- `Scripts/`：编译和 Mac 端服务安装脚本。

编译安装、局限性、Mac Folia 端集成要求请阅读 [SETUP.md](SETUP.md) 与 [Mac/INTEGRATION.md](Mac/INTEGRATION.md)。

## 授权和声明

本项目属于 **非官方的社区 ATV3 适配方案**，与 Folia 官方、Apple 不存在隶属或认可关系。

原项目 [Folia](https://github.com/chthollyphile/folia-major) 为 AGPL-3.0 开源软件。本目录保留官方署名和许可文本。这里未上传私人 Mac 修改版安装包或包含个人登录状态的 ASAR，也不表示这里的部分文件就是修改版 Electron 程序的完整对应源码。任何分发修改版 Folia 桌面程序的行为仍需满足 AGPL 对应源码义务。

本目录已排除本机凭据、真实私人 LAN 地址、账号 Cookie、密钥和运行日志；配置按部署机器填写。**不要将服务器或端口直接暴露到互联网。**
