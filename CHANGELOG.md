# Changelog

## [0.2.0] — 2026-11-01

- Default model-v2: direct, hash-pinned NVIDIA/NeMo export with licensed preprocessing; no Cyberistic export in the default chain.
- Corrected compression: dynamic int8 convolution plus symmetric int4 constant MatMul; removed unrepresentative activation calibration and the rejected ARM-crashing static-int8 candidate.
- Fixed preprocessing precision past NeMo's implicit float32 cast. Source fidelity passes at the original tolerance.
- Published source/native/local validation receipts, retaining raw non-speech decoder differences and the original failures.
- Native model metadata now supplies versioned cache paths and manifests to Swift/.NET; package versions come from build metadata.
- Model-v1 remains available for older SDKs. No recognition-acceptance thresholds or target-text rules changed.

## [0.1.1] — 2026-11-01

- Fixed version-based SwiftPM manifest evaluation; reused the checksum-pinned v0.1.0 native archive.

## [0.1.0] — 2026-11-01

- Published the Rust core, C ABI, offline ONNX runner, mic/resampler, CLI and local WebSocket/stdio sidecar.
- Swift, Node, Python and .NET bindings, platform binaries, examples and model-v1 release.
- Verbatim Tanzil corpus with in-memory/local index generation; third-party notices and cross-platform CI.
- Registry publication remains separate; npm/PyPI/NuGet uploads have not been performed.
