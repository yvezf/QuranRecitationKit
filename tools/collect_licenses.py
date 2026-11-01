#!/usr/bin/env python3
"""Collect registry dependency notices from the resolved local Cargo graph; no network."""
import json, subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
sections=[];seen=set();missing=[]
for manifest in [ROOT/'core/Cargo.toml',ROOT/'bindings/node/native/Cargo.toml']:
    metadata=json.loads(subprocess.check_output(['cargo','+stable','metadata','--manifest-path',str(manifest),'--format-version','1','--locked'],text=True))
    for package in metadata['packages']:
        key=(package['name'],package['version'])
        if key in seen or package.get('source') is None:continue
        seen.add(key);directory=Path(package['manifest_path']).parent
        files=[p for p in directory.iterdir() if p.is_file() and (p.name.upper().startswith(('LICENSE','COPYING','NOTICE','UNLICENSE')))]
        specified=package.get('license_file')
        if specified and (directory/specified).is_file() and directory/specified not in files:files.append(directory/specified)
        sections.append('\n'+'='*72+'\n'+f"{key[0]} {key[1]} — {package.get('license') or 'see license file'}\n{package.get('repository') or package.get('source')}\n")
        if not files:missing.append(f'{key[0]} {key[1]}')
        for file in sorted(files):
            try:sections.append(f'\n--- {file.name} ---\n'+file.read_text())
            except UnicodeError:missing.append(f'{key[0]}: non-text {file.name}')
(ROOT/'third-party/RUST-DEPENDENCIES.txt').write_text('\n'.join(sections))
(ROOT/'third-party/NOTICE-COVERAGE.json').write_text(json.dumps({'packages':len(seen),'packages_without_bundled_notice_file':missing},indent=2)+'\n')
print(json.dumps({'packages':len(seen),'without_notice_file':missing}))
