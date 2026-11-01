# Changelog

All notable changes to this project are documented here. The format follows Keep a Changelog; versions follow Semantic Versioning.

## [Unreleased]

### Added
- Cross-platform core in Rust (`core/`): engine, ONNX runner, microphone capture, C ABI, and the `qrk` CLI/sidecar (`model fetch`, `devices`, `wav`, `mic`, `serve`).
- `protocol/`: one JSON event schema and the sidecar protocol (stdio JSON lines, localhost WebSocket) with JS/Python/C# clients.
- Bindings: Swift (SwiftPM + XCFramework), Node (`@quranrecitationkit/node`), Python (`quranrecitationkit`), .NET (`QuranRecitationKit`).
- Runtime corpus index built from Tanzil's verbatim text at startup (no derived Qur'an index is distributed).
- Model release `model-v1` (NVIDIA FastConformer Arabic, CC BY 4.0; mixed int4/int8 ONNX; dual output) and the reproducible `model/export/` pipeline toward `model-v2`.
- Examples: node-mic, python-wav, dotnet-console, swift-ios, electron-plugin.

## [0.1.0] — 2026-11-01

Internal milestone: the recognizer extracted from Hablobi into a standalone Swift package (now `bindings/swift/`).

### Local implementation status
- Phase A committed separately; Phase B rebases Swift onto the shared C ABI and adds PyO3 abi3 and netstandard2.0 bindings.
- Apple XCFramework includes static ONNX Runtime; native archives, wheel notice staging and aggregate NuGet packaging are prepared.
- Model publication, remote CI, and Swift public archive checksum pinning remain publisher-review steps. No model-v1 asset is claimed uploaded.
