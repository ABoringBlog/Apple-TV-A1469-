#!/usr/bin/env python3
"""Interactive credentials -> anonymous pipe; fixed output only."""
import argparse
import getpass
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import urlsplit

STAGES = ('configuration', 'public server information', 'authentication',
          'authenticated libraries', 'authenticated read-only library scan status', 'first media page', 'second media page',
          'media detail', 'poster download', 'backdrop download', 'local session cleared',
          'server logout and token invalidation', 'TLS rejects invalid certificate', 'offline transport', 'connection total deadline')
SKIPS = {'SKIP: media pagination (library ID not configured)',
         'SKIP: detail/artwork (item ID not configured)'}

def safe_output(data):
    for line in data.decode(errors='replace').splitlines():
        if line in SKIPS or any(re.fullmatch(r'(PASS|FAIL): ' + re.escape(stage) +
                                            r' \(error-code=-?[0-9]{1,6}\)', line) for stage in STAGES):
            print(line)

class Parser(argparse.ArgumentParser):
    def error(self, message):
        self.exit(2, 'FAIL: configuration (error-code=2)\n')

def main():
    parser = Parser()
    parser.add_argument('--url')
    parser.add_argument('--config', help='external JSON configuration file')
    parser.add_argument('--mode', choices=('server', 'probe', 'offline', 'timeout', 'tls-invalid'), default='server')
    parser.add_argument('--library', default='')
    parser.add_argument('--item', default='')
    parser.add_argument('--allow-http', action='store_true')
    parser.add_argument('--fixture', action='store_true')
    args = parser.parse_args()
    config = vars(args).copy()
    try:
        external = {}
        if args.config:
            raw = Path(args.config).read_bytes()
            if len(raw) > 65536: raise ValueError()
            external = json.loads(raw)
            if not isinstance(external, dict): raise ValueError()
        for key in ('url', 'username', 'password', 'token', 'library', 'item'):
            value = None if args.fixture else os.environ.get('JF_' + key.upper(), external.get(key))
            if value is not None:
                if not isinstance(value, str): raise ValueError()
                if not config.get(key): config[key] = value
        args.url = config.get('url')
        args.library = config.get('library', '')
        args.item = config.get('item', '')
        if config.get('token') and (config.get('username') or config.get('password')): raise ValueError()
    except (OSError, ValueError, TypeError):
        print('FAIL: configuration (error-code=2)')
        return 2
    if args.fixture:
        if args.url or args.mode != 'server':
            print('FAIL: configuration (error-code=2)')
            return 2
        config.update(url='http://fixture.invalid/jellyfin', username='测试用户',
                      password='p"ass', library='lib1', item='movie1')
    elif not args.url:
        print('NOT RUN: real server not configured (JF_URL or external config).')
        return 77
    try:
        url = urlsplit(config['url'])
        valid = (url.scheme in ('http', 'https') and url.hostname and not url.username
                 and not url.password and not url.query and not url.fragment
                 and (url.port is None or 1 <= url.port <= 65535)
                 and not any(c.isspace() or ord(c) < 32 for c in config['url']))
    except ValueError:
        valid = False
    if not valid or any(value and not re.fullmatch(r'[A-Za-z0-9_-]+', value)
                        for value in (args.library, args.item)) or (args.mode == 'tls-invalid' and url.scheme != 'https'):
        print('FAIL: configuration (error-code=2)')
        return 2
    if not args.fixture and url.scheme == 'http' and not args.allow_http:
        print('BLOCKED: HTTP requires explicit --allow-http.')
        return 77
    if not args.fixture and args.mode == 'server' and not config.get('token') and not ('username' in config and 'password' in config):
        if not sys.stdin.isatty():
            print('BLOCKED: interactive terminal required for credentials.')
            return 77
        try:
            config['username'] = getpass.getpass('Test username (hidden): ')
            config['password'] = getpass.getpass('Test password (hidden): ')
        except (EOFError, KeyboardInterrupt):
            print('BLOCKED: credential input cancelled.')
            return 77
    try:
        result = subprocess.run(['build/integration'], input=json.dumps(config).encode(), timeout=90,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        safe_output(result.stdout)
        code = result.returncode if result.returncode in (0, 1, 2, 77) else 1
        if code:
            print('Integration harness exit:', code)
        return code
    except (subprocess.TimeoutExpired, OSError):
        print('FAIL: integration harness unavailable or deadline exceeded')
        return 1

if __name__ == '__main__':
    sys.exit(main())
