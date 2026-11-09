#!/usr/bin/python3 -B
"""Nur zu dieser Installation gehörende Starter und Dateimanager-Adapter entfernen."""
import os
import fcntl
from pathlib import Path
import shutil
import sys


def main():
    root=Path(__file__).resolve().parent.parent.parent
    data=Path(os.environ.get('XDG_DATA_HOME',Path.home()/'.local/share'))
    if root!=data/'favenio' or root.is_symlink():
        raise SystemExit('Unbekannter Installationsort; nichts entfernt.')
    if '--yes' not in sys.argv:
        if input('Favenio und FavenioQuick entfernen? Vorlagen und Einstellungen bleiben erhalten. [j/N] ').lower()!='j':return
    sys.path.insert(0,str(Path(__file__).resolve().parent/'update'))
    from coordinator import installation_lease, UpdateError
    try:
        with installation_lease(root,exclusive=True):
            descriptor=os.open(root/'update.lock',os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600)
            with os.fdopen(descriptor,'r+') as lock:
                try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
                except BlockingIOError:raise SystemExit('Eine Installation läuft. Danach erneut deinstallieren.')
                remove_installation(root,data)
    except UpdateError as error:raise SystemExit(str(error))


def remove_installation(root,data):
    for relative in ['applications/org.favenio.Main.desktop','applications/org.favenio.Quick.desktop','nemo-python/extensions/favenio_nemo.py','nemo/actions/favenio-quick.nemo_action','kio/servicemenus/favenio-quick.desktop']:
        path=data/relative
        if path.is_file() and ('Favenio' in path.read_text() or 'favenio' in path.read_text()):path.unlink()
    shutil.rmtree(root)
    print('Favenio und FavenioQuick entfernt. Vorlagen und Einstellungen bleiben erhalten.')


if __name__=='__main__':main()
