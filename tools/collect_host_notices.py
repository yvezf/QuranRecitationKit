#!/usr/bin/env python3
"""Collect installed Node/.NET package notices without retaining local cache paths."""
from pathlib import Path
import json
root=Path(__file__).resolve().parent.parent
sections=[]
ws=root/'bindings/node/node_modules/ws'
if ws.exists():
    package=json.loads((ws/'package.json').read_text())
    sections.append(f"ws {package['version']} — https://github.com/websockets/ws\n"+(ws/'LICENSE').read_text())
(root/'third-party/NODE-DEPENDENCIES.txt').write_text('\n'.join(sections)+'\n')
assets=root/'bindings/dotnet/QuranRecitationKit/obj/project.assets.json'
if assets.exists():
    d=json.loads(assets.read_text());package_roots=list(d['packageFolders']);sections=[];missing=[]
    for key,p in d['libraries'].items():
        if p['type']!='package':continue
        package=next((Path(r)/p['path'] for r in package_roots if (Path(r)/p['path']).exists()),None)
        files=[]if package is None else [f for f in package.iterdir()if f.is_file()and f.name.upper().startswith(('LICENSE','THIRD-PARTY-NOTICE','NOTICE','COPYRIGHT'))]
        sections.append('\n'+'='*72+'\n'+key+'\n')
        if not files:
            if key.startswith('Microsoft.NETCore.Platforms/'):
                sections.append('Build-time runtime identifier metadata, not compiled implementation. MIT. Copyright (c) Microsoft Corporation. The Microsoft MIT permission notice is reproduced with the other .NET package notices in this file. Source: https://github.com/dotnet/corefx\n')
            else:missing.append(key)
        for f in sorted(files):sections.append('\n--- '+f.name+' ---\n'+f.read_text())
    (root/'third-party/DOTNET-DEPENDENCIES.txt').write_text('\n'.join(sections))
    print(json.dumps({'nuget_packages_without_notice':missing}))
