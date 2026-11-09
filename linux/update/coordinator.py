"""Signierter, benutzerlokaler Versionswechsel für beide Linux-Apps."""
import base64
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import tarfile
import tempfile
import time
import urllib.parse
import urllib.request

CHANNEL = 'https://github.com/DanielMuellerIR/favenio/releases/download/linux-stable/linux-update.json'
CONTEXT = b'Favenio Linux Update v1\n'
MAX_PACKAGE = 256 * 1024**2
MAX_EXPANDED = 1024**3


class UpdateError(Exception):
    pass


def version_key(value):
    if not isinstance(value, str) or re.fullmatch(r'0|[1-9][0-9]*', value):
        raise UpdateError('Version braucht drei numerische Komponenten.')
    if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', value):
        raise UpdateError('Ungültige Version.')
    return tuple(map(int, value.split('.')))


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise UpdateError('Doppeltes Manifestfeld.')
        result[key] = value
    return result


def verify_manifest(data, signature, public_key):
    if len(data) > 65536 or len(signature) > 128:
        raise UpdateError('Manifest oder Signatur zu groß.')
    try:
        raw_key = base64.b64decode(public_key.strip(), validate=True)
        raw_signature = base64.b64decode(signature.strip(), validate=True)
        if len(raw_key) != 32 or len(raw_signature) != 64:
            raise ValueError()
        with tempfile.TemporaryDirectory(prefix='favenio-verify-') as directory:
            root = Path(directory)
            (root/'public.der').write_bytes(bytes.fromhex('302a300506032b6570032100') + raw_key)
            (root/'signature').write_bytes(raw_signature)
            (root/'message').write_bytes(CONTEXT + data)
            result = subprocess.run(['/usr/bin/openssl', 'pkeyutl', '-verify', '-pubin', '-keyform', 'DER', '-inkey', str(root/'public.der'), '-rawin', '-in', str(root/'message'), '-sigfile', str(root/'signature')], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
            if result.returncode:
                raise UpdateError('Herausgebersignatur ist ungültig.')
        manifest = json.loads(data, object_pairs_hook=unique_object)
        if not isinstance(manifest, dict) or set(manifest) != {'schemaVersion','platform','version','engineVersion','size','sha256','url'} or manifest['schemaVersion'] != 1 or isinstance(manifest['schemaVersion'], bool) or manifest['platform'] != 'linux-x86_64':
            raise UpdateError('Unbekanntes Updateformat.')
        version_key(manifest['version'])
        if manifest['engineVersion'] != manifest['version'] or type(manifest['size']) is not int or not 0 < manifest['size'] <= MAX_PACKAGE or not re.fullmatch(r'[a-f0-9]{64}', manifest['sha256']):
            raise UpdateError('Ungültige Paketbindung.')
        parsed = urllib.parse.urlsplit(manifest['url'])
        if parsed.scheme != 'https' or parsed.netloc != 'github.com' or not parsed.path.startswith('/DanielMuellerIR/favenio/releases/download/') or parsed.query or parsed.fragment:
            raise UpdateError('Paketadresse gehört nicht zum Favenio-Releasekanal.')
        return manifest
    except (ValueError, TypeError, KeyError, OSError, subprocess.SubprocessError) as error:
        raise UpdateError('Manifest konnte nicht verifiziert werden.') from error


class HTTPSRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, newurl):
        if urllib.parse.urlsplit(newurl).scheme != 'https':
            raise UpdateError('Unsichere Downloadweiterleitung.')
        return super().redirect_request(request, fp, code, message, headers, newurl)


def download(url, destination, maximum):
    if urllib.parse.urlsplit(url).scheme != 'https':
        raise UpdateError('Nur HTTPS ist erlaubt.')
    opener = urllib.request.build_opener(HTTPSRedirect())
    request = urllib.request.Request(url, headers={'User-Agent':'Favenio-Linux-Updater/1'})
    size = 0
    with opener.open(request, timeout=20) as response, open(destination, 'xb') as output:
        deadline = time.monotonic() + 300
        while True:
            if time.monotonic() >= deadline:
                raise UpdateError('Download überschreitet fünf Minuten.')
            chunk = response.read1(min(65536, maximum + 1 - size))
            if not chunk:
                break
            size += len(chunk)
            if size > maximum:
                raise UpdateError('Download überschreitet die erlaubte Größe.')
            output.write(chunk)
        output.flush()
        os.fsync(output.fileno())


def check(public_key):
    with tempfile.TemporaryDirectory(prefix='favenio-update-check-') as directory:
        root=Path(directory)
        download(CHANNEL, root/'manifest', 65536)
        download(CHANNEL+'.sig', root/'signature', 128)
        data, signature = (root/'manifest').read_bytes(), (root/'signature').read_bytes()
        return verify_manifest(data, signature, public_key), data, signature


