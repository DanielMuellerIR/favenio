"""Echte Pakete im privaten XDG-Verzeichnis installieren, aktualisieren und zurücknehmen.

Nur kurzlebige Testschlüssel; die veränderten Prüfpakete werden nie ausgeliefert.
"""
import base64
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile


def main():
    inputs=[Path(argument).resolve() for argument in sys.argv[1:]]
    assert len(inputs)==2
    with tempfile.TemporaryDirectory(prefix='favenio-package-probe-') as directory:
        root=Path(directory);key=root/'ephemeral-test-only.pem'
        subprocess.run(['/usr/bin/openssl','genpkey','-algorithm','ED25519','-out',str(key)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        public=base64.b64encode(subprocess.check_output(['/usr/bin/openssl','pkey','-in',str(key),'-pubout','-outform','DER'],stderr=subprocess.DEVNULL)[-32:])+b'\n'
        packages=[]
        for index,source in enumerate(inputs):
            destination=root/('source-'+str(index));destination.mkdir()
            # Die Eingaben sind eigene Build-Artefakte, keine fremden Downloads.
            with tarfile.open(source,'r:gz') as archive:archive.extractall(destination,filter='data')
            folder=next(destination.iterdir());version=(folder/'VERSION').read_text().strip()
            (folder/'update/public-key.txt').write_bytes(public)
            package=root/('test-only-'+version+'.tar.gz')
            with tarfile.open(package,'w:gz',dereference=True) as archive:archive.add(folder,arcname='favenio-'+version)
            data=json.dumps(dict(schemaVersion=1,platform='linux-x86_64',version=version,engineVersion=version,size=package.stat().st_size,sha256=hashlib.sha256(package.read_bytes()).hexdigest(),url='https://github.com/DanielMuellerIR/favenio/releases/download/v'+version+'/favenio.tar.gz')).encode()
            manifest=root/(version+'.json');manifest.write_bytes(data)
            message=root/'message';message.write_bytes(b'Favenio Linux Update v1\n'+data)
            signature=root/(version+'.sig');raw=root/'raw-signature'
            subprocess.run(['/usr/bin/openssl','pkeyutl','-sign','-rawin','-inkey',str(key),'-in',str(message),'-out',str(raw)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            signature.write_bytes(base64.b64encode(raw.read_bytes()))
            packages.append((folder,version,package,manifest,signature))
        data_home=root/'data';environment=dict(os.environ,XDG_DATA_HOME=str(data_home),XDG_STATE_HOME=str(root/'state'))
        installation=data_home/'favenio'
        for index,(folder,version,package,manifest,signature) in enumerate(packages):
            result=subprocess.run([sys.executable,'-B',str(folder/'install.py'),str(package),str(manifest),str(signature)],env=environment,capture_output=True,timeout=40)
            assert result.returncode==0,result.stderr
            assert (installation/'current').resolve().name==version
            if index == 1:
                with (installation/'lifecycle.lock').open('r+') as lock:
                    fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
                    blocked=subprocess.run([str(installation/'bin/favenio'),'--self-test'],env=environment,capture_output=True,timeout=10)
                    assert blocked.returncode!=0,blocked.stdout

            for quick in [False,True]:
                launch=installation/'bin'/('favenio-quick' if quick else 'favenio')
                result=subprocess.run([str(launch),'--self-test'],env=environment,capture_output=True,timeout=15)
                assert result.returncode==0,result.stderr
            assert (data_home/'applications/org.favenio.Main.desktop').is_file()
            if index==1:assert (installation/'current/icons/org.favenio.Main.png').read_bytes().startswith(b'\x89PNG')
            assert (data_home/'nemo-python/extensions/favenio_nemo.py').is_file()
            assert (data_home/'nemo-python/extensions/favenio_nemo.py').read_bytes()==(folder/'integration/favenio_nemo.py').read_bytes()
            assert (data_home/'kio/servicemenus/favenio-quick.desktop').is_file()
        old_version=packages[0][1];new_version=packages[1][1]
        result=subprocess.run([str(installation/'current/helpers/favenio-update'),'--rollback'],env=environment,capture_output=True,timeout=15)
        assert result.returncode==0,result.stderr
        assert (installation/'current').resolve().name==old_version
        assert (data_home/'nemo-python/extensions/favenio_nemo.py').read_bytes()==(packages[0][0]/'integration/favenio_nemo.py').read_bytes()
        assert json.loads((installation/'update-state.json').read_text())['highestVersion']==new_version
        result=subprocess.run([sys.executable,'-B',str(installation/'versions'/new_version/'uninstall.py'),'--yes'],env=environment,capture_output=True,timeout=15)
        assert result.returncode==0,result.stderr
        assert not installation.exists()
        assert not (data_home/'applications/org.favenio.Main.desktop').exists()
        print('LINUX PACKAGE OK: real '+old_version+' → '+new_version+'; both launchers, isolated desktop adapters, verified rollback, new uninstaller, process lease; ephemeral test key only')


if __name__=='__main__':main()
