#!/usr/bin/env python3
"""Unveränderte PNG-Bilder aus den gemeinsamen macOS-Iconcontainern übernehmen."""
from pathlib import Path
import struct
import sys


def extract(source, target):
    data=source.read_bytes()
    if data[:4]!=b'icns' or struct.unpack('>I',data[4:8])[0]!=len(data):
        raise ValueError('Ungültiger Iconcontainer: '+source.name)
    offset=8;candidates=[]
    while offset<len(data):
        size=struct.unpack('>I',data[offset+4:offset+8])[0]
        if size<8 or offset+size>len(data):raise ValueError('Ungültige Icontabelle.')
        payload=data[offset+8:offset+size]
        if payload.startswith(b'\x89PNG\r\n\x1a\n') and payload[12:16]==b'IHDR':
            width,height=struct.unpack('>II',payload[16:24])
            if 0<width==height<=2048:candidates.append((width,payload))
        offset+=size
    if not candidates:raise ValueError('PNG-Bild fehlt: '+source.name)
    target.write_bytes(max(candidates,key=lambda item:item[0])[1])


if __name__=='__main__':
    source,target=map(Path,sys.argv[1:]);target.mkdir(parents=True,exist_ok=True)
    for name,identifier in [('Favenio','org.favenio.Main'),('FavenioQuick','org.favenio.Quick')]:
        extract(source/(name+'.icns'),target/(identifier+'.png'))