def secure_directory(path):
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    info=path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
        raise UpdateError('Installationsordner ist fremd oder für andere beschreibbar.')


@contextlib.contextmanager
def installation_lease(root, exclusive=False, create=True):
    if not create and not root.exists():
        yield
        return
    secure_directory(root)
    descriptor=os.open(root/'lifecycle.lock',os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600)
    with os.fdopen(descriptor,'r+') as lock:
        try:fcntl.flock(lock,(fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH)|fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise UpdateError('Favenio, FavenioQuick und laufende Updates zuerst schließen; die Installation wird gerade benutzt oder entfernt.') from error
        yield


def safe_extract(package, destination, version):
    total=0
    names=set()
    prefix='favenio-'+version
    with tarfile.open(package, 'r:gz') as archive:
        for index, member in enumerate(archive):
            path=PurePosixPath(member.name)
            if index>=8192 or path.is_absolute() or '..' in path.parts or not path.parts or path.parts[0] != prefix or str(path) in names or not (member.isfile() or member.isdir()):
                raise UpdateError('Unsicherer Archiveintrag.')
            names.add(str(path))
            total+=member.size
            if total>MAX_EXPANDED or member.size<0:
                raise UpdateError('Entpacktes Paket ist zu groß.')
            target=destination.joinpath(*path.parts[1:])
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True, mode=0o700)
            else:
                target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                with archive.extractfile(member) as source, target.open('xb') as output:
                    shutil.copyfileobj(source,output,65536)
                target.chmod(0o755 if member.mode & 0o111 else 0o644)


def atomic_json(path, value):
    temporary=path.with_name(path.name+'.new')
    descriptor=os.open(temporary, os.O_WRONLY|os.O_CREAT|os.O_TRUNC|os.O_NOFOLLOW,0o600)
    with os.fdopen(descriptor,'w') as output:
        json.dump(value,output,sort_keys=True)
        output.flush();os.fsync(output.fileno())
    os.replace(temporary,path)


def switch(root, version):
    temporary=root/('current-'+str(os.getpid()))
    temporary.symlink_to('versions/'+version)
    os.replace(temporary,root/'current')
    descriptor=os.open(root,os.O_RDONLY|os.O_DIRECTORY)
    try:os.fsync(descriptor)
    finally:os.close(descriptor)


def installation_root():
    return Path(os.environ.get('XDG_DATA_HOME',Path.home()/'.local/share'))/'favenio'


