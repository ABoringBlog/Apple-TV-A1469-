# Mac audio Bridge

**Required for audio**: the ATV3's built-in Photos bridge video path does not output the iCloud Photos soundtrack through ATV HDMI. A separate companion program on the user's Mac plays it through the **Mac's local output**.

### Path

Chromium's PulseAudio sink `output` → `output.monitor` → `parec --format=s16le --rate=44100 --channels=2 --raw` → NAS SSH `docker exec` stdout → Mac `mac_icloud_audio_relay.py` → `icloud_pcm_player.c` AudioQueue → macOS/CoreAudio → Mac speakers. All PCM stays in memory in normal operation; logs should contain counters only.

The macOS AudioQueue PCM sink provides a bounded ring buffer, nonblocking output callbacks, initial prebuffer, underrun/overrun diagnostics, bounded drift correction, an input-stall watchdog and old-session cleanup. Browser pause/seek changes the captured stream; no direct ATV presentation timestamps are fed back, so device-independent perfect synchronization is **not** guaranteed.

### Bring-up

* Build the C player with Apple Command Line Tools. Change its binary path if necessary in `mac_icloud_audio_relay.py` and set `ATV_PHOTOS_NAS_IP` and `ATV_PHOTOS_SSH_KEY`. The supervisor was written for a Mac user LaunchAgent; paths/log folder and task's environment must be adapted per user.
* The NAS SSH account must be authorized for `docker exec -u abc atv3-icloud-chromium ... /config/atv3_icloud_pcm_source.sh`. Do not publish SSH keys. Avoid broad root permissions if possible; limit the allowed command and remote host.
* Provide PulseAudio at `/defaults/native`, `output.monitor` and the `parec` executable in the Docker image. These are local requirements, **not** automatically provisioned by the repository.
* The Mac relay checks the NAS direct-video `/health` endpoint: `active=false` stops output, while transient connections=0 is tolerated for a brief reconnection grace period.
* Use native Mac speakers or explicitly configure a local output device; sound is not sent to ATV HDMI and no special audio hardware is distributed.

### Safety and limits

No raw photo/audio/video stream or account data should be persisted. Avoid exposing the private PCM endpoint; secure NAS→Mac transport with SSH. Audio latency, underruns and perceived sync require user testing on the actual hardware. The implementation is a device-specific reference, not a certified low-latency media transport.
