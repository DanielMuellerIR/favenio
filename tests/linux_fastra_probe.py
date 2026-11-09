"""Echte Fastra-Übernahme von Datei und Archiv; nur in freigegebener Desktop-Sitzung."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import uuid
import zipfile
from linux_shared_probe import SharedModelTests


def main():
    folder=Path(sys.argv[1]).resolve();control=Path(sys.argv[2]).resolve()
    os.environ['FAVENIO_ENGINE']=str(folder/'favenio.py')
    os.environ['FAVENIO_SHARED_LIBRARY']=str(folder/'libfavenio-shared.so')
    SharedModelTests.setUpClass();model=SharedModelTests()
    sessions=[]
    def remote(operation,**fields):
        request=dict(version=1,id=str(uuid.uuid4()),deadline=time.time()+8,operation=operation,**fields)
        result=subprocess.run([str(control),'--no-launch','--request','-'],input=json.dumps(request).encode(),capture_output=True,timeout=10)
        value=json.loads(result.stdout)
        assert result.returncode==0,value
        return value
    try:
        with tempfile.TemporaryDirectory(prefix='favenio-fastra-e2e-') as directory:
            root=Path(directory);data='👋 needle Straße\r\n'.encode()
            (root/'native.txt').write_bytes(data)
            with zipfile.ZipFile(root/'bundle.zip','w') as archive:archive.writestr('inside.txt',data)
            started=model.call(operation='start',pattern='needle',roots=[str(root)],options=[dict(name='mode',value='content'),dict(name='archives',value='1')])
            hits,_=model.finish(started);assert len(hits)==2,hits
            for index,hit in enumerate(hits):
                job=model.call(operation='fastra',index=index);assert job['ok'],job
                deadline=time.monotonic()+32
                while time.monotonic()<deadline:
                    result=model.call(operation='fastraStatus',jobID=job['handoff']['id'])['handoff']
                    if result['state'] in ['ready','failed','cancelled']:break
                    time.sleep(.05)
                assert result['state']=='ready',result
                receipt=result['fastra'];sessions.append(receipt['sessionID'])
                assert receipt['adopted'] and receipt['sha256']==hashlib.sha256(data).hexdigest(),receipt
                assert receipt['textSHA256']==hashlib.sha256(data).hexdigest(),receipt
                # Der Übergabevertrag markiert die ganze Fundzeile ohne CRLF.
                assert receipt['selection']==dict(location=0,length=16),receipt
                provenance=receipt['provenance']
                assert set(provenance['hitIdentity'])=={'filesystemPath','archiveMembers','archiveMemberBytes'},provenance
                member=bool(json.loads(hit['raw'])['hit']['archiveMembers'])
                assert provenance['kind']==('archiveMaterialization' if member else 'original'),provenance
                assert provenance['positionBinding']=='exactUTF16',provenance
                if member:assert provenance['outerSHA256']==hashlib.sha256((root/'bundle.zip').read_bytes()).hexdigest(),provenance
                runtime=remote('capabilities')['runtimeID']
                remote('close',sessionID=sessions.pop(),runtimeID=runtime)
    finally:
        if sessions:
            runtime=remote('capabilities')['runtimeID']
            for session in sessions:remote('close',sessionID=session,runtimeID=runtime)
        model.call(operation='cleanup')
    print('FASTRA E2E OK: native and archive snapshots, raw/text hashes, UTF-16 selection and confirmed provenance')


if __name__=='__main__':main()
