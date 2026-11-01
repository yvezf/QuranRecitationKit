#!/usr/bin/env python3
"""Verify explicitly pinned/reused release archives without overwriting them."""
from pathlib import Path
import hashlib,json,os,re,sys,tempfile,subprocess

def reused_release(metadata, tag):
    match=re.search(r'/releases/download/([^/]+)/QRKFFI\.xcframework\.zip$',metadata.get('url',''))
    if not metadata.get('checksum') or not match:return None
    if match.group(1)==tag or tag in metadata.get('source_only_releases',[]):return match.group(1)
    return None

def main():
    root=Path(__file__).resolve().parent.parent
    tag=sys.argv[1]
    if not re.fullmatch(r'v\d+\.\d+\.\d+(?:[-.a-zA-Z0-9]*)',tag):raise SystemExit('expected version tag')
    metadata=json.loads((root/'bindings/swift/binary-release.json').read_text())
    release=reused_release(metadata,tag)
    if release:
        with tempfile.TemporaryDirectory()as folder:
            subprocess.run(['gh','release','download',release,'--pattern','QRKFFI.xcframework.zip','--dir',folder],check=True)
            actual=hashlib.sha256((Path(folder)/'QRKFFI.xcframework.zip').read_bytes()).hexdigest()
            if actual!=metadata['checksum']:raise SystemExit('Published Swift archive differs from the committed pin; refusing to overwrite')
        print('Reviewed Swift archive matches its committed pin; preserving the existing release artifacts.')
    with open(os.environ['GITHUB_OUTPUT'],'a')as f:f.write(f'build={str(release is None).lower()}\n')
if __name__=='__main__':main()
