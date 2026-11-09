"""Nemo-Ortsknopf ohne Änderungen am laufenden Dateimanager prüfen."""
import base64
import json
import os
from pathlib import Path
import runpy
import sys
import tempfile
import time
import urllib.parse


def main():
    with tempfile.TemporaryDirectory(prefix='favenio-nemo-probe-') as directory:
        root=Path(directory);os.environ['XDG_DATA_HOME']=str(root)
        launcher=root/'favenio/bin/favenio-quick';launcher.parent.mkdir(parents=True)
        captured=root/'argv.json'
        launcher.write_text('#!/usr/bin/python3 -B\nimport base64,json,os,sys\nfrom pathlib import Path\nPath('+repr(str(captured))+').write_text(json.dumps([base64.b64encode(os.fsencode(a)).decode() for a in sys.argv[1:]]))\n')
        launcher.chmod(0o700)
        module=runpy.run_path(sys.argv[1],run_name='favenio_nemo');provider=module['FavenioQuickLocation']();Gtk=module['Gtk'];Gio=module['Gio'];GLib=module['GLib']
        bus=Gio.bus_get_sync(Gio.BusType.SESSION,None)
        def locations():
            response=[]
            def received(connection,result):response.append(connection.call_finish(result).unpack()[0])
            bus.call('org.favenio.NemoLocations1.p'+str(os.getpid()),'/org/favenio/NemoLocations1','org.freedesktop.DBus.Properties','Get',GLib.Variant('(ss)',('org.favenio.NemoLocations1','OpenLocations')),None,Gio.DBusCallFlags.NO_AUTO_START,1000,None,received)
            deadline=time.monotonic()+2
            while not response and time.monotonic()<deadline:
                while Gtk.events_pending():Gtk.main_iteration_do(False)
                time.sleep(.01)
            assert response
            return response[0]
        for path in [os.fsencode(directory)+b'/ordinary folder',os.fsencode(directory)+b'/bad-\xff-folder']:
            os.mkdir(path)
            uri='file://'+urllib.parse.quote_from_bytes(path)
            window=Gtk.OffscreenWindow()
            widget=provider.get_widget(uri,window)
            assert widget is not None
            window.add(widget);window.show_all()
            widget.get_children()[0].emit('clicked')
            deadline=time.monotonic()+5
            while not captured.exists() and time.monotonic()<deadline:
                while Gtk.events_pending():Gtk.main_iteration_do(False)
                time.sleep(.01)
            arguments=[base64.b64decode(a) for a in json.loads(captured.read_text())]
            assert arguments==[b'--directory',path],arguments
            assert locations()==[uri]
            captured.unlink();window.destroy()
            assert locations()==[]
        assert provider.get_widget('smb://server/share',None) is None
        print('NEMO ADAPTER OK: current folder button, raw POSIX path, read-only open views, destroyed views removed, remote location rejected')


if __name__=='__main__':main()
