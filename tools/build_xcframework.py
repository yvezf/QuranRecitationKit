#!/usr/bin/env python3
"""Build the shared C ABI for Apple; binaries stay ignored until release packaging."""
from pathlib import Path
import argparse, hashlib, os, plistlib, shutil, subprocess, zipfile
ROOT=Path(__file__).resolve().parent.parent
os.environ.setdefault('DEVELOPER_DIR','/Applications/Xcode.app/Contents/Developer')
p=argparse.ArgumentParser();p.add_argument('--onnx-framework',type=Path);a=p.parse_args()
work=ROOT/'.planning/apple';work.mkdir(parents=True,exist_ok=True)
framework=a.onnx_framework
if framework is None:
    local=ROOT/'bindings/swift/.build/artifacts/onnxruntime-swift-package-manager/onnxruntime/onnxruntime.xcframework'
    if local.exists():framework=local
    else:
        archive=work/'onnxruntime-1.24.2.zip'
        if not archive.exists():subprocess.run(['curl','--fail','--location','--output',str(archive),'https://download.onnxruntime.ai/pod-archive-onnxruntime-c-1.24.2.zip'],check=True)
        if hashlib.sha256(archive.read_bytes()).hexdigest()!='f7100a992d2a8135168c8afd831e6a58b465349101982aa58b3e11d36e600b54':raise RuntimeError('Microsoft runtime archive checksum mismatch')
        vendor=work/'vendor'
        if vendor.exists():shutil.rmtree(vendor)
        subprocess.run(['/usr/bin/ditto','-x','-k',str(archive),str(vendor)],check=True)
        framework=next((work/'vendor').rglob('onnxruntime.xcframework'))
slices=[('aarch64-apple-darwin','macos-arm64_x86_64','arm64'),('x86_64-apple-darwin','macos-arm64_x86_64','x86_64'),('aarch64-apple-ios','ios-arm64','arm64'),('aarch64-apple-ios-sim','ios-arm64_x86_64-simulator','arm64'),('x86_64-apple-ios','ios-arm64_x86_64-simulator','x86_64')]
for target,variant,arch in slices:
    location=work/target;location.mkdir(exist_ok=True)
    subprocess.run(['lipo',str(framework/variant/'onnxruntime.framework/onnxruntime'),'-thin',arch,'-output',str(location/'libonnxruntime.a')],check=True)
    env=dict(os.environ,ORT_LIB_LOCATION=str(location),DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',MACOSX_DEPLOYMENT_TARGET='14.0',IPHONEOS_DEPLOYMENT_TARGET='16.0')
    env.pop('QRK_EMBED_RUNTIME',None);env.pop('ORT_DYLIB_PATH',None)
    subprocess.run(['cargo','+stable','build','--manifest-path',str(ROOT/'core/Cargo.toml'),'-p','qrk-ffi','--no-default-features','--target',target,'--release','--locked'],env=env,check=True)
out=ROOT/'bindings/swift/Artifacts/QRKFFI.xcframework'
if out.exists():shutil.rmtree(out)
out.mkdir(parents=True);libraries=[]
for ident,platform,targets,archs,variant in [
    ('macos-arm64_x86_64','macos',['aarch64-apple-darwin','x86_64-apple-darwin'],['arm64','x86_64'],None),
    ('ios-arm64','ios',['aarch64-apple-ios'],['arm64'],None),
    ('ios-arm64_x86_64-simulator','ios',['aarch64-apple-ios-sim','x86_64-apple-ios'],['arm64','x86_64'],'simulator')]:
    folder=out/ident;headers=folder/'Headers';headers.mkdir(parents=True)
    lib=folder/'libqrk.a';inputs=[ROOT/'core/target'/t/'release/libqrk.a' for t in targets]
    if len(inputs)>1:subprocess.run(['lipo','-create',*map(str,inputs),'-output',str(lib)],check=True)
    else:shutil.copy2(inputs[0],lib)
    newest=max((ROOT/'core/target'/targets[0]/'release/build').glob('qrk-ffi-*/out/qrk.h'),key=lambda p:p.stat().st_mtime)
    shutil.copy2(newest,ROOT/'core/qrk-ffi/include/qrk.h');shutil.copy2(newest,headers/'qrk.h')
    (headers/'module.modulemap').write_text('module QRKFFI { header "qrk.h"\n export *\n}\n')
    d=dict(LibraryIdentifier=ident,LibraryPath='libqrk.a',HeadersPath='Headers',SupportedArchitectures=archs,SupportedPlatform=platform)
    if variant:d['SupportedPlatformVariant']=variant
    libraries.append(d)
with open(out/'Info.plist','wb')as f:plistlib.dump(dict(AvailableLibraries=libraries,CFBundlePackageType='XFWK',XCFrameworkFormatVersion='1.0'),f)
for name in ['LICENSE','THIRD_PARTY_NOTICES.md']:shutil.copy2(ROOT/name,out/name)
shutil.copytree(ROOT/'third-party',out/'third-party')
print(out)
