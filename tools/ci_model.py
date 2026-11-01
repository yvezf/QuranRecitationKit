#!/usr/bin/env python3
"""Exercise the public default downloader and enable real-model inference checks in CI."""
from pathlib import Path
import os,subprocess
root=Path(__file__).resolve().parent.parent
binary=root/'core/target/release'/('qrk.exe'if os.name=='nt'else'qrk')
r=subprocess.run([str(binary),'model','fetch'],capture_output=True,text=True)
if r.returncode:raise SystemExit(r.stderr[-4000:])
path=Path(r.stdout.strip().splitlines()[-1])
if not (path/'model-manifest.json').is_file():raise SystemExit('verified model manifest missing')
with open(os.environ['GITHUB_ENV'],'a')as f:f.write(f'QRK_MODEL_DIR={path}\n')
print('Public model-v1 downloaded and integrity-verified; native inference tests enabled.')
