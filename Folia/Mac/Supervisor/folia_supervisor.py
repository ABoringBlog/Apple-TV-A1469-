#!/usr/bin/env python3
"""Folia ATV3 on-demand lifecycle. Keep Mac Folia state across TV sessions."""
import json
import os
from pathlib import Path
import signal
import subprocess
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

HOST = os.environ['FOLIA_ATV3_MAC_HOST']
ATV_IP = os.environ['FOLIA_ATV3_ATV_IP']
PORT = 18783
BRIDGE = 'http://' + HOST + ':18782'
HOME = Path.home()
APP = Path(os.environ.get('FOLIA_ATV3_APP', str(HOME / 'Applications/FoliaATV3.app/Contents/MacOS/Folia')))
LOCK = HOME / 'Library/Application Support/FoliaATV3/atv3-instance.pid'
LOG = HOME / 'Library/Logs/FoliaATV3/supervisor-app.log'
LIFELOG = HOME / 'Library/Logs/FoliaATV3/supervisor-lifecycle.log'
STATE_LOCK = threading.RLock()
latest_session = 0
suspended_session = 0

# These flags reproduce the known-good v33/v43 direct encoder invocation.
APP_ENV = {
    'FOLIA_ATV3_DIRECT': '1',
    'FOLIA_ATV3_FORCE_PAINT': '1',
    'FOLIA_ATV3_RENDER_FPS': '45',
    'FOLIA_ATV3_CAPTURE_THROTTLE_MS': '24',
    'FOLIA_ATV3_ENCODER_WORKER': '1',
    'FOLIA_ATV3_WORKER_NETWORK': '1',
    'FOLIA_ATV3_NATIVE_VT': '1',
    'FOLIA_ATV3_MAC_HOST': HOST,
    'FOLIA_ATV3_ATV_IP': ATV_IP,
    'FOLIA_ATV3_NATIVE_ENCODER': os.environ.get('FOLIA_ATV3_NATIVE_ENCODER', str(Path(__file__).resolve().parent.parent / 'Bridge/folia_native_vt1080_encoder')),
}

def record(message):
    LOG.parent.mkdir(parents=True, exist_ok=True)
    with LIFELOG.open('a', encoding='utf-8') as f:
        f.write(time.strftime('%Y-%m-%d %H:%M:%S') + ' ' + message + '\n')

def process_table():
    try:
        output = subprocess.run(
            ['/bin/ps', '-axo', 'pid=,ppid=,stat=,command='],
            capture_output=True, text=True, timeout=3, check=True
        ).stdout
        result = {}
        for line in output.splitlines():
            parts = line.split(None, 3)
            if len(parts) == 4:
                try:
                    pid, ppid = int(parts[0]), int(parts[1])
                    result[pid] = (ppid, parts[2], parts[3])
                except ValueError:
                    pass
        return result
    except (OSError, subprocess.SubprocessError):
        return {}

def pinfo(table=None):
    try:
        pid = int(LOCK.read_text().strip())
        if pid < 2:
            return None
        table = process_table() if table is None else table
        details = table.get(pid)
        # Never signal an unrelated PID recycled after a crash.
        if details and str(APP) in details[2] and not details[2].lstrip().startswith('sh '):
            return pid
    except (OSError, ValueError):
        pass
    return None

def family(pid, table):
    # Signal ONLY the verified Folia process and descendants, never its
    # process group: launchd can assign a shared PGID to unrelated services.
    collected = [pid]
    seen = {pid}
    while True:
        added = [p for p, d in table.items() if d[0] in seen and p not in seen]
        if not added:
            break
        collected += added
        seen.update(added)
    return collected

def is_suspended(pid=None, table=None):
    table = process_table() if table is None else table
    pid = pinfo(table) if pid is None else pid
    return bool(pid and pid in table and 'T' in table[pid][1])

def health(timeout=1.5):
    try:
        with urllib.request.urlopen(BRIDGE + '/health', timeout=timeout) as req:
            return json.load(req)
    except (OSError, ValueError):
        return None

def direct_ready(h):
    return bool(
        h and h.get('mode') == 'direct' and h.get('running') and
        h.get('workerNetworkReady') and h.get('nativeVTEncoder') and
        h.get('videoPort') == 18786 and
        h.get('encoderError') is None and
        h.get('framesEncoded', 0) >= 3
    )

def resume_tree(pid):
    table = process_table()
    members = family(pid, table)
    # Resume parent first; reconnect callbacks may then resume normally.
    for child in members:
        if child in table:
            try:
                os.kill(child, signal.SIGCONT)
            except ProcessLookupError:
                pass
    record('RESUME pid=%s members=%s' % (pid, members))

def suspend_tree(pid):
    table = process_table()
    members = family(pid, table)
    # Stop the helpers and encoder before the UI process to quiesce CPU.
    # Do not SIGKILL or terminate, so UI state and song queue survive.
    for child in reversed(members):
        if child in table:
            try:
                os.kill(child, signal.SIGSTOP)
            except ProcessLookupError:
                pass
    record('SUSPEND pid=%s members=%s' % (pid, members))
    return members

