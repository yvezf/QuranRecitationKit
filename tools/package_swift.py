#!/usr/bin/env python3
"""Archive Apple libraries and pin a reviewed archive, never publish anything."""
from pathlib import Path
import argparse,hashlib,json,re,zipfile
root=Path(__file__).resolve().parent.parent
p=argparse.ArgumentParser();p.add_argument('--archive',type=Path);p.add_argument('--pin',action='store_true');p.add_argument('--tag',default='v0.3.0');a=p.parse_args()
archive=a.archive or root/'dist/QRKFFI.xcframework.zip'
if a.archive is None:
    source=root/'bindings/swift/Artifacts/QRKFFI.xcframework';archive.parent.mkdir(exist_ok=True)
    with zipfile.ZipFile(archive,'w',compression=zipfile.ZIP_DEFLATED)as z:
        for f in sorted(source.rglob('*')):
            if f.is_file():z.write(f,Path('QRKFFI.xcframework')/f.relative_to(source))
sha=hashlib.sha256(archive.read_bytes()).hexdigest()
Path(str(archive)+'.sha256').write_text(sha+'  '+archive.name+'\n')
if a.pin:
    owner=re.search(r'pub const REPOSITORY_OWNER: &str = "([^"]+)"', (root/'core/qrk-onnx/src/lib.rs').read_text()).group(1)
    if '<'in owner:raise SystemExit('Configure REPOSITORY_OWNER before pinning a public URL.')
    if not re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+(?:[-.a-zA-Z0-9]*)',a.tag):raise SystemExit('invalid release tag')
    metadata={'url':f'https://github.com/{owner}/QuranRecitationKit/releases/download/{a.tag}/QRKFFI.xcframework.zip','checksum':sha}
    (root/'bindings/swift/binary-release.json').write_text(json.dumps(metadata,indent=2)+'\n')
    # SwiftPM evaluates version manifests through a virtual filesystem; sidecar file reads are not supported there.
    for manifest in [root/'Package.swift',root/'bindings/swift/Package.swift']:
        text=manifest.read_text()
        text,n=re.subn(r'    binary = \.binaryTarget\(name: "QRKFFI", url: "[^"]+", checksum: "[^"]+"\)',
            f'    binary = .binaryTarget(name: "QRKFFI", url: "{metadata["url"]}", checksum: "{sha}")',text)
        if n!=1:raise SystemExit(f'Expected one inline binary release pin in {manifest.name}')
        manifest.write_text(text)

print(archive.name+' '+sha)
