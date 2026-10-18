#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import hashlib
import unittest
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('deploy', 'Scripts/device-deploy.py')
deploy=importlib.util.module_from_spec(spec); spec.loader.exec_module(deploy)

class DeploymentTests(unittest.TestCase):
    def args(self, action='connect', *extra):
        return deploy.parser().parse_args([action, '--host', 'atv3-test', *extra])
    def test_no_network_by_default(self):
        for action in deploy.ACTIONS:
            if action in ('upload','install'): continue
            with self.subTest(action=action), patch('subprocess.run', side_effect=AssertionError('network forbidden')):
                import contextlib, io
                with contextlib.redirect_stdout(io.StringIO()): self.assertEqual(deploy.main([action,'--host','atv3-test']),0)
    def test_mutation_requires_explicit_flags(self):
        for action in deploy.MUTATING:
            with self.assertRaises(ValueError): deploy.validate(self.args(action, '--execute'))
    def test_host_injection_rejected(self):
        for host in ('-oProxyCommand=x','root@host;reboot','$(touch x)','a b','user:password@host'):
            a=self.args(); a.host=host
            with self.assertRaises(ValueError): deploy.validate(a)
    def test_run_id_and_port(self):
        for name in ('../x','x;reboot','', '-x'):
            with self.assertRaises(ValueError): deploy.validate(self.args('connect','--run-id='+name))
        with self.assertRaises(ValueError): deploy.validate(self.args('connect','--port','0'))
    def test_remote_script_syntax_and_gates(self):
        for action in deploy.ACTIONS:
            a=self.args(action)
            code=deploy.script(a,'a'*64,'0.5.0-predevice1')
            result=subprocess.run(['sh','-n'],input=code.encode(),capture_output=True)
            self.assertEqual(result.returncode,0,action)
            self.assertNotIn('reboot',code); self.assertNotIn('killall',code)
            if action in ('install','rollback','uninstall','upload'): self.assertIn('BACKUP_VERIFIED',code)
            if action in ('backup','upload','install','rollback','uninstall'):
                self.assertIn('apt-get check',code)
                self.assertIn('test -d /Applications/AppleTV.app',code)
                self.assertNotIn('test -z "$(dpkg --audit)"',code)
                self.assertNotIn(' | awk ',code)
            if action=='install': self.assertIn('hash_file candidate.deb',code)
    def test_removal_and_rollback_local_simulation(self):
        # Execute generated shell only with a temporary filesystem and fake dpkg; never SSH.
        for action, previous in [('uninstall', ''), ('rollback', ''), ('rollback', 'install ok installed 0.5.0-predevice1')]:
            with self.subTest(action=action, previous=previous), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                payload = root/'Applications/Jellyfin.frappliance'
                entry = root/'Applications/AppleTV.app/Appliances/Jellyfin.frappliance'
                payload.mkdir(parents=True); (payload/'Jellyfin').write_text('candidate')
                entry.parent.mkdir(parents=True); entry.symlink_to(payload)
                backup = root/'backup'; backup.mkdir(); (backup/'BACKUP_VERIFIED').touch()
                (backup/'before-state').write_text(previous)
                (backup/'rollback.deb').write_bytes(b'previous-package')
                (backup/'rollback.sha256').write_text(hashlib.sha256(b'previous-package').hexdigest())
                a = self.args(action)
                code = deploy.script(a).replace(deploy.remote_dir(a), str(backup)).replace('/Applications', str(root/'Applications'))
                # Keep set -e and all backup/hash/path gates; replace OS/package commands only.
                code = code.replace('dpkg-query', 'fixture_query')
                code = code.replace('apt-get check >/dev/null 2>&1', 'true')
                code = code.replace('test "$(id -u)" = 0', 'true')
                stub = """dpkg() {
 case "$1" in
 --print-architecture) echo iphoneos-arm ;;
 --audit) : ;;
 --field) echo 0.5.0-predevice1 ;;
 --remove) rm -f "$test_entry" "$test_payload/Jellyfin"; rmdir "$test_payload" ;;
 -i) printf old > "$test_payload/Jellyfin" ;;
 *) return 90 ;;
 esac
}
fixture_query() {
 case "$*" in
 *'${Status} ${Version}'*) printf '%s' 'install ok installed 0.5.0-predevice1' ;;
 *'${Status}'*) printf '%s' 'install ok installed' ;;
 *) printf '%s' 'org.jellyfin.atv3: fixture' ;;
 esac
}
"""
                import shlex
                prelude = 'test_payload='+shlex.quote(str(payload))+'\ntest_entry='+shlex.quote(str(entry))+'\n'+stub
                result = subprocess.run(['sh'], input=(prelude+code).encode(), capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr.decode())
                if previous:
                    self.assertEqual((payload/'Jellyfin').read_text(), 'old')
                    self.assertEqual(entry.resolve(), payload.resolve())
                else:
                    self.assertFalse(payload.exists()); self.assertFalse(entry.is_symlink())

    def test_log_collection_opt_in(self):
        self.assertNotIn('tail -n',deploy.script(self.args('crashes')))
        self.assertIn('tail -n',deploy.script(self.args('crashes','--include-sensitive-logs')))
    def test_original_candidate_hash_is_checked(self):
        path=Path('build/package-phase4e-final/org.jellyfin.atv3_0.4.0-test1_iphoneos-arm.deb')
        with self.assertRaises(ValueError): deploy.verify_package(path,'0'*64)
        self.assertEqual(deploy.verify_package(path)[1],'0.4.0-test1')

if __name__=='__main__': unittest.main()