def start_app():
    if not APP.is_file():
        return {'ready': False, 'reason': 'dedicated Folia executable missing'}
    LOG.parent.mkdir(parents=True, exist_ok=True)
    with LOG.open('ab') as log:
        proc = subprocess.Popen(
            [str(APP)], stdin=subprocess.DEVNULL, stdout=log,
            stderr=subprocess.STDOUT, start_new_session=True,
            close_fds=True, env={**os.environ, **APP_ENV}
        )
    record('COLD_START spawned_pid=%s' % proc.pid)
    return proc.pid

def start():
    table = process_table()
    pid = pinfo(table)
    resumed = bool(pid and is_suspended(pid, table))
    cold = not bool(pid)
    if resumed:
        resume_tree(pid)
    if cold:
        result = start_app()
        if isinstance(result, dict):
            return result
    deadline = time.monotonic() + (27 if cold else 8)
    while time.monotonic() < deadline:
        table = process_table()
        pid = pinfo(table)
        if pid and not is_suspended(pid, table):
            h = health(timeout=1.0)
            if direct_ready(h):
                return {'ready': True, 'pid': pid, 'resumed': resumed,
                        'cold_started': cold, 'video_port': 18786}
        time.sleep(0.35)
    record('START_TIMEOUT pid=%s resumed=%s cold=%s' % (pid, resumed, cold))
    return {'ready': False, 'pid': pid, 'resumed': resumed,
            'cold_started': cold, 'reason': 'direct encoder not ready'}

def suspend():
    table = process_table()
    pid = pinfo(table)
    if not pid:
        return {'suspended': False, 'pid': None, 'reason': 'no live Folia process'}
    if is_suspended(pid, table):
        return {'suspended': True, 'pid': pid, 'already': True}
    members = suspend_tree(pid)
    return {'suspended': is_suspended(pid), 'pid': pid, 'members': len(members)}

def force_stop():
    table = process_table()
    pid = pinfo(table)
    if not pid:
        return {'stopped': True, 'pid': None}
    if is_suspended(pid, table):
        resume_tree(pid)
    # Explicit Mac maintenance only. Never triggered by ATV exit.
    for child in reversed(family(pid, process_table())):
        try:
            os.kill(child, signal.SIGTERM)
        except ProcessLookupError:
            pass
    record('FORCE_STOP pid=%s' % pid)
    return {'stopped': True, 'pid': pid}

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        global latest_session, suspended_session
        if self.client_address[0] not in (ATV_IP, HOST, '127.0.0.1'):
            self.send_response(403)
            self.end_headers()
            return
        parsed = urlsplit(self.path)
        params = parse_qs(parsed.query)
        try:
            requested_session = int(params['session'][0]) if 'session' in params else None
            if requested_session is not None and requested_session <= 0:
                raise ValueError('invalid session')
        except (ValueError, IndexError):
            return self.reply(400, {'error': 'invalid session'})
        path = parsed.path
        if path == '/status':
            table = process_table()
            pid = pinfo(table)
            paused = is_suspended(pid, table)
            response = {'pid': pid, 'suspended': paused,
                        'bridge': None if paused else health(),
                        'session': latest_session}
            return self.reply(200, response)
        if path not in ('/start', '/suspend', '/stop'):
            return self.reply(404, {'error': 'not found'})
        with STATE_LOCK:
            # ATV-generated epoch millisecond sessions reject stale out-of-order
            # background requests after a rapid Home -> reopen transition.
            session = (requested_session if requested_session is not None
                       else (int(time.time() * 1000) if path == '/start' else latest_session))
            if path == '/start':
                if session < latest_session or (session == suspended_session and session != 0):
                    response = {'ready': False, 'ignored': True, 'reason': 'stale or canceled activation'}
                    code = 409
                else:
                    latest_session = max(latest_session, session)
                    response = start()
                    code = 200 if response.get('ready') else 503
                record('START_REQUEST session=%s result=%s' % (session, response))
            elif path == '/stop' and self.client_address[0] != ATV_IP and params.get('force') == ['1']:
                response = force_stop()
                code = 200
            else:
                if requested_session is not None and session < latest_session:
                    response = {'suspended': False, 'ignored': True, 'reason': 'newer TV session active'}
                else:
                    latest_session = max(latest_session, session)
                    suspended_session = latest_session
                    response = suspend()
                code = 200
                record('SUSPEND_REQUEST session=%s result=%s' % (session, response))
        self.reply(code, response)

    def reply(self, status, content):
        body = json.dumps(content, ensure_ascii=False).encode('utf8')
        self.send_response(status)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, fmt, *args):
        print(time.strftime('%Y-%m-%d %H:%M:%S'),
              self.client_address[0], fmt % args, flush=True)

if __name__ == '__main__':
    record('SUPERVISOR_STARTED')
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print('Folia ATV3 suspend/resume supervisor', HOST, PORT, flush=True)
    server.serve_forever()
