"""Assemble only binaries that passed Windows smoke tests for this source commit."""
import argparse
import hashlib
import json
from pathlib import Path
import zipfile

parser=argparse.ArgumentParser()
parser.add_argument('--parts',required=True);parser.add_argument('--output',required=True);parser.add_argument('--commit',required=True)
a=parser.parse_args()
source=Path(__file__).resolve().parent
parts=Path(a.parts);output=Path(a.output);output.mkdir(parents=True,exist_ok=True)
reports=[];binaries=[]
for arch in ('x64','x86'):
    found=list(parts.rglob('CloudshopPrint-'+arch+'.exe'))
    checks=list(parts.rglob('smoke-'+arch+'.json'))
    assert len(found)==len(checks)==1,(arch,'missing or duplicate build')
    data=json.loads(checks[0].read_text(encoding='utf-8-sig'))
    assert data.get('ok') and data.get('gui') and data.get('dpapi'),(arch,'failed smoke test')
    assert data.get('source_commit')==a.commit,(arch,'wrong source commit')
    assert data.get('version')=='0.3',(arch,'wrong version')
    with found[0].open('rb') as f:assert f.read(2)==b'MZ'
    binaries.append(found[0]);reports.append(data)
archive=output/'Cloudshop-Print-Windows-v0.3.zip'
with zipfile.ZipFile(archive,'w',compression=zipfile.ZIP_DEFLATED,allowZip64=True) as z:
    for binary in binaries:z.write(binary,'Cloudshop-Print/'+binary.name)
    for name in ('НАЧАТЬ_ЗДЕСЬ.html','ИНСТРУКЦИЯ.txt','ТЕСТ_НЕ_ПЕЧАТАТЬ_1х1см.tif','THIRD-PARTY.txt'):
        z.write(source/name,'Cloudshop-Print/'+name)
    z.write(source/'START-NATIVE.cmd','Cloudshop-Print/START.cmd')
    z.writestr('Cloudshop-Print/Windows-checks.json',json.dumps({'version':'0.3','source_commit':a.commit,'checks':reports},indent=2))
    # Carry original dependency license texts alongside the application.
    for wheel in (source/'wheelhouse').glob('*.whl'):
        with zipfile.ZipFile(wheel) as w:
            for name in w.namelist():
                if not name.endswith('/') and any(word in Path(name).name.upper() for word in ('LICENSE','COPYING')):
                    z.writestr('Cloudshop-Print/licenses/'+wheel.stem+'/'+Path(name).name,w.read(name))
assert archive.stat().st_size<95*1024*1024,'Release exceeds GitHub single-file limit'
with zipfile.ZipFile(archive) as z:assert z.testzip() is None
checksum=hashlib.sha256(archive.read_bytes()).hexdigest()
(output/'Cloudshop-Print-Windows-v0.3.sha256').write_text(checksum+'  '+archive.name+'\n')
print('Prepared',archive.name,archive.stat().st_size,'bytes; SHA256',checksum)
