#!/usr/bin/env python3
"""Stage redistribution notices into the wheel source directory before maturin build."""
from pathlib import Path
import shutil
root=Path(__file__).resolve().parent.parent;target=root/'bindings/python/LICENSES';target.mkdir(exist_ok=True)
for name in ['LICENSE','THIRD_PARTY_NOTICES.md']:shutil.copy2(root/name,target/name)
shutil.copytree(root/'third-party',target/'third-party',dirs_exist_ok=True)
