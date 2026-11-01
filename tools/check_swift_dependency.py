#!/usr/bin/env python3
"""Regression: resolve a tagged Git dependency, not merely a full source checkout."""
from pathlib import Path
import os,subprocess,tempfile
root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='qrk-swift-git-')as temporary:
    work=Path(temporary);bare=work/'QuranRecitationKit.git'
    subprocess.run(['git','clone','--bare','--no-local',str(root),str(bare)],check=True)
    subprocess.run(['git','--git-dir',str(bare),'tag','-f','0.0.1','HEAD'],check=True)
    consumer=work/'consumer';source=consumer/'Sources/Smoke';source.mkdir(parents=True)
    (consumer/'Package.swift').write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "SmokeConsumer", platforms: [.macOS(.v14)], dependencies: [
    .package(url: "'''+bare.as_uri()+'''", exact: "0.0.1")
], targets: [.executableTarget(name: "Smoke", dependencies: [.product(name: "QuranRecitationKit", package: "QuranRecitationKit")])])
''')
    (source/'main.swift').write_text('import QuranRecitationKit\nlet c = try QuranCatalog()\nprecondition(c.surahs.count == 114)\nprint("TAGGED SWIFTPM DEPENDENCY PASS")\n')
    env=dict(os.environ);env.setdefault('DEVELOPER_DIR','/Applications/Xcode.app/Contents/Developer')
    subprocess.run(['swift','build','--package-path',str(consumer),'--product','Smoke'],env=env,check=True)
    directory=subprocess.check_output(['swift','build','--package-path',str(consumer),'--show-bin-path'],env=env,text=True).strip()
    binary=Path(directory)/'Smoke'
    # macOS runners can retain stale launch-signature state after repeated SwiftPM links.
    # Sign only this generated test executable; never alter host security policy or release archives.
    subprocess.run(['/usr/bin/codesign','--force','--sign','-','--timestamp=none',str(binary)],check=True)
    subprocess.run(['/usr/bin/codesign','--verify','--strict',str(binary)],check=True)
    result=subprocess.run([str(binary)],env=env)
    if result.returncode:
        subprocess.run(['/usr/bin/codesign','-d','--verbose=4',str(binary)])
        subprocess.run(['/usr/bin/log','show','--last','2m','--style','compact','--predicate','eventMessage CONTAINS "Smoke"'],stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
        raise SystemExit(f'Tagged SwiftPM consumer exited with {result.returncode}')

