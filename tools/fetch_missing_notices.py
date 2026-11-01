#!/usr/bin/env python3
"""Fetch missing registry notices from their recorded public source revision, never executable code."""
import json, subprocess, urllib.request, concurrent.futures
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
missing=set(json.loads((ROOT/'third-party/NOTICE-COVERAGE.json').read_text())['packages_without_bundled_notice_file'])
packages={}
for manifest in ['core/Cargo.toml','bindings/node/native/Cargo.toml']:
    m=json.loads(subprocess.check_output(['cargo','+stable','metadata','--manifest-path',str(ROOT/manifest),'--format-version','1','--locked'],text=True))
    for p in m['packages']:
        if f"{p['name']} {p['version']}" in missing:packages[(p['name'],p['version'])]=p
out=ROOT/'third-party/supplemental';out.mkdir(parents=True,exist_ok=True)
def fetch(p):
    directory=Path(p['manifest_path']).parent;vcs=directory/'.cargo_vcs_info.json'
    revision=json.loads(vcs.read_text())['git']['sha1'] if vcs.exists() else 'v'+p['version'];repo=(p.get('repository')or'').removesuffix('.git').removesuffix('/')
    if not repo.startswith('https://github.com/'):return {'package':p['name'],'error':'unsupported source host','repository':repo}
    base='https://raw.githubusercontent.com/'+repo.removeprefix('https://github.com/')+'/'+revision+'/'
    found=[]
    for name in ['LICENSE','LICENSE-MIT','LICENSE-APACHE','LICENSE.txt','LICENSE.md','COPYING']:
        try:
            data=subprocess.check_output(['curl','--fail','--silent','--show-error','--location','--max-time','12',base+name],stderr=subprocess.DEVNULL)
            text=data.decode();
            if len(text)<120:continue
            path=out/f"{p['name']}-{p['version']}-{name.replace('/','-')}";path.write_bytes(data);found.append({'file':str(path.relative_to(ROOT)),'url':base+name})
        except Exception:continue
    return {'package':p['name'],'version':p['version'],'revision':revision,'notices':found}
with concurrent.futures.ThreadPoolExecutor(max_workers=8)as pool:results=list(pool.map(fetch,packages.values()))
(ROOT/'third-party/SUPPLEMENTAL-SOURCES.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps({'resolved':sum(bool(r.get('notices'))for r in results),'remaining':[r['package']for r in results if not r.get('notices')]}))
