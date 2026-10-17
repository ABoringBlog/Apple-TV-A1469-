# Verification status and exclusions

* **Observed on one configured private deployment:** ATV3 remote photo browsing; NAS-hosted Chromium and Wayland/H.264 direct video; Mac-side native PCM output reported clear and synchronized during tests.
* **Reference, not fully reproduced from this source-only tree:** full clean-room NAS/Docker provisioning, third-party pixelflux packaging, generic Docker network setup, native plugin build with a compatible SDK, physical Mac/ATV audio-video timing on new hardware.
* **Excluded from publication:** authenticated Chromium profile, Apple Account and 2FA details, login cookies, browser screenshots, personal photos/videos, captured PCM/WAV, Apple-inspired copyrighted icons, compiled plugins with embedded secrets, local backup archives, private host config/systemd state, SDKs, proprietary binaries, device logs, IP-specific service settings.
* **Intentionally no release binary:** the current client build uses install-specific embedded secrets. Shipping a prebuilt binary would either expose them or fail to authenticate. Users must build their own with unique keys.
* **Legal:** Unofficial integration; no assertion of zero legal risk or endorsement. The original source may use unsupported/private interoperability interfaces. Distribution of Apple SDKs and copyrighted branding is outside project scope.
