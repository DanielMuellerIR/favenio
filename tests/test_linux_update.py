"""Vertrauensgrenze: manipulierte Downloads dürfen keinen Versionswechsel auslösen."""
import base64
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('linux_update',Path(__file__).resolve().parents[1]/'linux/update/coordinator.py')
update=importlib.util.module_from_spec(spec);spec.loader.exec_module(update)


@unittest.skipUnless(sys.platform.startswith('linux'),'OpenSSL-3-Verifikation der Linux-Auslieferung')
class UpdateTrustTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='favenio-updater-test-');self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);self.installation=self.root/'installation'
        environment=patch.dict(os.environ,XDG_DATA_HOME=str(self.root/'data'))
        environment.start();self.addCleanup(environment.stop)
        self.key=self.root/'private.pem'
        subprocess.run(['/usr/bin/openssl','genpkey','-algorithm','ED25519','-out',str(self.key)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        public=subprocess.check_output(['/usr/bin/openssl','pkey','-in',str(self.key),'-pubout','-outform','DER'],stderr=subprocess.DEVNULL)[-32:]
        self.public=base64.b64encode(public)

    def manifest(self,package,version):
        value=dict(schemaVersion=1,platform='linux-x86_64',version=version,engineVersion=version,size=package.stat().st_size,sha256=hashlib.sha256(package.read_bytes()).hexdigest(),url='https://github.com/DanielMuellerIR/favenio/releases/download/v'+version+'/favenio.tar.gz')
        return self.sign(json.dumps(value).encode())

    def sign(self,data):
        message=self.root/'message';signature=self.root/'signature';message.write_bytes(update.CONTEXT+data)
        subprocess.run(['/usr/bin/openssl','pkeyutl','-sign','-rawin','-inkey',str(self.key),'-in',str(message),'-out',str(signature)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        return data,base64.b64encode(signature.read_bytes())

    def package(self,version='1.0.0',bad=None):
        path=self.root/(version+'.tar.gz')
        values={'favenio':b'fake binary','favenio.py':('print("favenio '+version+'")\n').encode(),'libfavenio-shared.so':b'shared','launch':b'#!/bin/sh\nexit 0\n','VERSION':version.encode(),'helpers/favenio-update':b'update','update/public-key.txt':self.public}
        values['install.py']=('from pathlib import Path\nimport os\ndef integration(root):\n p=Path(os.environ["XDG_DATA_HOME"])/"adapter-version"\n p.parent.mkdir(parents=True,exist_ok=True)\n p.write_text('+repr(version)+')\n').encode()
        with tarfile.open(path,'w:gz') as archive:
            for name,data in values.items():
                member=tarfile.TarInfo('favenio-'+version+'/'+name);member.size=len(data);member.mode=0o755 if name=='launch' else 0o644;archive.addfile(member,io.BytesIO(data))
            if bad:
                member=tarfile.TarInfo(bad)
                if 'link' in bad:member.type=tarfile.SYMTYPE;member.linkname='/tmp'
                archive.addfile(member,io.BytesIO())
        return path

    def test_signed_upgrade_and_verified_rollback_preserve_monotonic_floor(self):
        for version in ['1.0.0','1.0.1']:
            package=self.package(version);data,signature=self.manifest(package,version)
            self.assertEqual(update.install(self.installation,package,data,signature,self.public),version)
            self.assertEqual((self.installation/'current').resolve().name,version)
            self.assertEqual((self.root/'data/adapter-version').read_text(),version)
        self.assertEqual(update.rollback(self.installation,self.public),'1.0.0')
        self.assertEqual((self.root/'data/adapter-version').read_text(),'1.0.0')
        package=self.package('1.0.0');data,signature=self.manifest(package,'1.0.0')
        with self.assertRaises(update.UpdateError):update.install(self.installation,package,data,signature,self.public)
        self.assertEqual((self.installation/'current').resolve().name,'1.0.0')

    def test_tampered_manifest_and_package_never_switch(self):
        package=self.package();data,signature=self.manifest(package,'1.0.0')
        with self.assertRaises(update.UpdateError):update.install(self.installation,package,data.replace(b'1.0.0',b'1.0.1'),signature,self.public)
        package.write_bytes(package.read_bytes()+b'tamper')
        with self.assertRaises(update.UpdateError):update.install(self.installation,package,data,signature,self.public)
        self.assertFalse((self.installation/'current').exists())

    def test_even_signed_archives_cannot_escape_through_paths_or_links(self):
        for bad in ['../escaped','/absolute','favenio-1.0.0/../../escaped','favenio-1.0.0/link']:
            package=self.package(bad=bad);data,signature=self.manifest(package,'1.0.0')
            with self.assertRaises(update.UpdateError,msg=bad):update.install(self.installation,package,data,signature,self.public)
            self.assertFalse((self.installation/'current').exists())
        self.assertFalse((self.root/'escaped').exists())

    def test_failed_runtime_probe_keeps_old_version(self):
        package=self.package();data,signature=self.manifest(package,'1.0.0');update.install(self.installation,package,data,signature,self.public)
        package=self.package('1.0.1')
        # Eine fehlende Laufzeit wird unabhängig vom Archivbau als echter Kindprozessfehler geprüft.
        original=update.subprocess.run
        from unittest.mock import patch
        def failed(arguments,**kwargs):
            if arguments[-1]=='--self-test':return subprocess.CompletedProcess(arguments,2,b'',b'missing GTK')
            return original(arguments,**kwargs)
        data,signature=self.manifest(package,'1.0.1')
        with patch.object(update.subprocess,'run',side_effect=failed):
            with self.assertRaises(update.UpdateError):update.install(self.installation,package,data,signature,self.public)
        self.assertEqual((self.installation/'current').resolve().name,'1.0.0')

    def test_interrupted_atomic_switch_recovers_verified_pending_version(self):
        from unittest.mock import patch
        package=self.package();data,signature=self.manifest(package,'1.0.0')
        with patch.object(update,'switch',side_effect=OSError('simulierter Stromausfall')):
            with self.assertRaises(OSError):update.install(self.installation,package,data,signature,self.public)
        self.assertFalse((self.installation/'current').exists())
        self.assertEqual(update.recover(self.installation,self.public),'1.0.0')
        self.assertEqual((self.installation/'current').resolve().name,'1.0.0')
        state=json.loads((self.installation/'update-state.json').read_text())
        self.assertNotIn('pendingVersion',state)
        self.assertEqual(state['highestVersion'],'1.0.0')

    def test_concurrent_install_cannot_change_current_version(self):
        import fcntl
        self.installation.mkdir(mode=0o700)
        with (self.installation/'update.lock').open('w') as lock:
            fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
            package=self.package();data,signature=self.manifest(package,'1.0.0')
            with self.assertRaises(update.UpdateError):update.install(self.installation,package,data,signature,self.public)
        self.assertFalse((self.installation/'current').exists())

    def test_interrupted_rollback_refresh_recovers_adapters_and_keeps_floor(self):
        for version in ['1.0.0','1.0.1']:
            package=self.package(version);data,signature=self.manifest(package,version)
            update.install(self.installation,package,data,signature,self.public)
        with patch.object(update,'refresh_integration',side_effect=OSError('simulierter Stromausfall')):
            with self.assertRaises(OSError):update.rollback(self.installation,self.public)
        state=json.loads((self.installation/'update-state.json').read_text())
        self.assertEqual(state['pendingVersion'],'1.0.0')
        self.assertEqual(update.recover(self.installation,self.public),'1.0.0')
        self.assertEqual((self.root/'data/adapter-version').read_text(),'1.0.0')
        state=json.loads((self.installation/'update-state.json').read_text())
        self.assertEqual(state['highestVersion'],'1.0.1')
        self.assertNotIn('pendingVersion',state)

    def test_both_apps_share_one_daily_network_check_reservation(self):
        import fcntl
        from importlib.machinery import SourceFileLoader
        loader=SourceFileLoader('linux_update_helper',str(Path(__file__).resolve().parents[1]/'linux/helpers/favenio-update'))
        helper_spec=importlib.util.spec_from_loader(loader.name,loader)
        helper=importlib.util.module_from_spec(helper_spec);loader.exec_module(helper)
        state=self.root/'daily-state'
        self.assertTrue(helper.reserve_daily_check(state,100000))
        self.assertFalse(helper.reserve_daily_check(state,100001))
        self.assertTrue(helper.reserve_daily_check(state,200000))
        with (state/'daily-update-check').open('r+') as lock:
            fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
            self.assertFalse(helper.reserve_daily_check(state,300000))

    def test_uninstall_refuses_running_apps_then_removes_own_installation(self):
        import shutil
        data=self.root/'data';root=data/'favenio';root.mkdir(mode=0o700,parents=True)
        version=root/'versions/1.0.0';version.mkdir(parents=True)
        uninstall=version/'uninstall.py'
        shutil.copyfile(Path(__file__).resolve().parents[1]/'linux/uninstall.py',uninstall)
        (version/'update').mkdir()
        shutil.copyfile(Path(__file__).resolve().parents[1]/'linux/update/coordinator.py',version/'update/coordinator.py')
        (root/'current').symlink_to('versions/1.0.0')
        launcher=version/'active-app';launcher.write_text('#!/usr/bin/python3 -B\nimport fcntl,time\nfrom pathlib import Path\nroot=Path('+repr(str(root))+')\nlease=(root/"lifecycle.lock").open("w")\nfcntl.flock(lease,fcntl.LOCK_SH)\n(root/"running").touch()\ntime.sleep(30)\n');launcher.chmod(0o700)
        process=subprocess.Popen([str(launcher)],start_new_session=True)
        environment=dict(os.environ,XDG_DATA_HOME=str(data))
        import time
        deadline=time.monotonic()+5
        while not (root/'running').exists() and time.monotonic()<deadline:time.sleep(.01)
        self.assertTrue((root/'running').exists())
        try:
            result=subprocess.run([sys.executable,'-B',str(uninstall),'--yes'],env=environment,capture_output=True,timeout=5)
            self.assertNotEqual(result.returncode,0);self.assertTrue(root.exists())
        finally:
            import signal
            os.killpg(process.pid,signal.SIGTERM);process.wait()
        result=subprocess.run([sys.executable,'-B',str(uninstall),'--yes'],env=environment,capture_output=True,timeout=5)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertFalse(root.exists())


if __name__=='__main__':unittest.main()
