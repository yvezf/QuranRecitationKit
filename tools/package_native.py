#!/usr/bin/env python3
"""Collect built Phase A artifacts and notices. Does not publish or include a model."""
from pathlib import Path
import argparse, platform, shutil, tarfile, zipfile, hashlib, json
p=argparse.ArgumentParser();p.add_argument('--rid',required=True);a=p.parse_args()
root=Path(__file__).resolve().parent.parent;out=root/'dist'/a.rid;out.mkdir(parents=True,exist_ok=True)
windows=a.rid.startswith('win');binary='qrk.exe'if windows else'qrk';library='qrk.dll'if windows else'libqrk.dylib'if'darwin'in a.rid else'libqrk.so'
for name in (binary,library):
 dest=out/name
 if dest.exists():dest.unlink()
 shutil.copy2(root/'core/target/release'/name,dest)
shutil.copyfile(root/'core/qrk-ffi/include/qrk.h',out/'qrk.h')
for name in ('LICENSE','THIRD_PARTY_NOTICES.md','MODEL_CARD.md'):shutil.copyfile(root/name,out/name)
shutil.copytree(root/'third-party',out/'third-party',dirs_exist_ok=True)
receipt={p.name:hashlib.sha256(p.read_bytes()).hexdigest()for p in out.iterdir()if p.is_file()}
(out/'SHA256SUMS.json').write_text(json.dumps(receipt,indent=2)+'\n')
archive=root/'dist'/f'qrk-{a.rid}.zip'
with zipfile.ZipFile(archive,'w',compression=zipfile.ZIP_DEFLATED)as z:
 for f in out.rglob('*'):
  if f.is_file():z.write(f,f.relative_to(out))
print(archive.name)

node=root/'bindings/node/prebuilds'/a.rid
if not node.is_dir():raise SystemExit('Node prebuild missing')
with zipfile.ZipFile(root/'dist'/f'node-{a.rid}.zip','w',compression=zipfile.ZIP_DEFLATED)as z:
 for f in node.rglob('*'):
  if f.is_file():z.write(f,Path('prebuilds')/a.rid/f.relative_to(node))