def refresh_integration(root, folder):
    # Auch ältere verifizierte Pakete besitzen dieselbe Installer-Funktion.
    script = 'import runpy,sys; from pathlib import Path; runpy.run_path(sys.argv[1])["integration"](Path(sys.argv[2]))'
    try:
        result = subprocess.run(['/usr/bin/python3', '-B', '-c', script, str(folder/'install.py'), str(root)], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
    except subprocess.TimeoutExpired as error:
        raise UpdateError('Dateimanager-Anbindung überschreitet die Zeitgrenze. Den verifizierten Stand mit --recover wiederherstellen.') from error
    if result.returncode:
        raise UpdateError('Dateimanager-Anbindung konnte nicht aktualisiert werden. Den verifizierten Stand mit --recover wiederherstellen.')


def install(root, package, data, signature, public_key):
    with installation_lease(root):
        return install_package(root, package, data, signature, public_key)


def install_package(root, package, data, signature, public_key):
    manifest=verify_manifest(data, signature, public_key)
    with open(package,'rb') as source:
        digest=hashlib.file_digest(source,'sha256').hexdigest() if hasattr(hashlib,'file_digest') else hashlib.sha256(source.read(MAX_PACKAGE+1)).hexdigest()
    if Path(package).stat().st_size != manifest['size'] or digest != manifest['sha256']:
        raise UpdateError('Paketgröße oder SHA-256 stimmt nicht.')
    secure_directory(root);secure_directory(root/'versions')
    descriptor=os.open(root/'update.lock',os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600)
    with os.fdopen(descriptor,'w') as lock:
        try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError as error:raise UpdateError('Eine andere Installation läuft bereits.') from error
        current=(root/'current').resolve() if (root/'current').is_symlink() else None
        old=current.name if current and current.parent == (root/'versions').resolve() and current.is_dir() else None
        target=root/'versions'/manifest['version']
        state_path=root/'update-state.json'
        previous=json.loads(state_path.read_text()) if state_path.exists() else {}
        greatest=previous.get('highestVersion',old)
        if greatest and version_key(manifest['version'])<=version_key(greatest):
            raise UpdateError('Diese Version ist bereits installiert oder älter als der verifizierte Stand.')
        orphan = None
        if target.exists():
            if (root/'current').resolve() == target.resolve() or not (target/'verified-manifest.json').is_file() or (target/'verified-manifest.json').read_bytes() != data or (target/'verified-manifest.sig').read_bytes() != signature:
                raise UpdateError('Versionsordner existiert bereits und ist keine verifizierte unterbrochene Installation.')
            orphan = root/'versions'/('.recovery-'+str(time.time_ns()))
            os.rename(target, orphan)
        with tempfile.TemporaryDirectory(prefix='.staging-',dir=root/'versions') as directory:
            staging=Path(directory)
            safe_extract(package,staging,manifest['version'])
            required=['favenio','favenio.py','libfavenio-shared.so','launch','install.py','helpers/favenio-update','update/public-key.txt']
            if not all((staging/name).is_file() for name in required):
                raise UpdateError('Paket ist unvollständig.')
            if (staging/'update/public-key.txt').read_bytes().strip()!=public_key.strip():
                raise UpdateError('Unangekündigter Herausgeberschlüsselwechsel.')
            if (staging/'VERSION').read_text().strip()!=manifest['version']:
                raise UpdateError('Paketversion stimmt nicht.')
            engine = subprocess.run(['/usr/bin/python3', '-B', str(staging/'favenio.py'), '--version'], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
            if engine.returncode or engine.stdout.decode('utf-8', 'strict').strip() != 'favenio ' + manifest['engineVersion']:
                raise UpdateError('Suchkern und Paketversion passen nicht zusammen.')
            probe=subprocess.run([str(staging/'launch'),'--self-test'],stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=30)
            if probe.returncode:
                raise UpdateError('Paket besteht die Laufzeitprüfung nicht: '+probe.stderr[-2048:].decode('utf-8','replace'))
            (staging/'verified-manifest.json').write_bytes(data)
            (staging/'verified-manifest.sig').write_bytes(signature)
            os.rename(staging,target)
            # TemporaryDirectory darf nach dem Umbenennen nur seinen alten, nun fehlenden Pfad säubern.
        atomic_json(state_path,dict(highestVersion=manifest['version'],previousVersion=old,pendingVersion=manifest['version']))
        switch(root,manifest['version'])
        refresh_integration(root,target)
        atomic_json(state_path,dict(highestVersion=manifest['version'],previousVersion=old,currentVersion=manifest['version']))
    return manifest['version']


def recover(root, public_key):
    with installation_lease(root):
        return recover_package(root, public_key)


def recover_package(root, public_key):
    secure_directory(root)
    descriptor=os.open(root/'update.lock',os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600)
    with os.fdopen(descriptor,'w') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        state=json.loads((root/'update-state.json').read_text())
        pending=state.get('pendingVersion')
        if not pending:
            return state.get('currentVersion')
        version_key(pending)
        folder=root/'versions'/pending
        manifest=verify_manifest((folder/'verified-manifest.json').read_bytes(),(folder/'verified-manifest.sig').read_bytes(),public_key)
        if manifest['version']!=pending or pending not in (state.get('highestVersion'),state.get('previousVersion')):
            raise UpdateError('Wiederherstellungsauftrag passt nicht zur verifizierten Version.')
        result=subprocess.run([str(folder/'launch'),'--self-test'],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=30)
        if result.returncode:
            raise UpdateError('Unterbrochenes Update ist nicht startbar. Den verifizierten Rückfall verwenden.')
        switch(root,pending)
        refresh_integration(root,folder)
        state['currentVersion']=pending;state.pop('pendingVersion',None);atomic_json(root/'update-state.json',state)
        return pending


def rollback(root, public_key):
    with installation_lease(root):
        return rollback_package(root, public_key)


def rollback_package(root, public_key):
    secure_directory(root)
    descriptor=os.open(root/'update.lock',os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600)
    with os.fdopen(descriptor,'w') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        state=json.loads((root/'update-state.json').read_text())
        version=state.get('previousVersion')
        version_key(version)
        folder=root/'versions'/version
        manifest=verify_manifest((folder/'verified-manifest.json').read_bytes(),(folder/'verified-manifest.sig').read_bytes(),public_key)
        if manifest['version']!=version:raise UpdateError('Rückfallversion ist nicht verifiziert.')
        state['pendingVersion']=version;atomic_json(root/'update-state.json',state)
        switch(root,version)
        refresh_integration(root,folder)
        state['currentVersion']=version;state.pop('pendingVersion',None);atomic_json(root/'update-state.json',state)
        return version
