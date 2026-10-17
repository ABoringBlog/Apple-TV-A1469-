#!/usr/bin/env python3
"""ATV3 private NAS Chromium -> H.264 live HLS video.
Frames and rolling MPEG-TS fragments are held in /run (RAM), not archived.
"""
import hashlib
import hmac
import json
import os
from pathlib import Path
import shutil
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from server import Browser, SPATIAL_JS

BIND="192.0.2.24"
PORT=18791
SECRET=Path("/etc/atv3-icloud-photos/api.token").read_text().strip()
CACHE=Path("/run/atv3-icloud-video")
FPS=10
MAX_CAPTURE=3_500_000
VIEW_ALLOWED={"192.0.2.41","192.0.2.15","192.0.2.24","127.0.0.1"}
# Mac may inspect the stream for debugging; only client ATV can request start.
CONTROL_ALLOWED={"192.0.2.41","192.0.2.15","192.0.2.24","127.0.0.1"}

class Stream:
    def __init__(self):
        self.lock=threading.RLock()
        self.worker=None
        self.ffmpeg=None
        self.capture=None
        self.running=False
        self.generation=0
        self.frames=0
        self.capture_count=0
        self.latest_frame=None
        self.last_capture=0.
        self.last_error=""
        self.started=0.
        self.last_view=0.

    def _cleanup(self):
        if self.ffmpeg:
            try:
                self.ffmpeg.stdin.close()
                self.ffmpeg.terminate()
                self.ffmpeg.wait(timeout=3)
            except Exception:
                try:self.ffmpeg.kill()
                except Exception:pass
            self.ffmpeg=None
        if self.capture:
            self.capture.disconnect()
            self.capture=None
        for f in CACHE.glob("*"):
            if f.is_file():
                try:f.unlink()
                except OSError:pass

    def start(self):
        with self.lock:
            if self.running and self.ffmpeg and self.ffmpeg.poll() is None:
                return {"ok":True,"ready":True,"already_running":True,"fps":FPS,"video":"1920x1080"}
            self._cleanup()
            self.generation+=1
            token=self.generation
            self.last_error=""
            self.running=True
            self.last_view=time.monotonic()
            self.started=time.monotonic()
            self.frames=0
            self.capture_count=0
            self.latest_frame=None
            self.worker=threading.Thread(target=self._serve,args=(token,),daemon=True)
            self.worker.start()
        # Do not announce HLS readiness until the first segment is complete.
        deadline=time.monotonic()+18
        while time.monotonic()<deadline:
            if (CACHE/"stream.m3u8").exists():
                try:
                    playlist=(CACHE/"stream.m3u8").read_text()
                    if playlist.count("#EXTINF:") >= 3:
                        return {"ok":True,"ready":True,"fps":FPS,"video":"1920x1080"}
                except OSError:pass
            if self.last_error:
                break
            time.sleep(.2)
        return {"ok":False,"error":self.last_error or "hls_start_timeout"}

    def stop(self):
        with self.lock:
            self.running=False
            self.generation+=1
            # Avoid blocking the HTTP request while background writer completes.
        return {"ok":True}

    def status(self):
        with self.lock:
            live=bool(self.running and self.ffmpeg and self.ffmpeg.poll() is None)
            return {"ok":True,"active":live,"frames":self.frames,
                    "captured":self.capture_count,"fps":FPS,"last_error":self.last_error,
                    "uptime":round(time.monotonic()-self.started,1) if live else 0}

    def _capture_frames(self,browser,token):
        # Capture can vary between 3 and 8 fps on the NAS CPU. The encoder
        # must not inherit that irregular timing; it consumes the most recent
        # frame independently on a constant clock.
        while True:
            with self.lock:
                if not self.running or token!=self.generation:
                    return
            try:
                response=browser.request("Page.captureScreenshot",{
                    "format":"jpeg","quality":88,
                    "fromSurface":True,"captureBeyondViewport":False})
                data=__import__("base64").b64decode(response.get("data",""))
                if len(data)<500 or len(data)>MAX_CAPTURE or not data.startswith(b"\xff\xd8"):
                    raise ValueError("capture_invalid")
                with self.lock:
                    self.latest_frame=data
                    self.capture_count+=1
                    self.last_capture=time.monotonic()
            except Exception as error:
                self.last_error=type(error).__name__
                return
            time.sleep(.12)

    def _serve(self,token):
        ff=None
        capture=None
        try:
            CACHE.mkdir(mode=0o700,parents=True,exist_ok=True)
            os.chmod(CACHE,0o700)
            capture=Browser()
            capture.connect()
            # Install visible remote focus ring before encoding the first frame.
            # This allows the first photo to be selected immediately on entry.
            capture.request("Runtime.evaluate", {
                "expression":SPATIAL_JS.replace("__ACTION__",'"init"'),
                "returnByValue":True
            })
            first=capture.request("Page.captureScreenshot",{
                "format":"jpeg","quality":88,
                "fromSurface":True,"captureBeyondViewport":False})
            self.latest_frame=__import__("base64").b64decode(first.get("data",""))
            if not self.latest_frame.startswith(b"\xff\xd8"):
                raise ValueError("first_capture_invalid")
            self.capture_count=1
            # Fix CSS viewport; DPR=1.5 produces an actual 1920x1080 JPEG.
            ff=subprocess.Popen([
                "/usr/bin/ffmpeg","-nostdin","-hide_banner","-loglevel","error",
                "-thread_queue_size","16","-f","mjpeg","-framerate",str(FPS),
                "-i","pipe:0",
                "-f","lavfi","-i","anullsrc=channel_layout=stereo:sample_rate=44100",
                "-map","0:v:0","-map","1:a:0",
                "-c:v","libx264","-preset","ultrafast","-tune","zerolatency",
                "-crf","18","-pix_fmt","yuv420p","-profile:v","main","-level:v","4.0",
                # A 0.5s segment made old ffmpeg emit TARGETDURATION:0,
                # which is invalid HLS and fails ATV3 playback. Six frames
                # at 10 fps = 0.6s, rounded target duration 1 second.
                "-g","6","-keyint_min","6","-sc_threshold","0",
                "-r",str(FPS),
                "-c:a","aac","-b:a","48k","-ar","44100","-ac","2",
                "-f","hls","-hls_time","0.6","-hls_list_size","4",
                "-hls_delete_threshold","4",
                "-hls_flags","delete_segments+omit_endlist",
                "-hls_segment_filename",str(CACHE/"part_%08d.ts"),
                str(CACHE/"stream.m3u8")
            ],stdin=subprocess.PIPE,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,
            bufsize=0)
            with self.lock:
                self.ffmpeg=ff
                self.capture=capture
            threading.Thread(target=self._capture_frames,args=(capture,token),daemon=True).start()
            interval=1.0/FPS
            deadline=time.monotonic()
            while True:
                with self.lock:
                    if not self.running or token!=self.generation:
                        break
                    if self.frames>150 and time.monotonic()-self.last_view>35:
                        self.running=False
                        self.last_error="player_disconnected"
                        break
                with self.lock:
                    data=self.latest_frame
                if not data:
                    time.sleep(.03)
                    continue
                ff.stdin.write(data)
                if ff.poll() is not None:
                    raise RuntimeError("h264_encoder_exited")
                self.frames+=1
                self.last_capture=time.monotonic()
                deadline+=interval
                remaining=deadline-time.monotonic()
                if remaining>0:
                    time.sleep(remaining)
                elif remaining < -.7:
                    deadline=time.monotonic()
        except Exception as ex:
            self.last_error=type(ex).__name__+":"+str(ex)[:100]
        finally:
            with self.lock:
                if token==self.generation:
                    self.running=False
                if ff is not None:
                    try:
                        ff.stdin.close()
                        ff.terminate()
                        ff.wait(timeout=3)
                    except Exception:
                        try:ff.kill()
                        except Exception:pass
                if capture is not None:capture.disconnect()
                if self.ffmpeg is ff:self.ffmpeg=None
                if self.capture is capture:self.capture=None
                # Unlink transient photo-derived video fragments on stop;
                # a newly-started session must never inherit old segment files.
                if not self.running and self.generation in (token,token+1):
                    self.latest_frame=None
                    for segment in CACHE.glob('*'):
                        if segment.is_file():
                            try:segment.unlink()
                            except OSError:pass

