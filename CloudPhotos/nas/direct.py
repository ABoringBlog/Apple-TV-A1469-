#!/usr/bin/env python3
"""Private on-demand Apple TV 3 iCloud Photos low-latency H.264 TCP stream.

Wire protocol reused from the tested FoliaDirect "FV01" receiver.
NALs are length-prefixed AVCC; a frame has 16-byte header (len,seq,ts-ms).
No HLS, no persistent frame files, no account cookies accessed by the service.
"""
import base64
import hmac
import json
import os
from pathlib import Path
import select
import socket
import struct
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from server import Browser, SPATIAL_JS

HOST = "192.0.2.24"
PORT_CONTROL=18793
PORT_VIDEO=18792
PORT_CAPTURE=18794  # private Docker-to-NAS compressed H264 ingest
CAPTURE_MODE=os.environ.get("ATV_PHOTOS_CAPTURE_MODE","wayland")
CAPTURE_KEY_FILE=Path("/etc/atv3-icloud-photos/capture.key")
CAPTURE_KEY=CAPTURE_KEY_FILE.read_bytes().strip() if CAPTURE_KEY_FILE.exists() else b""
KEY=Path("/etc/atv3-icloud-photos/api.token").read_text().strip()
ALLOWED={"192.0.2.41","192.0.2.15","192.0.2.24","127.0.0.1"}
FPS=15

def jpeg_dimensions(data):
    """Read JPEG SOF geometry without decoding or logging private pixels."""
    i=2
    while i+10 < len(data):
        if data[i] != 0xff:
            i+=1
            continue
        marker=data[i+1]
        i+=2
        if marker in (0xd8,0xd9,0x01):
            continue
        n=int.from_bytes(data[i:i+2], "big")
        if n<2:break
        if marker in (0xc0,0xc1,0xc2,0xc3,0xc6,0xc7):
            return (int.from_bytes(data[i+5:i+7],"big"),
                    int.from_bytes(data[i+3:i+5],"big"))
        i+=n
    return None

