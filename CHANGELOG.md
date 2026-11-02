# Changelog

## 0.3.0

- Add independent open-set quotation sessions for lecture/note-taking apps: runtime retrieval, scoped CTC verification, timed verbatim Tanzil spans, explicit ambiguity and overlapping-window merge/debounce.
- Add model-free text candidates, always unverified, in Rust/C, CLI/sidecar, Swift, Node, Python and .NET; include lecture/notes integration examples.
- Preserve tracking behavior and the existing Swift tracking-event enum. Spotting uses the same pinned model-v2; no new weights or recording data ship in the SDK.
- Validate runtime display/shingle caches against the corpus and publish frame/time, ambiguity, pronunciation, synthetic-stream and private owned-clip gates. Classroom precision/recall remains unmeasured.
- Stage ABI-changing release artifacts before publishing a version tag; verify the exact public Swift archive after pinning.


## [0.2.1] — 2026-11-01

- Fixed continuous multi-ayah recognition: anchored positional alignment, real fresh-observation evidence, ayah-boundary confirmation, bounded backtrack and ordered per-ayah terminal scoring. A completed earlier ayah survives continuing speech.
- Added a timeline-driven two-ayah CTC logit fixture, long rolling-window, repeated-phrase, stop-only and wrong-target regressions, plus a local owned-recording gate.
- Added CLI help text, bounded non-TTY download progress, real raw-transcript confidence, shared mean downmix and clear non-zero no-input-device errors. Match confidence now maps its uncalibrated margin smoothly instead of clipping at 1.
- Added Linux aarch64 CI and an isolated no-input ALSA CLI check. No speech-identity threshold reduction or model changes.
- Documented macOS quarantine and notarization status; Developer-ID signing remains a credential-dependent follow-up.

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