stream=Stream()

class Handler(BaseHTTPRequestHandler):
    def log_message(self,*a):pass

    def response(self,code,data,typ="application/json"):
        self.send_response(code)
        self.send_header("Content-Type",typ)
        self.send_header("Cache-Control","no-store")
        self.send_header("X-Content-Type-Options","nosniff")
        self.send_header("Content-Length",str(len(data)))
        self.end_headers()
        if data:
            try:self.wfile.write(data)
            except (BrokenPipeError,ConnectionResetError):pass

    def json(self,data,code=200):
        self.response(code,json.dumps(data,separators=(",",":")).encode())

    def authenticated(self):
        return (self.client_address[0] in CONTROL_ALLOWED and
                hmac.compare_digest(self.headers.get("X-ATV-Photos-Key",""),SECRET))

    def do_POST(self):
        if self.path not in ("/v1/video/start","/v1/video/stop"):
            return self.json({"ok":False,"error":"not_found"},404)
        if not self.authenticated():
            return self.json({"ok":False,"error":"forbidden"},403)
        if self.path.endswith("/start"):
            result=stream.start()
            return self.json(result,200 if result.get("ok") else 503)
        return self.json(stream.stop())

    def do_GET(self):
        path=self.path.split("?",1)[0]
        if path=="/health":
            return self.json({"ok":True,"service":"atv3-photos-hls",
                              **stream.status()})
        if self.client_address[0] not in VIEW_ALLOWED:
            return self.json({"ok":False,"error":"forbidden"},403)
        if path=="/v1/video/status":
            if not self.authenticated():return self.json({"ok":False},403)
            return self.json(stream.status())
        name=path.lstrip("/")
        if name=="stream.m3u8":
            media="application/vnd.apple.mpegurl"
        elif (name.startswith("part_") and name.endswith(".ts") and
              len(name)==16 and name[5:13].isdigit()):
            media="video/mp2t"
        else:
            return self.json({"ok":False,"error":"not_found"},404)
        filename=CACHE/name
        try:
            payload=filename.read_bytes()
            stream.last_view=time.monotonic()
        except OSError:
            return self.json({"ok":False,"error":"not_ready"},503)
        return self.response(200,payload,media)

if __name__=="__main__":
    ThreadingHTTPServer((BIND,PORT),Handler).serve_forever()
