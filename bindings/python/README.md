# Python binding

Python 3.9+ abi3 wheel, powered by PyO3. Inference releases the GIL; each session serializes calls. Returned events/summary use the shared JSON schema. A synchronous `on_event` callback is optional. Do not re-enter a session from its callback.

```python
from quranrecitationkit import Recognizer
r = Recognizer('/path/to/model', on_event=print)
r.set_expected({'surah': 112})
events = r.feed([0.0] * 16000)  # replace silence with mono 16 kHz Float32 PCM
summary = r.stop()
r.reset()
```

Build: install Rust stable and maturin, run `python tools/package_python.py`, set `QRK_EMBED_RUNTIME` to an official ONNX Runtime 1.24-compatible library, then `maturin build --manifest-path bindings/python/Cargo.toml --release`. On macOS set `MACOSX_DEPLOYMENT_TARGET=14.0`. Install the resulting wheel and run `python -m unittest discover -s bindings/python/tests -v`. Set `QRK_MODEL_DIR` for the opt-in real-model test. No model is downloaded during tests. Source distributions need the complete repository because the native crates use local workspace paths; publish built wheels.

`model_fetch(cache_dir=None)` performs an explicit pinned download after the release owner is configured. Native wheel builds can embed ONNX Runtime and extract verified bytes into a user-local cache; no Python inference service is used. The CLI is the easiest option for automatic WAV resampling; `examples/python-wav/` intentionally accepts only mono PCM16 16 kHz.
