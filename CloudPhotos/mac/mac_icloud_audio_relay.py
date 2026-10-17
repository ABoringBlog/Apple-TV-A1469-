#!/usr/local/bin/python3
"""iCloud Photos ATV3: NAS Chromium PulseAudio -> Mac built-in speaker.

Source is a live, unmodified 44.1kHz stereo PCM monitor of the private
Chromium container, transported through the user's EXISTING SSH session.
No credentials, photos or captured audio are stored. No ATV native changes.
Jellyfin/NetEase/Radio Mac audio services are never touched.
"""
from __future__ import annotations

import atexit
import fcntl
import json
import os
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

HOME = Path.home()
AUDIO_ROOT = HOME / "Library" / "Application Support" / "ATV3iCloudPhotosAudio"
ROOT = Path(__file__).resolve().parent
FFPLAY = "/usr/local/bin/ffplay"
SSH = "/usr/bin/ssh"
NAS_IP = os.environ.get("ATV_PHOTOS_NAS_IP", "192.0.2.24")
KEY = Path(os.environ.get("ATV_PHOTOS_SSH_KEY", str(HOME / ".ssh" / "id_ed25519_nas")))
HEALTH = f"http://{NAS_IP}:18793/health"
LOG = AUDIO_ROOT / "audio-status.log"
LOCK = AUDIO_ROOT / "run.lock"
POLL_SECONDS = 0.65


def write_log(message: str):
    # Only static labels and counters. Never log media, credentials or PCM.
    try:
        with LOG.open("a", encoding="utf-8") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M:%S %z ") + message + "\n")
    except OSError:
        pass


def source_health():
    req = urllib.request.Request(HEALTH, headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=1.4) as f:
        data = json.load(f)
    active = bool(data.get("ok") and data.get("active")
                  and data.get("source") in ("wayland", "screenshot_fallback", "screenshot"))
    if not active:
        return False  # Explicit application exit stops immediately.
    if int(data.get("connections", 0)) < 1:
        return None  # Video TCP reconnect is not an application stop.
    return True



