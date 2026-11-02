# Python binding

Python 3.9+ abi3 wheel, powered by PyO3. Download the matching wheel from https://github.com/yvezf/QuranRecitationKit/releases/tag/v0.3.0 and install it with `python -m pip install /path/to/downloaded.whl`. No PyPI registry upload has been performed. Inference releases the GIL; each session serializes calls. Returned events/summary use the shared JSON schema. A synchronous `on_event` callback is optional. Do not re-enter a session from its callback.

```python
from quranrecitationkit import Recognizer
r = Recognizer('/path/to/model', on_event=print)
r.set_expected({'surah': 112})
events = r.feed([0.0] * 16000)  # replace silence with mono 16 kHz Float32 PCM
summary = r.stop()
r.reset()
```

Build: install Rust stable and maturin, run `python tools/package_python.py`, set `QRK_EMBED_RUNTIME` to an official ONNX Runtime 1.24-compatible library, then `maturin build --manifest-path bindings/python/Cargo.toml --release`. On macOS set `MACOSX_DEPLOYMENT_TARGET=14.0`. Install the resulting wheel and run `python -m unittest discover -s bindings/python/tests -v`. Set `QRK_MODEL_DIR` for the opt-in real-model test. No model is downloaded during tests. Source distributions need the complete repository because the native crates use local workspace paths; publish built wheels.

`model_fetch(cache_dir=None)` performs an explicit pinned download from the configured public model-v2 release. Native wheel builds can embed ONNX Runtime and extract verified bytes into a user-local cache; no Python inference service is used. The CLI is the easiest option for automatic WAV resampling; `examples/python-wav/` intentionally accepts only mono PCM16 16 kHz.

## Lecture quotations

The same native core now provides open-set spot mode and model-free transcript matching. See [the spotting guide](../../docs/SPOTTING.md) for the exact API, timestamp/word-range conventions, ambiguous candidates, reviewable transcript replacement and measured limits. Recognition is local; text-only results are always unverified.
