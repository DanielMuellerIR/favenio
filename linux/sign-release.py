#!/usr/bin/env python3
"""Manifest mit vorhandenem Ed25519-Herausgeberschlüssel signieren; veröffentlicht nichts."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('package',type=Path)
    parser.add_argument('--key-file',type=Path,required=True)
    parser.add_argument('--url',required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    match=re.fullmatch(r'favenio-([0-9]+\.[0-9]+\.[0-9]+)\.tar\.gz',args.package.name)
    if not match:raise ValueError('Paketname braucht eine Version.')
    version=match[1]
    digest=hashlib.sha256()
    with args.package.open('rb') as source:
        for chunk in iter(lambda:source.read(65536),b''):digest.update(chunk)
    manifest=dict(schemaVersion=1,platform='linux-x86_64',version=version,engineVersion=version,size=args.package.stat().st_size,sha256=digest.hexdigest(),url=args.url)
    data=json.dumps(manifest,sort_keys=True,separators=(',',':')).encode()+b'\n'
    # Sparkle speichert den Ed25519-Seed mit öffentlichem Anteil; nur der Seed gehört in PKCS#8.
    private=base64.b64decode(args.key_file.read_bytes().splitlines()[0].strip(),validate=True)
    if len(private) not in (32,64):raise ValueError('Unbekanntes Ed25519-Schlüsselformat.')
    with tempfile.TemporaryDirectory(prefix='favenio-sign-') as directory:
        root=Path(directory)
        key=root/'key.der';key.write_bytes(bytes.fromhex('302e020100300506032b657004220420')+private[:32]);key.chmod(0o600)
        public=subprocess.check_output(['openssl','pkey','-inform','DER','-in',str(key),'-pubout','-outform','DER'],stderr=subprocess.DEVNULL)[-32:]
        expected=base64.b64decode((Path(__file__).resolve().parent.parent/'common/update-public-key.txt').read_bytes().strip(),validate=True)
        if public!=expected:raise ValueError('Schlüssel passt nicht zum eingebetteten Herausgeber.')
        (root/'message').write_bytes(b'Favenio Linux Update v1\n'+data)
        subprocess.run(['openssl','pkeyutl','-sign','-keyform','DER','-inkey',str(key),'-rawin','-in',str(root/'message'),'-out',str(root/'signature')],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        signature=base64.b64encode((root/'signature').read_bytes())+b'\n'
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_bytes(data);args.output.with_suffix(args.output.suffix+'.sig').write_bytes(signature)
    print('Manifest und Signatur erstellt; nichts veröffentlicht.')


if __name__=='__main__':
    try:main()
    except (OSError,ValueError,subprocess.SubprocessError) as error:
        print('Signierung fehlgeschlagen: '+str(error),file=sys.stderr);sys.exit(2)
