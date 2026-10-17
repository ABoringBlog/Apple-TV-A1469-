#!/usr/bin/env python3
"""On-demand Wayland H.264 frame producer inside private iCloud Chromium container.

Idle when no ATV stream is requested. Encodes directly from Wayland compositor
via pixelflux, and relays Annex-B H264 access units through NAS-local TCP.
Never touches DevTools, takes no screenshots, and stores no video or credentials.
"""
import os
import queue
import socket
import struct
import time
from pathlib import Path

os.environ.setdefault("XDG_RUNTIME_DIR", "/config/.XDG")
os.environ.setdefault("WAYLAND_DISPLAY", "wayland-1")
import pixelflux

HOST = "192.0.2.24"
PORT = 18794
KEY_PATH = Path("/config/atv3-icloud-capture.key")
CAPTURE_FPS = 15.0

def build_settings():
    c = pixelflux.CaptureSettings()
    c.use_wayland = True
    c.wayland_host_display = "wayland-1"
    c.display_id = 0
    c.codec = "h264"
    c.video_fullframe = True
    c.video_streaming_mode = True
    c.video_crf = 22
    c.keyframe_interval_s = 0.5
    c.use_cpu = True
    c.capture_width = 1920
    c.capture_height = 1080
    c.target_fps = CAPTURE_FPS
    c.capture_cursor = False
    c.scale = 1.0
    c.auto_adjust_screen_capture_size = False
    return c

def connection_loop():
    capture = pixelflux.ScreenCapture()
    sock = socket.create_connection((HOST, PORT), timeout=4)
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    sock.settimeout(2.0)
    try:
        key = KEY_PATH.read_bytes().strip()
        if len(key) != 64:
            raise ValueError("capture_auth_not_configured")
        sock.sendall(b"PHC1" + key)
        ack = sock.recv(4)
        if ack != b"GO!!":
            return
        frame_queue = queue.Queue(maxsize=8)
        dropped = [0]
        def callback(frame):
            data = memoryview(frame)
            if len(data) <= 16 or bytes(data[12:16]) != b"\x00\x00\x00\x01":
                return
            try:
                frame_queue.put_nowait(bytes(data[12:]))
            except queue.Full:
                dropped[0] += 1
                try:
                    frame_queue.get_nowait()
                    frame_queue.put_nowait(bytes(data[12:]))
                except queue.Empty:
                    pass
                capture.request_idr_frame()
        capture.start_capture(callback, build_settings())
        try:
            while True:
                try:
                    payload = frame_queue.get(timeout=1.0)
                except queue.Empty:
                    state,err = capture.capture_state(0)
                    if state == "failed":
                        raise RuntimeError("capture_pipeline_failed")
                    # Check whether NAS has stopped the stream.
                    try:
                        sock.sendall(struct.pack(">I",0))
                    except OSError:
                        break
                    continue
                if len(payload) > 1000000:
                    continue
                sock.sendall(struct.pack(">I", len(payload)) + payload)
        finally:
            capture.stop_capture()
    finally:
        sock.close()

def main():
    # The small connect loop uses negligible CPU when Photos is not open.
    while True:
        try:
            connection_loop()
        except (ConnectionError, OSError, TimeoutError, RuntimeError, ValueError):
            pass
        time.sleep(0.8)

if __name__ == "__main__":
    main()
