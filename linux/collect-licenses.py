#!/usr/bin/env python3
"""Lizenzdateien der tatsächlich aufgelösten Rust-Pakete mit ins Paket nehmen."""
import json
from pathlib import Path
import shutil
import subprocess
import sys

repo=Path(__file__).resolve().parent.parent
out=Path(sys.argv[1]);out.mkdir(parents=True,exist_ok=True)
metadata=json.loads(subprocess.check_output(['cargo','metadata','--manifest-path',str(repo/'linux/Cargo.toml'),'--locked','--filter-platform','x86_64-unknown-linux-gnu','--format-version','1']))
for package in metadata['packages']:
    source=Path(package['manifest_path']).parent
    names=[p for p in source.iterdir() if p.is_file() and p.name.upper().startswith(('LICENSE','LICENCE','COPYING','NOTICE','COPYRIGHT'))]
    if not names and package['name']!='favenio-linux':
        raise SystemExit('Lizenztext fehlt: '+package['name'])
    destination=out/(package['name']+'-'+package['version']);destination.mkdir(exist_ok=True)
    for path in names:shutil.copyfile(path,destination/path.name)
    (destination/'source.txt').write_text('Name: '+package['name']+'\nVersion: '+package['version']+'\nLicense: '+str(package.get('license'))+'\nRepository: '+str(package.get('repository'))+'\n')

sysroot=Path(subprocess.check_output(['rustc','--print','sysroot'],text=True).strip())/'share/doc/rust'
shutil.copyfile(sysroot/'COPYRIGHT-library.html',out/'Rust-standard-library-COPYRIGHT.html')
shutil.copytree(sysroot/'licenses',out/'Rust-standard-library-licenses',dirs_exist_ok=True)
