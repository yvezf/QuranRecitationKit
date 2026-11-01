#!/usr/bin/env python3
"""Stage native NuGet assets. --pack requires all promised desktop platforms."""
from pathlib import Path
import argparse, os, shutil, subprocess
ROOT=Path(__file__).resolve().parent.parent
p=argparse.ArgumentParser();p.add_argument('--rid',choices=['osx-arm64','osx-x64','win-x64','linux-x64']);p.add_argument('--native',type=Path);p.add_argument('--pack',action='store_true');p.add_argument('--dotnet',default='dotnet');a=p.parse_args()
names={'osx-arm64':'libqrk.dylib','osx-x64':'libqrk.dylib','win-x64':'qrk.dll','linux-x64':'libqrk.so'}
if a.rid:
    source=a.native or ROOT/'core/target/release'/names[a.rid]
    dest=ROOT/'bindings/dotnet/runtimes'/a.rid/'native'/names[a.rid];dest.parent.mkdir(parents=True,exist_ok=True)
    if dest.exists():dest.unlink()
    shutil.copy2(source,dest)
if a.pack:
    for rid,name in names.items():
        if not (ROOT/'bindings/dotnet/runtimes'/rid/'native'/name).exists():raise SystemExit(f'missing native runtime: {rid}; collect all four CI artifacts before packing')
    subprocess.run([a.dotnet,'pack',str(ROOT/'bindings/dotnet/QuranRecitationKit/QuranRecitationKit.csproj'),'-c','Release','-o',str(ROOT/'dist')],check=True)
