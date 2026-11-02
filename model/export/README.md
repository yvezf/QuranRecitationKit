# Clean NVIDIA model-v2 pipeline

The manually triggered [successful run](https://github.com/yvezf/QuranRecitationKit/actions/runs/41363708288) starts from the revision-, size- and SHA-pinned NVIDIA checkpoint in `source.json`. NeMo 2.4.0 provides the original featurizer and neural model. The frontend accumulates in float64 through `get_features`; encoder/decoder and public inputs/outputs remain float32. ONNX Runtime applies dynamic int8 convolution and symmetric int4 constant MatMul (block 128), without activation-calibration audio or tones. No Cyberistic exporter/code/graph is imported.

Run `python export_clean.py --out <directory>` in the pinned environment from `requirements.txt`; the workflow records matching CPU PyTorch wheels and resolved dependencies. Source fidelity must pass before compression. The native `validate_model` example checks public acceptance/retry decisions on four desktop platforms and the optional local owned recording. No recording is a hosted workflow input.

`check_parity.py` separately records raw greedy CTC tone strings. Strict mode reports mismatches; `--report-only` records that diagnostic without confusing hallucinated tone text with accepted verses. It never authorizes release. Read [VALIDATION.md](VALIDATION.md) and the [full correction/status receipt](STATUS-2026-11-01.md).

The verified model is published separately as [model-v2](https://github.com/yvezf/QuranRecitationKit/releases/tag/model-v2), default in SDK v0.2.0. The exporter never publishes or changes a default automatically. Releasing requires deliberate hash/manifest updates, native checks, local recording verification and SDK packaging.
