#!/usr/bin/python3 -B
"""Signiertes Favenio-Paket samt beiden Desktop-Startern benutzerlokal installieren."""
import argparse
import os
from pathlib import Path
import sys
import tempfile
sys.path.insert(0,str(Path(__file__).resolve().parent/'update'))
from coordinator import UpdateError, install, installation_root, installation_lease


def write(path,text,mode=0o644):
    path.parent.mkdir(parents=True,exist_ok=True)
    descriptor, name = tempfile.mkstemp(prefix='.favenio-', dir=path.parent)
    temporary = Path(name)
    try:
        with os.fdopen(descriptor,'w') as output:
            os.fchmod(output.fileno(),mode)
            output.write(text);output.flush();os.fsync(output.fileno())
        os.replace(temporary,path)
    finally:temporary.unlink(missing_ok=True)


def desktop_quote(path):
    return '"'+str(path).replace('\\','\\\\').replace('"','\\"').replace('`','\\`').replace('$','\\$').replace('%','%%')+'"'


def integration(root):
    data=Path(os.environ.get('XDG_DATA_HOME',Path.home()/'.local/share'))
    source=Path(__file__).resolve().parent/'integration'
    for quick in (False,True):
        name='favenio-quick' if quick else 'favenio'
        launcher=root/'bin'/name
        write(launcher,'#!/usr/bin/env bash\nset -euo pipefail\nroot=$(cd "$(dirname "$0")/.." && pwd)\nexec "$root/current/launch" '+('--quick ' if quick else '')+'"$@"\n',0o755)
        write(data/'applications'/('org.favenio.Quick.desktop' if quick else 'org.favenio.Main.desktop'), '[Desktop Entry]\nType=Application\nName='+('FavenioQuick' if quick else 'Favenio')+'\nComment=Lokale indexlose Dateisuche\nExec='+desktop_quote(launcher)+' --directory %f\nIcon='+str(root/'current/icons'/('org.favenio.Quick.png' if quick else 'org.favenio.Main.png'))+'\nTerminal=false\nCategories=Utility;FileTools;\nMimeType=inode/directory;\n')
    for relative in ['nemo-python/extensions/favenio_nemo.py','nemo/actions/favenio-quick.nemo_action','kio/servicemenus/favenio-quick.desktop']:
        text=(source/Path(relative).name).read_text()
        text=text.replace('Exec=favenio-quick', 'Exec='+desktop_quote(root/'bin/favenio-quick'))
        text=text.replace('Dependencies=favenio-quick;\n','')
        write(data/relative,text,0o755 if relative.endswith('.desktop') else 0o644)
    write(root/'bin/favenio-uninstall','#!/usr/bin/python3 -B\nimport runpy\nfrom pathlib import Path\nrunpy.run_path(str(Path(__file__).resolve().parent.parent/"current"/"uninstall.py"),run_name="__main__")\n',0o755)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('package',type=Path)
    parser.add_argument('manifest',type=Path)
    parser.add_argument('signature',type=Path)
    args=parser.parse_args()
    if os.getuid()==0:raise UpdateError('Als normaler Benutzer installieren, ohne sudo.')
    key=(Path(__file__).resolve().parent/'update/public-key.txt').read_bytes()
    root=installation_root()
    with installation_lease(root):
        version=install(root,args.package,args.manifest.read_bytes(),args.signature.read_bytes(),key)
    print('Favenio '+version+' und FavenioQuick sind installiert. Die Dateimanager-Erweiterungen werden beim nächsten regulären Start von Nemo/Dolphin geladen.')


if __name__=='__main__':
    try:main()
    except (UpdateError,OSError,ValueError) as error:
        print('Installation fehlgeschlagen: '+str(error),file=sys.stderr);sys.exit(2)
