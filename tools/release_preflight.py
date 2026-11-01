#!/usr/bin/env python3
"""A final checksum-pin tag verifies/reuses the reviewed archive, never overwrites it."""
from pathlib import Path
import hashlib,json,os,sys,tempfile,subprocess
root=Path(__file__).resolve().parent.parent
tag=sys.argv[1]
if not tag.startswith('v'):raise SystemExit('expected version tag')
metadata=json.loads((root/'bindings/swift/binary-release.json').read_text())
build=True
if metadata.get('checksum') and f'/download/{tag}/'in metadata.get('url',''):
    with tempfile.TemporaryDirectory()as folder:
        subprocess.run(['gh','release','download',tag,'--pattern','QRKFFI.xcframework.zip','--dir',folder],check=True)
        actual=hashlib.sha256((Path(folder)/'QRKFFI.xcframework.zip').read_bytes()).hexdigest()
        if actual!=metadata['checksum']:raise SystemExit('Published Swift archive differs from the committed pin; refusing to overwrite')
    print('Reviewed Swift archive matches its committed pin; preserving the existing release artifacts.')
    build=False
with open(os.environ['GITHUB_OUTPUT'],'a')as f:f.write(f'build={str(build).lower()}\n')