class Direct:
    def __init__(self):
        self.lock=threading.RLock()
        self.run=False
        self.serial=0
        self.encoder=None
        self.capture=None
        self.frame=None
        self.seq=0
        self.packet_count=0
        self.latest_capture=0
        self.latest_capture_started=0
        self.screenshot_attempts=0
        self.worker_errors=0
        self.clients=set()
        self.last_error=""
        self.capture_count=0
        self.start_at=0.
        self.source="idle"
        self.ingest_socket=None
        self.ingest_last=0.0
        self._ready={}
        self.enable_wayland=CAPTURE_MODE=="wayland" and len(CAPTURE_KEY)==64
        self.listener=socket.socket()
        self.listener.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
        self.listener.bind((HOST,PORT_VIDEO))
        self.listener.listen(4)
        threading.Thread(target=self._accept,daemon=True).start()
        if self.enable_wayland:
            self.ingest_listener=socket.socket()
            self.ingest_listener.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
            self.ingest_listener.bind((HOST,PORT_CAPTURE))
            self.ingest_listener.listen(3)
            threading.Thread(target=self._accept_capture,daemon=True).start()

    def _accept(self):
        while True:
            sock,addr=self.listener.accept()
            if addr[0] not in ALLOWED:
                sock.close()
                continue
            sock.setsockopt(socket.IPPROTO_TCP,socket.TCP_NODELAY,1)
            sock.settimeout(.12)
            try:
                with self.lock:
                    active=self.run
                if not active:
                    # The ATV receiver may retry while the user is outside
                    # Photos. Never retain inactive TCP sockets (CLOSE-WAIT).
                    sock.close()
                    continue
                sock.sendall(b"FV01")
                with self.lock:
                    self.clients.add(sock)
            except OSError:
                sock.close()

    @staticmethod
    def _recv_exact(sock,n):
        data=bytearray()
        while len(data)<n:
            chunk=sock.recv(n-len(data))
            if not chunk:raise EOFError()
            data.extend(chunk)
        return bytes(data)

    @staticmethod
    def _frame_nals(payload):
        # pixelflux emits one complete Annex-B H.264 access unit per callback.
        # Unlike ffmpeg's byte stream, the final NAL is also complete.
        starts=[]
        i=0;n=len(payload)
        while i+3<n:
            if payload[i:i+4]==b"\x00\x00\x00\x01":
                starts.append((i,4));i+=4
            elif payload[i:i+3]==b"\x00\x00\x01":
                starts.append((i,3));i+=3
            else:
                i+=1
        out=[]
        for ix,(pos,header_len) in enumerate(starts):
            end=starts[ix+1][0] if ix+1<len(starts) else n
            nal=payload[pos+header_len:end]
            if nal and len(nal)<900000 and nal[0]&31 in (1,5,6,7,8,9):
                out.append(nal)
        return out

    def _accept_capture(self):
        while True:
            sock,addr=self.ingest_listener.accept()
            sock.settimeout(1.5)
            try:
                # Never expose the raw screen to an unauthenticated sender.
                auth=self._recv_exact(sock,68)
                with self.lock:
                    active=(self.run and self.source=="wayland" and
                            self.ingest_socket is None)
                    permitted=self.enable_wayland
                if not active or not permitted or not hmac.compare_digest(
                        auth,b"PHC1"+CAPTURE_KEY):
                    sock.sendall(b"WAIT")
                    sock.close()
                    continue
                with self.lock:
                    self.ingest_socket=sock
                    self.ingest_last=time.monotonic()
                sock.sendall(b"GO!!")
                threading.Thread(target=self._capture_receiver,
                                 args=(sock,self.serial),daemon=True).start()
            except (OSError,EOFError):
                try:sock.close()
                except OSError:pass

    def _capture_receiver(self,sock,serial):
        try:
            while True:
                with self.lock:
                    if not self.run or self.source!="wayland" or serial!=self.serial:
                        return
                size=struct.unpack(">I",self._recv_exact(sock,4))[0]
                if size==0:continue
                if size<15 or size>1000000:raise ValueError("invalid_h264_frame")
                payload=self._recv_exact(sock,size)
                nals=self._frame_nals(payload)
                if not nals:continue
                with self.lock:
                    if self.serial!=serial or not self.run:return
                    self.capture_count+=1
                    self.ingest_last=time.monotonic()
                self._broadcast(nals)
        except (OSError,EOFError,TimeoutError,ValueError):
            pass
        finally:
            with self.lock:
                if self.ingest_socket is sock:
                    self.ingest_socket=None
            try:sock.close()
            except OSError:pass

    def _focus_watch(self,serial):
        browser=None
        old_window=None
        try:
            browser=Browser()
            # The existing CDP connection is used ONLY for remote focus/input,
            # not screenshot/video capture. Keep this session alive.
            browser.connect()
            try:
                win=browser.request("Browser.getWindowForTarget")
                old_window=win.get("windowId")
                if old_window is not None:
                    browser.request("Browser.setWindowBounds",{
                        "windowId":old_window,"bounds":{"windowState":"fullscreen"}})
            except Exception:
                old_window=None
            expression=SPATIAL_JS.replace("__ACTION__",
                "(window.__atv3ResumeForUnlock?'resume':'init')")
            browser.request("Runtime.evaluate",{
                "expression":expression,"returnByValue":True,"awaitPromise":True})
            last_repair=0
            while True:
                with self.lock:
                    if not self.run or serial!=self.serial or self.source!="wayland":
                        return
                now=time.monotonic()
                if now-last_repair>1.8:
                    last_repair=now
                    present=browser.request("Runtime.evaluate",{
                        "expression":"!!document.getElementById('__atv3_photos_focus_ring')",
                        "returnByValue":True}).get("result",{}).get("value",False)
                    if not present:
                        browser.request("Runtime.evaluate",{
                            "expression":SPATIAL_JS.replace("__ACTION__","'resume'"),
                            "returnByValue":True,"awaitPromise":True})
                time.sleep(.25)
        except Exception as ex:
            with self.lock:
                if self.serial==serial:
                    self.last_error="focus_"+type(ex).__name__
        finally:
            if browser:
                if old_window is not None:
                    try:
                        browser.request("Browser.setWindowBounds",{
                            "windowId":old_window,
                            "bounds":{"windowState":"maximized"}})
                    except Exception:pass
                browser.disconnect()

    def stop(self):
        with self.lock:
            self.run=False
            self.serial+=1
            self.source="idle"
            if self.ingest_socket:
                try:self.ingest_socket.close()
                except OSError:pass
                self.ingest_socket=None
            for sock in self.clients:
                try:sock.shutdown(socket.SHUT_RDWR)
                except OSError:pass
                try:sock.close()
                except OSError:pass
            self.clients.clear()
        return {"ok":True}

    def start(self):
        with self.lock:
            if self.run and ((self.encoder and self.encoder.poll() is None) or
                (self.source=="wayland" and self.ingest_socket is not None and
                 time.monotonic()-self.ingest_last<5)):
                return {"ok":True,"ready":True,"already_running":True,"source":self.source}
            for old in self.clients:
                try:old.close()
                except OSError:pass
            self.clients.clear()
            self.run=False
            self.serial+=1
            serial=self.serial
            if self.ingest_socket:
                try:self.ingest_socket.close()
                except OSError:pass
                self.ingest_socket=None
            self.last_error=""
            self.seq=0
            self.packet_count=0
            self.capture_count=0
            self.screenshot_attempts=0
            self.worker_errors=0
            self.latest_capture_started=0
            self.frame=None
            self._ready={}
            self.run=True
            self.source="wayland" if self.enable_wayland else "screenshot"
            self.start_at=time.monotonic()
            self.ingest_last=0.
        if self.source=="wayland":
            threading.Thread(target=self._focus_watch,args=(serial,),daemon=True).start()
        else:
            threading.Thread(target=self._stream,args=(serial,),daemon=True).start()
        deadline=time.monotonic()+18
        wayland_deadline=time.monotonic()+9
        fallback_started=self.source!="wayland" 
        while time.monotonic()<deadline:
            with self.lock:
                if self.packet_count>0:
                    return {"ok":True,"ready":True,"transport":"h264_direct_tcp",
                            "fps":FPS,"size":"1920x1080","source":self.source}
                error=self.last_error
            if not fallback_started and time.monotonic()>wayland_deadline:
                fallback_started=True
                with self.lock:
                    if self.ingest_socket:
                        try:self.ingest_socket.close()
                        except OSError:pass
                        self.ingest_socket=None
                    self.source="screenshot_fallback"
                    self.last_error=""
                threading.Thread(target=self._stream,args=(serial,),daemon=True).start()
            if error and fallback_started:break
            time.sleep(.10)
        return {"ok":False,"error":error or "timeout"}

    def status(self):
        with self.lock:
            return {"ok":True,"active":self.run,"encoded":self.packet_count,
                    "captured":self.capture_count,"connections":len(self.clients),
                    "source":self.source,"ingest_connected":self.ingest_socket is not None,
                    "last_error":self.last_error,"fps":FPS,
                    "elapsed":round(time.monotonic()-self.start_at,1) if self.run else 0,
                    "actual_encode_fps":round(self.packet_count/(time.monotonic()-self.start_at),1) if self.run and time.monotonic()>self.start_at else 0,
                    "actual_new_capture_fps":round(self.capture_count/(time.monotonic()-self.start_at),1) if self.run and time.monotonic()>self.start_at else 0,
                    "screenshot_attempts":self.screenshot_attempts,
                    "worker_errors":self.worker_errors}

    def _capture(self,browser,serial):
        # Use the SAME CDP session used for the initial 1080p screenshot.
        # Concurrent CDP Emulation sessions were observed to alternate source
        # pixels between 1x and 1.5x scale despite 1920x1080 JPEG wrappers.
        last_focus_check=0.0
        while True:
            with self.lock:
                if not self.run or serial!=self.serial:
                    return
            started=time.monotonic()
            try:
                # A Chromium/WebUI reload destroys our DOM-only NAS focus ring.
                # Restore the old mode if possible, without creating an ATV
                # overlay or changing the current iCloud album.
                if started-last_focus_check>1.2:
                    last_focus_check=started
                    focus=browser.request("Runtime.evaluate",{
                        "expression":"!!document.getElementById('__atv3_photos_focus_ring')",
                        "returnByValue":True})
                    if not focus.get("result",{}).get("value",False):
                        browser.request("Runtime.evaluate",{
                            "expression":SPATIAL_JS.replace("__ACTION__", "'resume'"),
                            "returnByValue":True,"awaitPromise":True})
                response=browser.request("Page.captureScreenshot",{
                    "format":"jpeg","quality":88,"fromSurface":True,
                    "captureBeyondViewport":False})
                data=base64.b64decode(response["data"])
                if not data.startswith(b"\xff\xd8") or len(data)>3500000 or jpeg_dimensions(data)!=(1920,1080):
                    raise ValueError("jpeg_geometry_invalid")
                with self.lock:
                    if serial!=self.serial or not self.run:
                        return
                    self.screenshot_attempts+=1
                    self.latest_capture_started=started
                    self.frame=data
                    self.capture_count+=1
                    self.latest_capture=time.monotonic()
            except Exception as ex:
                with self.lock:
                    self.worker_errors+=1
                    self.last_error="capture_"+type(ex).__name__
                browser.disconnect()
                time.sleep(.25)

    @staticmethod
    def _nals_from_annexb(data):
        # Input is an accumulated stream; return complete NALs only and the
        # unconsumed suffix. Strip both 3-byte/4-byte start codes.
        starts=[]
        n=len(data);i=0
        while i<n-3:
            if data[i]==0 and data[i+1]==0 and data[i+2]==1:
                starts.append((i,3));i+=3
            elif i<n-4 and data[i]==0 and data[i+1]==0 and data[i+2]==0 and data[i+3]==1:
                starts.append((i,4));i+=4
            else:i+=1
        if len(starts)<2:
            return [],data[-2000000:]
        nals=[]
        for k in range(len(starts)-1):
            a,alen=starts[k];b,_=starts[k+1]
            nal=data[a+alen:b]
            if nal and len(nal)<1000000:nals.append(nal)
        return nals,data[starts[-1][0]:]

    def _broadcast(self,nals):
        has_key=any((n[0]&31)==5 for n in nals)
        nalbytes=b"".join(struct.pack(">I",len(n))+n for n in nals)
        if not nalbytes:return
        with self.lock:
            self.seq+=1
            seq=self.seq
            self.packet_count+=1
            peers=list(self.clients)
        packet=struct.pack(">IIQ",len(nalbytes),seq,int(time.time()*1000))+nalbytes
        for sock in peers:
            if not self._ready.get(id(sock),False) and not has_key:
                continue
            try:
                sock.sendall(packet)
                # A socket object cannot always carry attrs, so each
                # connection receives IDRs whenever it joins.
                self._ready[id(sock)]=True
            except (OSError,TimeoutError):
                with self.lock:self.clients.discard(sock)
                try:sock.close()
                except OSError:pass

    def _stream(self,serial):
        browser=None;proc=None;capture_thread=None
        self._ready={}
        try:
            browser=Browser()
            browser.connect()
            # Explicitly restore the NAS HTML focus border when entering
            # direct H.264 playback; no local ATV GPU ring exists.
            browser.request("Runtime.evaluate",{
                "expression":"window.__atv3DirectNativeFocus=false; var ring=document.getElementById('__atv3_photos_focus_ring'); if(ring)ring.style.display='block'; true",
                "returnByValue":True})
            browser.request("Runtime.evaluate",{
                "expression":SPATIAL_JS.replace("__ACTION__", "(window.__atv3ResumeForUnlock?'resume':'init')"),
                "returnByValue":True,"awaitPromise":True})
            first=browser.request("Page.captureScreenshot",{
                "format":"jpeg","quality":89,"fromSurface":True,
                "captureBeyondViewport":False})
            self.frame=base64.b64decode(first["data"])
            if not self.frame.startswith(b"\xff\xd8") or jpeg_dimensions(self.frame)!=(1920,1080):
                raise ValueError("initial_jpeg_geometry_invalid")
            self.capture_count=1
            proc=subprocess.Popen([
                "/usr/bin/ffmpeg","-nostdin","-hide_banner","-loglevel","error",
                "-f","mjpeg","-framerate",str(FPS),"-i","pipe:0",
                "-an","-c:v","libx264","-preset","ultrafast",
                "-tune","zerolatency","-crf","18","-pix_fmt","yuv420p",
                "-profile:v","baseline","-level:v","4.0",
                "-x264-params","aud=1:repeat-headers=1:scenecut=0:bframes=0:keyint=8:min-keyint=8",
                "-r",str(FPS),"-f","h264","pipe:1"
            ],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,bufsize=0)
            with self.lock:self.encoder=proc;self.capture=browser
            capture_thread=threading.Thread(target=self._capture,args=(browser,serial),daemon=True)
            capture_thread.start()
            def output():
                try:
                    carry=b"";unit=[]
                    while True:
                        piece=os.read(proc.stdout.fileno(),65536)
                        if not piece:break
                        nals,carry=self._nals_from_annexb(carry+piece)
                        for nal in nals:
                            kind=nal[0]&31
                            if kind==9:  # Access-unit delimiter, one per frame
                                if unit:self._broadcast(unit)
                                unit=[]
                            elif kind in (1,5,6,7,8):
                                unit.append(nal)
                except Exception as ex:
                    with self.lock:self.last_error="output_"+type(ex).__name__
            thread=threading.Thread(target=output,daemon=True)
            thread.start()
            nexttime=time.monotonic()
            while True:
                with self.lock:
                    if not self.run or self.serial!=serial:break
                    frame=self.frame
                if proc.poll() is not None:
                    raise RuntimeError("ffmpeg_terminated")
                if frame:
                    proc.stdin.write(frame)
                nexttime+=1.0/FPS
                remaining=nexttime-time.monotonic()
                if remaining>0:time.sleep(remaining)
                elif remaining < -.5:nexttime=time.monotonic()
        except Exception as ex:
            with self.lock:self.last_error=type(ex).__name__+":"+str(ex)[:90]
        finally:
            with self.lock:
                if self.serial==serial:self.run=False
            if proc:
                try:proc.stdin.close()
                except Exception:pass
                try:proc.terminate();proc.wait(timeout=3)
                except Exception:
                    try:proc.kill()
                    except Exception:pass
            if capture_thread:
                capture_thread.join(timeout=2.5)
            if browser:
                try:
                    browser.request("Runtime.evaluate",{
                        "expression":"window.__atv3DirectNativeFocus=false; true",
                        "returnByValue":True})
                except Exception:pass
                browser.disconnect()
            with self.lock:
                if self.encoder is proc:self.encoder=None
                if self.capture is browser:self.capture=None

direct=Direct()

class Handler(BaseHTTPRequestHandler):
    def log_message(self,*a):pass
    def send(self,code,obj):
        buf=json.dumps(obj,separators=(",",":")).encode()
        self.send_response(code)
        self.send_header("Content-Type","application/json")
        self.send_header("Cache-Control","no-store")
        self.send_header("Content-Length",str(len(buf)))
        self.end_headers()
        self.wfile.write(buf)
    def authorized(self):
        return self.client_address[0] in ALLOWED and self.headers.get("X-ATV-Photos-Key","")==KEY
    def do_GET(self):
        if self.path=="/health":return self.send(200,direct.status())
        if not self.authorized():return self.send(403,{"ok":False})
        return self.send(404,{"ok":False})
    def do_POST(self):
        if not self.authorized():return self.send(403,{"ok":False})
        if self.path=="/start":
            r=direct.start()
            return self.send(200 if r["ok"] else 503,r)
        if self.path=="/stop":return self.send(200,direct.stop())
        return self.send(404,{"ok":False})
if __name__=="__main__":
    ThreadingHTTPServer((HOST,PORT_CONTROL),Handler).serve_forever()
