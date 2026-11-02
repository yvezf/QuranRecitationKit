#!/usr/bin/env python3
"""Hash-guarded export-only compatibility with patched Lightning.

Keep override validation enabled. Widen one adapter annotation, and make the
removed optional Neptune training logger explicitly unsupported for export.
No checkpoint/model method body is changed; no telemetry adapter is enabled.
The modified upstream files retain their NVIDIA Apache-2.0 copyright notices.
"""
from hashlib import sha256
from importlib.metadata import distribution
from pathlib import Path
import sys

ADAPTER_OLD = b"def save_checkpoint(self, filepath: Union[str, Path], weights_only: bool = False, storage_options: Optional[Any] = None) -> None:"
PATCHES = [
    ("nv-one-logger-pytorch-lightning-integration", "2.3.1",
     "nv_one_logger/training_telemetry/integration/pytorch_lightning.py",
     "70d04b515b014b030cefb7ccd494326543d13291ff36da29b60a4ed36c142069",
     "ff8fa1bbc8e317c4ebf573a48cb90b7bcd289ee7babc9d8430c7a506fcab0262",
     [(ADAPTER_OLD, ADAPTER_OLD.replace(b"weights_only: bool", b"weights_only: Optional[bool]"))]),
    ("nemo-toolkit", "3.0.0", "nemo/utils/exp_manager.py",
     "9664f4c1c99e58e3ff3df9c8f5753ef0995aa05ce9b6a0a0f277fdfa5e35022b",
     "894f7f4f12a92ab93b57ae292ac5ab0cfc135288d15fbc08ec88e7d61b50290a",
     [(b"from lightning.pytorch.loggers import MLFlowLogger, NeptuneLogger, TensorBoardLogger, WandbLogger",
       b"from lightning.pytorch.loggers import MLFlowLogger, TensorBoardLogger, WandbLogger"),
      (b"    if create_neptune_logger:\n",
       b'    if create_neptune_logger:\n        raise RuntimeError("Neptune training logging is not supported by this export-only environment")\n')]),
]


def prepare():
    if sys.prefix == sys.base_prefix:
        raise RuntimeError("Use an isolated export venv; never modify global Python")
    if distribution("lightning").version != "2.6.6":
        raise RuntimeError("Review export compatibility for the new Lightning version")
    changes = []
    for name, version, relative, before, after, replacements in PATCHES:
        package = distribution(name)
        if package.version != version:
            raise RuntimeError(f"Review export compatibility for the new {name} version")
        file = Path(package.locate_file(relative))
        original = file.read_bytes()
        digest = sha256(original).hexdigest()
        if digest == after:
            continue
        if digest != before:
            raise RuntimeError(f"Unexpected {name} source; refusing to patch it")
        changed = original
        for old, new in replacements:
            if changed.count(old) != 1:
                raise RuntimeError(f"Unexpected {name} source shape")
            changed = changed.replace(old, new)
        if sha256(changed).hexdigest() != after:
            raise RuntimeError("Export compatibility patch integrity failure")
        changes.append((file, changed))
    for file, changed in changes:
        file.write_bytes(changed)
    if changes:
        print("Applied reviewed export-only Lightning compatibility; override checks remain enabled")


if __name__ == "__main__":
    prepare()
