#!/usr/bin/env python3
"""Locate ORT 1.24.2; link Intel macOS from Microsoft's checksum-pinned static archive."""
from pathlib import Path
import hashlib,importlib.util,json,os,platform,shutil,subprocess
root=Path(__file__).resolve().parent.parent
work=root/'.planning/native-runtime';work.mkdir(parents=True,exist_ok=True)
provenance={'version':'1.24.2','provider':'CPU','publisher':'Microsoft'}
if platform.system()=='Darwin' and platform.machine()=='x86_64':
    os.environ.setdefault('DEVELOPER_DIR','/Applications/Xcode.app/Contents/Developer')
    url='https://download.onnxruntime.ai/pod-archive-onnxruntime-c-1.24.2.zip'
    archive=work/'onnxruntime-1.24.2.zip'
    if not archive.exists():subprocess.run(['curl','--fail','--location','--silent','--show-error',url,'--output',str(archive)],check=True)
    digest=hashlib.sha256(archive.read_bytes()).hexdigest()
    if digest!='f7100a992d2a8135168c8afd831e6a58b465349101982aa58b3e11d36e600b54':raise SystemExit('Microsoft Apple archive checksum mismatch')
    vendor=work/'vendor'
    if vendor.exists():shutil.rmtree(vendor)
    subprocess.run(['/usr/bin/ditto','-x','-k',str(archive),str(vendor)],check=True)
    source=next(vendor.rglob('onnxruntime.xcframework'))/'macos-arm64_x86_64/onnxruntime.framework/onnxruntime'
    static=work/'libonnxruntime.a'
    subprocess.run(['xcrun','lipo',str(source),'-thin','x86_64','-output',str(static)],check=True)
    runtime=work/'libonnxruntime.1.24.2.dylib'
    if runtime.exists():runtime.unlink()
    subprocess.run(['xcrun','clang++','-target','x86_64-apple-macos14.0','-dynamiclib',f'-Wl,-force_load,{static}','-Wl,-exported_symbol,_OrtGetApiBase','-Wl,-dead_strip','-framework','Foundation','-framework','CoreML','-framework','Accelerate','-lc++','-liconv','-o',str(runtime)],check=True)
    subprocess.run(['/usr/bin/codesign','--force','--sign','-','--timestamp=none',str(runtime)],check=True)
    provenance.update(source=url,source_sha256=digest,modification='Intel slice linked into a C-API shared library; no model or runtime source changes')
else:
    spec=importlib.util.find_spec('onnxruntime')
    if spec is None or spec.origin is None:raise SystemExit('Install official onnxruntime==1.24.2 first')
    folder=Path(spec.origin).parent/'capi'
    files=[p for p in folder.iterdir()if p.name.startswith('libonnxruntime.')and('.so'in p.name or p.suffix=='.dylib')or p.name=='onnxruntime.dll']
    runtime=sorted(files)[0]
    provenance.update(source='Official onnxruntime 1.24.2 wheel',modification='unmodified platform native runtime')
runtime=runtime.resolve();provenance['runtime_sha256']=hashlib.sha256(runtime.read_bytes()).hexdigest()
(work/'ONNXRUNTIME-PROVENANCE.json').write_text(json.dumps(provenance,indent=2)+'\n')
if os.environ.get('GITHUB_ENV'):
    with open(os.environ['GITHUB_ENV'],'a')as f:f.write(f'ORT_DYLIB_PATH={runtime}\nQRK_EMBED_RUNTIME={runtime}\n')
print(runtime)
