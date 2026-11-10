"""Tatsächliche X11-Eingabe in Quick und Übergabe in das Hauptfenster."""
import ctypes as c
import json
import os
from pathlib import Path
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time
import uuid


def main():
    x=c.CDLL('libX11.so.6');xt=c.CDLL('libXtst.so.6')
    x.XOpenDisplay.restype=c.c_void_p
    x.XDefaultRootWindow.argtypes=[c.c_void_p];x.XDefaultRootWindow.restype=c.c_ulong
    x.XQueryTree.argtypes=[c.c_void_p,c.c_ulong,c.POINTER(c.c_ulong),c.POINTER(c.c_ulong),c.POINTER(c.POINTER(c.c_ulong)),c.POINTER(c.c_uint)]
    x.XGetGeometry.argtypes=[c.c_void_p,c.c_ulong,c.POINTER(c.c_ulong),c.POINTER(c.c_int),c.POINTER(c.c_int),c.POINTER(c.c_uint),c.POINTER(c.c_uint),c.POINTER(c.c_uint),c.POINTER(c.c_uint)]
    x.XSetInputFocus.argtypes=[c.c_void_p,c.c_ulong,c.c_int,c.c_ulong]
    x.XStringToKeysym.argtypes=[c.c_char_p];x.XStringToKeysym.restype=c.c_ulong
    x.XKeysymToKeycode.argtypes=[c.c_void_p,c.c_ulong];x.XKeysymToKeycode.restype=c.c_uint
    x.XFlush.argtypes=[c.c_void_p];x.XFree.argtypes=[c.c_void_p]
    xt.XTestFakeKeyEvent.argtypes=[c.c_void_p,c.c_uint,c.c_int,c.c_ulong]
    xt.XTestFakeMotionEvent.argtypes=[c.c_void_p,c.c_int,c.c_int,c.c_int,c.c_ulong]
    xt.XTestFakeButtonEvent.argtypes=[c.c_void_p,c.c_uint,c.c_int,c.c_ulong]
    display=x.XOpenDisplay(None);assert display
    def key(name,down):xt.XTestFakeKeyEvent(display,x.XKeysymToKeycode(display,x.XStringToKeysym(name.encode())),down,0);x.XFlush(display)
    def window_with_width(width):
        parent=c.c_ulong();root=c.c_ulong();items=c.POINTER(c.c_ulong)();count=c.c_uint()
        x.XQueryTree(display,x.XDefaultRootWindow(display),c.byref(root),c.byref(parent),c.byref(items),c.byref(count))
        found=None
        for index in range(count.value):
            xx=c.c_int();yy=c.c_int();w=c.c_uint();h=c.c_uint();border=c.c_uint();depth=c.c_uint()
            x.XGetGeometry(display,items[index],c.byref(root),c.byref(xx),c.byref(yy),c.byref(w),c.byref(h),c.byref(border),c.byref(depth))
            if w.value==width and h.value>=500:found=items[index]
        x.XFree(items)
        return found
    with tempfile.TemporaryDirectory(prefix='favenio-input-probe-') as directory:
        root=Path(directory);runtime=root/'runtime';runtime.mkdir(mode=0o700);fixture=root/'fixture';fixture.mkdir()
        for name in ['needle-first.txt ','needle-second.txt','other.txt']:(fixture/name).write_text('example\n')
        environment=dict(os.environ,XDG_RUNTIME_DIR=str(runtime),GTK_A11Y='none')
        log=(root/'app.log').open('wb')
        require_scope='--require-scope' in sys.argv[2:]
        command=[str(Path(sys.argv[1]).resolve()),'--quick']+([] if require_scope else ['--directory',str(fixture)])
        process=subprocess.Popen(command,cwd=fixture,env=environment,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
        try:
            required_width=680 if require_scope else 700
            window=None;deadline=time.monotonic()+8
            while not window and time.monotonic()<deadline:
                parent=c.c_ulong();returned_root=c.c_ulong();items=c.POINTER(c.c_ulong)();count=c.c_uint()
                x.XQueryTree(display,x.XDefaultRootWindow(display),c.byref(returned_root),c.byref(parent),c.byref(items),c.byref(count))
                for i in range(count.value):
                    xx=c.c_int();yy=c.c_int();w=c.c_uint();h=c.c_uint();border=c.c_uint();depth=c.c_uint()
                    x.XGetGeometry(display,items[i],c.byref(returned_root),c.byref(xx),c.byref(yy),c.byref(w),c.byref(h),c.byref(border),c.byref(depth))
                    if w.value==required_width and h.value>=(300 if require_scope else 700):window=items[i]
                x.XFree(items);time.sleep(.05)
            assert window,(root/'app.log').read_text()
            if require_scope:
                x.XSetInputFocus(display,window,1,0)
                xt.XTestFakeMotionEvent(display,-1,180,100,0)
                xt.XTestFakeButtonEvent(display,1,1,0);xt.XTestFakeButtonEvent(display,1,0,0);x.XFlush(display)
                key('Control_L',1);key('a',1);key('a',0);key('Control_L',0)
                for char in str(fixture):
                    name={'/':'slash','-':'minus','_':'underscore'}.get(char,char)
                    key(name,1);key(name,0)
                xt.XTestFakeMotionEvent(display,-1,400,242,0)
                xt.XTestFakeButtonEvent(display,1,1,0);xt.XTestFakeButtonEvent(display,1,0,0);x.XFlush(display)
                time.sleep(.3)
                x.XQueryTree(display,x.XDefaultRootWindow(display),c.byref(returned_root),c.byref(parent),c.byref(items),c.byref(count))
                for i in range(count.value):
                    xx=c.c_int();yy=c.c_int();w=c.c_uint();h=c.c_uint();border=c.c_uint();depth=c.c_uint()
                    x.XGetGeometry(display,items[i],c.byref(returned_root),c.byref(xx),c.byref(yy),c.byref(w),c.byref(h),c.byref(border),c.byref(depth))
                    if w.value==700 and h.value>=700:window=items[i]
                x.XFree(items)
            x.XSetInputFocus(display,window,1,0)
            xt.XTestFakeMotionEvent(display,-1,150,28,0)
            xt.XTestFakeButtonEvent(display,1,1,0);xt.XTestFakeButtonEvent(display,1,0,0);x.XFlush(display)
            for char in 'needle':key(char,1);key(char,0)
            time.sleep(1.5)
            xt.XTestFakeMotionEvent(display,-1,120,229,0)
            xt.XTestFakeButtonEvent(display,1,1,0);xt.XTestFakeButtonEvent(display,1,0,0);x.XFlush(display)
            evidence=os.environ.get('FAVENIO_EVIDENCE_DIR')
            if evidence:
                Path(evidence).mkdir(parents=True,exist_ok=True)
                subprocess.run(['import','-window',str(window),str(Path(evidence)/'quick-search.png')],check=True,timeout=5)
            key('Control_L',1);key('Return',1);key('Return',0);key('Control_L',0)
            endpoint=runtime/'org.favenio.Main.search-control.v1.sock'
            deadline=time.monotonic()+10
            while not endpoint.exists() and time.monotonic()<deadline:time.sleep(.05)
            def call(operation,**fields):
                request=dict(version=1,id=str(uuid.uuid4()),deadline=time.time()+8,operation=operation,**fields)
                with socket.socket(socket.AF_UNIX) as stream:
                    stream.settimeout(9);stream.connect(str(endpoint));data=json.dumps(request).encode();stream.sendall(struct.pack('!I',len(data))+data)
                    def read(size):
                        data=b''
                        while len(data)<size:
                            chunk=stream.recv(size-len(data));assert chunk;data+=chunk
                        return data
                    size=struct.unpack('!I',read(4))[0];return json.loads(read(size))
            deadline=time.monotonic()+10
            while time.monotonic()<deadline:
                state=call('status')['status']
                if state['state']=='completed':break
                time.sleep(.05)
            assert state['count']==2,state
            config=call('configuration')['configuration'];assert config['pattern']=='needle',config
            captured=call('captureRecording',runID=state['runID']);assert 'error' not in captured,captured
            assert len(captured['recording']['selection'])==1,captured
            if evidence:
                subprocess.run(['import','-window','root',str(Path(evidence)/'handoff-main.png')],check=True,timeout=5)
            main_window=window_with_width(1180);assert main_window
            x.XSetInputFocus(display,main_window,1,0)
            xt.XTestFakeMotionEvent(display,-1,100,240,0)
            xt.XTestFakeButtonEvent(display,1,1,0);xt.XTestFakeButtonEvent(display,1,0,0);x.XFlush(display)
            key('space',1);key('space',0)
            deadline=time.monotonic()+5
            while not window_with_width(800) and time.monotonic()<deadline:time.sleep(.05)
            preview=window_with_width(800);assert preview,'Space must open the selected result preview'
            x.XSetInputFocus(display,preview,1,0)
            key('space',1);key('space',0);time.sleep(.2)
            assert not window_with_width(800),'Space must close the preview before a focused button handles it'
            x.XSetInputFocus(display,main_window,1,0)
            key('Control_L',1);key('c',1);key('c',0);key('Control_L',0)
            time.sleep(.1)
            copied=subprocess.check_output(['xclip','-selection','clipboard','-o'],timeout=3).decode()
            assert copied==str(fixture/'needle-first.txt '),(repr(copied),'Copied paths must preserve trailing spaces')
            xt.XTestFakeMotionEvent(display,-1,640,180,0)
            xt.XTestFakeButtonEvent(display,1,1,0);xt.XTestFakeButtonEvent(display,1,0,0);x.XFlush(display)
            for name in ['Home','Down','Return']:key(name,1);key(name,0)
            time.sleep(.3)
            xt.XTestFakeMotionEvent(display,-1,85,280,0)
            xt.XTestFakeButtonEvent(display,1,1,0);xt.XTestFakeButtonEvent(display,1,0,0);x.XFlush(display)
            key('space',1);key('space',0);time.sleep(.3)
            preview=window_with_width(800);assert preview,'Space must also open the thumbnail selection preview'
            x.XSetInputFocus(display,preview,1,0);key('space',1);key('space',0);time.sleep(.2)
            assert not window_with_width(800)
            x.XSetInputFocus(display,main_window,1,0)
            xt.XTestFakeMotionEvent(display,-1,640,180,0)
            xt.XTestFakeButtonEvent(display,1,1,0);xt.XTestFakeButtonEvent(display,1,0,0);x.XFlush(display)
            for name in ['Home','Return']:key(name,1);key(name,0)
            time.sleep(.2)
            xt.XTestFakeMotionEvent(display,-1,100,240,0)
            xt.XTestFakeButtonEvent(display,3,1,0);xt.XTestFakeButtonEvent(display,3,0,0);x.XFlush(display)
            time.sleep(.2)
            if evidence:
                subprocess.run(['import','-window','root',str(Path(evidence)/'result-context.png')],check=True,timeout=5)
            key('Escape',1);key('Escape',0);time.sleep(.1)
            # Echte Sortierauswahl und anschließende Ergebnisabfrage gemeinsam prüfen.
            for sort_index in [6, 7, 8, 0]:
                before=call('results',runID=state['runID'],offset=0,limit=128)
                xt.XTestFakeMotionEvent(display,-1,250,180,0)
                xt.XTestFakeButtonEvent(display,1,1,0);xt.XTestFakeButtonEvent(display,1,0,0);x.XFlush(display)
                for name in ['Home']+['Down']*sort_index+['Return']:key(name,1);key(name,0)
                time.sleep(.3)
                page=call('results',runID=state['runID'],offset=0,limit=128)
                assert 'error' not in page and len(page['hits'])==2,page
                assert page['generation']!=before['generation'],'Sort widget must change the projection'
            xt.XTestFakeMotionEvent(display,-1,245,112,0)
            xt.XTestFakeButtonEvent(display,1,1,0);xt.XTestFakeButtonEvent(display,1,0,0);x.XFlush(display)
            time.sleep(.3)
            caps=call('capabilities')
            blocked=call('configure',configuration=dict(pattern='other',root=str(fixture),options=[]),runtimeID=caps['runtimeID'],windowID=caps['windowID'])
            assert blocked.get('error',{}).get('code')=='busy',blocked
            xt.XTestFakeMotionEvent(display,-1,270,28,0)
            xt.XTestFakeButtonEvent(display,1,1,0);xt.XTestFakeButtonEvent(display,1,0,0);x.XFlush(display)
            time.sleep(.2)
            if evidence:
                subprocess.run(['import','-window','root',str(Path(evidence)/'criteria-editor.png')],check=True,timeout=5)
            xt.XTestFakeMotionEvent(display,-1,500,70,0)
            xt.XTestFakeButtonEvent(display,1,1,0);xt.XTestFakeButtonEvent(display,1,0,0);x.XFlush(display)
            for char in 'needle':key(char,1);key(char,0)
            xt.XTestFakeMotionEvent(display,-1,450,521,0)
            xt.XTestFakeButtonEvent(display,1,1,0);xt.XTestFakeButtonEvent(display,1,0,0);x.XFlush(display)
            time.sleep(.3)
            edited=call('configuration')['configuration']
            criteria=[item['value'] for item in edited['options'] if item['name']=='criteria']
            assert criteria and json.loads(criteria[0])['root']['children'][0]['value']=='needle',edited

            if require_scope:assert config.get('roots',[config.get('root')])==[str(fixture)],config
            print('X11 INPUT OK: Quick search and handoff, selection, Space preview open/close, exact clipboard path, criteria editor')
        finally:
            try:os.killpg(process.pid,signal.SIGTERM)
            except ProcessLookupError:pass
            try:process.wait(timeout=5)
            except subprocess.TimeoutExpired:os.killpg(process.pid,signal.SIGKILL);process.wait()
            log.close()
            if os.environ.get('FAVENIO_EVIDENCE_DIR'):
                target=Path(os.environ['FAVENIO_EVIDENCE_DIR']);target.mkdir(parents=True,exist_ok=True)
                (target/'interaction-app.log').write_bytes((root/'app.log').read_bytes())


if __name__=='__main__':main()