class Bridge:
    def __init__(self):
        self.ssh = None
        self.player = None
        self.ssh_log = None
        self.player_log = None
        self.running = True
        self.session_start = 0.0
        self.last_alive = 0.0
        self.last_restart = 0.0

    def cleanup_orphan_capture(self):
        # Docker exec clients may disconnect while their container process
        # survives. Kill only our specially tagged audio capture, NEVER other
        # PulseAudio clients, Chrome, or other ATV application sources.
        try:
            subprocess.run([
                SSH, "-n", "-T", "-o", "BatchMode=yes",
                "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=3",
                "-i", str(KEY), f"root@{NAS_IP}",
                "docker", "exec", "-u", "abc", "atv3-icloud-chromium",
                "/usr/bin/pkill", "-f", "^ATV3iCloudPCM-parec"
            ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
        except (OSError, subprocess.TimeoutExpired):
            pass

    def prepare_pulse_socket(self):
        # The container exposes /defaults/native through a root-owned parent.
        # Allow abc to TRAVERSE that one directory (not list or write it).
        # Always repeat after Docker recreation, without touching Chromium.
        base = [SSH, "-T", "-n", "-o", "BatchMode=yes",
                "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=4",
                "-i", str(KEY), f"root@{NAS_IP}", "docker", "exec",
                "atv3-icloud-chromium"]
        # SSH joins remote arguments into a shell command; avoid sh -c
        # fragments and invoke fixed binaries with fixed arguments.
        for command in (("/bin/chgrp", "abc", "/defaults"),
                        ("/bin/chmod", "710", "/defaults")):
            result = subprocess.run(base + list(command),
                                    stdin=subprocess.DEVNULL,
                                    stdout=subprocess.DEVNULL,
                                    stderr=subprocess.DEVNULL, timeout=7)
            if result.returncode:
                raise RuntimeError("pulse_socket_access_not_ready")

    def start(self):
        self.prepare_pulse_socket()
        # Raw PCM never transits an unauthenticated LAN port; it flows inside
        # the established NAS SSH session. Its stdout contains only PCM.
        args = [
            SSH, "-T", "-n", "-o", "BatchMode=yes",
            "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=4",
            "-o", "ServerAliveInterval=3", "-o", "ServerAliveCountMax=2",
            "-i", str(KEY), f"root@{NAS_IP}",
            "docker", "exec", "-u", "abc", "atv3-icloud-chromium",
            "/bin/bash", "/config/atv3_icloud_pcm_source.sh"
        ]
        self.ssh_log = (AUDIO_ROOT / "ssh-errors.log").open("ab", buffering=0)
        self.ssh = subprocess.Popen(
            args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=self.ssh_log, close_fds=True, bufsize=0)
        try:
            self.player_log = (AUDIO_ROOT / "player-errors.log").open("ab", buffering=0)
            self.player = subprocess.Popen([
                str(ROOT / "build" / "icloud-pcm-player")
            ], stdin=self.ssh.stdout, stdout=subprocess.DEVNULL,
               stderr=self.player_log, close_fds=True)
        finally:
            self.ssh.stdout.close()
        self.session_start = self.last_alive = time.monotonic()
        write_log("PCM_TO_MAC_STARTED_44100_STEREO_SSH")

    def stop(self):
        for proc in (self.player, self.ssh):
            if proc and proc.poll() is None:
                proc.terminate()
        for proc in (self.player, self.ssh):
            if proc:
                try:
                    proc.wait(timeout=1.0)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    try:
                        proc.wait(timeout=0.6)
                    except subprocess.TimeoutExpired:
                        pass
        had_session = self.player is not None or self.ssh is not None
        self.player = self.ssh = None
        for handle in (self.ssh_log, self.player_log):
            if handle:
                handle.close()
        self.ssh_log = self.player_log = None
        if had_session:
            self.cleanup_orphan_capture()
            write_log("PCM_TO_MAC_STOPPED")

    def run(self):
        signal.signal(signal.SIGTERM, lambda *_: setattr(self, "running", False))
        signal.signal(signal.SIGINT, lambda *_: setattr(self, "running", False))
        write_log("ICLOUD_MAC_AUDIO_WATCHER_READY")
        self.cleanup_orphan_capture()
        while self.running:
            now = time.monotonic()
            try:
                live = source_health()
                if live is True:
                    self.last_alive = now
                elif live is None:
                    live = self.player is not None and now - self.last_alive < 5.0
            except (OSError, ValueError, TimeoutError) as ex:
                write_log("HEALTH_FAILURE_" + type(ex).__name__)
                # One transient health failure should not interrupt playback.
                live = (self.player is not None and now - self.last_alive < 3.0)
            if live:
                dead = ((self.ssh and self.ssh.poll() is not None) or
                        (self.player and self.player.poll() is not None))
                if dead:
                    write_log("PCM_TO_MAC_CHILD_EXIT ssh=" +
                              str(self.ssh.poll() if self.ssh else None) +
                              " player=" +
                              str(self.player.poll() if self.player else None))
                    self.stop()
                if not self.ssh and now - self.last_restart > 2.5:
                    self.last_restart = now
                    try:
                        self.start()
                    except (OSError, subprocess.SubprocessError, RuntimeError):
                        self.stop()
                        write_log("PCM_TO_MAC_START_RETRY")
            else:
                self.stop()
            time.sleep(POLL_SECONDS)
        self.stop()


def main():
    os.umask(0o077)
    AUDIO_ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    with LOCK.open("a+") as lockfile:
        try:
            fcntl.flock(lockfile, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        if not KEY.is_file() or not (ROOT / "build" / "icloud-pcm-player").is_file():
            write_log("SOURCE_OR_PLAYER_MISSING")
            return
        Bridge().run()


if __name__ == "__main__":
    try:
        main()
    except Exception as ex:
        write_log("WATCHER_FATAL_" + type(ex).__name__)
        raise
