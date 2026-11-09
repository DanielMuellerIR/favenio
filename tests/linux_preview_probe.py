"""Echte begrenzte Bild-, PDF-, Text- und Office-Vorschau der Auslieferung."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from docx_fixture import docx_bytes, paragraph
from pdf_fixture import pdf_bytes


def main():
    folder,image=map(lambda value:Path(value).resolve(),sys.argv[1:])
    helper=folder/'helpers/favenio-preview'
    with tempfile.TemporaryDirectory(prefix='favenio-preview-probe-') as directory:
        root=Path(directory)
        def preview(path,encoding='utf-8',page=1,edge=600):
            workspace=root/('work-'+str(len(list(root.iterdir()))));workspace.mkdir(mode=0o700)
            process=subprocess.run([sys.executable,'-B',str(helper),str(path),str(workspace),encoding,str(page),str(edge)],capture_output=True,timeout=15)
            assert process.returncode==0,process.stderr
            return json.loads(process.stdout)
        text=root/'windows.txt';text.write_bytes('Preis € und Straße'.encode('cp1252'))
        result=preview(text,'windows-1252');assert result['kind']=='text' and '€ und Straße' in result['text'],result
        result=preview(image);assert result['kind']=='image',result
        assert Path(result['path']).read_bytes().startswith(b'\x89PNG'),result
        result=preview(folder/'icons/org.favenio.Main.png',edge=1800)
        assert result['kind']=='image',result
        pdf=root/'pages.pdf';pdf.write_bytes(pdf_bytes([[(40,700,'first page')],[(40,700,'second page')]]))
        result=preview(pdf,page=2);assert result['kind']=='image' and result['page']==2,result
        office=root/'notes.docx';office.write_bytes(docx_bytes(paragraph('Logischer Text ', 'mit Umlaut München')))
        result=preview(office);assert result['kind']=='text' and 'München' in result['text'],result
        broken=root/'bad.pdf';broken.write_bytes(b'%PDF-1.4\nbroken')
        result=preview(broken);assert result['kind']=='error',result
        assert 'Command' not in result['text'] and str(folder) not in result['text'],result
    print('LINUX PREVIEW OK: selected encoding, bounded image, second PDF page, shared DOCX reader, damaged PDF explained')


if __name__=='__main__':main()
