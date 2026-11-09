"""Sichtbares GTK-Fenster über seinen echten lokalen Steuerungsvertrag prüfen."""
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import time
import uuid


def main():
    launcher=Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory(prefix='favenio-gui-probe-') as directory:
        root=Path(directory);runtime=root/'runtime';runtime.mkdir(mode=0o700);fixture=root/'fixture';fixture.mkdir()
        for name in ['needle-first.txt','needle-second.txt']:(fixture/name).write_text('needle content\n')
        environment=dict(os.environ,XDG_RUNTIME_DIR=str(runtime),GTK_A11Y='none')
        log=(root/'app.log').open('wb')
        process=subprocess.Popen([str(launcher),'--directory',str(fixture)],env=environment,stdout=log,stderr=subprocess.STDOUT)
        endpoint=runtime/'org.favenio.Main.search-control.v1.sock'
        def read(stream,size):
            result=b''
            while len(result)<size:
                chunk=stream.recv(size-len(result))
                if not chunk:raise RuntimeError('vorzeitiges Socketende')
                result+=chunk
            return result
        def call(operation,**fields):
            request=dict(version=1,id=str(uuid.uuid4()),deadline=time.time()+8,operation=operation,**fields)
            with socket.socket(socket.AF_UNIX) as stream:
                stream.settimeout(9);stream.connect(str(endpoint));data=json.dumps(request).encode();stream.sendall(struct.pack('!I',len(data))+data)
                size=struct.unpack('!I',read(stream,4))[0];assert size<=1048576
                return json.loads(read(stream,size))
        try:
            deadline=time.monotonic()+10
            while not endpoint.exists() and time.monotonic()<deadline:
                if process.poll() is not None:raise RuntimeError((root/'app.log').read_text())
                time.sleep(.05)
            capabilities=call('capabilities');assert 'error' not in capabilities,capabilities
            binding=dict(runtimeID=capabilities['runtimeID'],windowID=capabilities['windowID'])
            configured=call('configure',configuration=dict(pattern='needle',root=str(fixture),options=[dict(name='mode',value='content')]),**binding)
            assert 'error' not in configured,configured
            started=call('start',**binding);assert 'error' not in started,started
            deadline=time.monotonic()+15
            while time.monotonic()<deadline:
                state=call('status')['status']
                if state['state']!='running':break
                time.sleep(.05)
            assert state['state']=='completed' and state['count']==2,state
            run=state['runID'];page=call('results',runID=run,offset=0,limit=128)
            assert len(page['hits'])==2,page
            hit=page['hits'][0].get('hit',page['hits'][0])
            identity={key:hit[key] for key in ['filesystemPath','archiveMembers','filesystemPathBytes'] if key in hit};identity['archiveMemberBytes']=hit.get('archiveMemberBytes',[])
            selected=call('select',runID=run,identity=identity,**binding);assert 'error' not in selected,selected
            captured=call('captureRecording',runID=run);assert 'error' not in captured,captured
            opened=call('openRecording',recording=captured['recording'],**binding);assert 'error' not in opened,opened
            assert opened['status']['state']=='recorded',opened
            restored=call('captureRecording',runID=opened['status']['runID']);assert restored.get('error'),restored
            stale=call('cancel',runID=run,**binding);assert stale.get('error',{}).get('code')=='stale',stale
            bad=call('configure',configuration=dict(pattern='bad',root=str(fixture),options=[]),runtimeID=str(uuid.uuid4()),windowID=binding['windowID']);assert bad.get('error',{}).get('code')=='stale',bad
            (fixture/'prefix needle suffix.txt').write_text('space-preserving query')
            spaced=call('configure',configuration=dict(pattern=' needle ',root=str(fixture),options=[]),**binding);assert 'error' not in spaced,spaced
            assert call('configuration')['configuration']['pattern']==' needle '
            started=call('start',**binding);assert 'error' not in started,started
            deadline=time.monotonic()+10
            while time.monotonic()<deadline:
                state=call('status')['status']
                if state['state']!='running':break
                time.sleep(.05)
            assert state['state']=='completed' and state['count']==3,state
            captured=call('captureRecording',runID=state['runID']);assert captured['recording']['configuration']['pattern']=='needle',captured
            offline=subprocess.run([str(launcher.parent/'helpers/favenio-control'),'--capabilities','--json'],env=environment,capture_output=True,timeout=10)
            assert offline.returncode==0,offline.stderr
            assert json.loads(offline.stdout)['maximumRequestBytes']==262144
            print('GTK CONTROL OK: visible search, paged byte identities, selection, recording, stale binding, offline capabilities')
        finally:
            process.terminate()
            try:process.wait(timeout=5)
            except subprocess.TimeoutExpired:process.kill();process.wait()
            log.close()


if __name__=='__main__':main()
