# Phase A verification — 2026-11-01

Prepared locally on macOS arm64. No remote created, no push, no model uploaded, and no edits to the source application's checkout.

## Implemented

Rust workspace: pure core, ONNX facade, CPAL/rubato capture, generated C ABI, WAV/mic/helper CLI, localhost WebSocket and JSON-lines stdio. Native Node binding and Electron/mic examples. Shared JSON schema. Runtime corpus index and local cache. Verified model loader and gated downloader. CPU runtime embedding/extraction for a self-contained helper. Clean model-v2 export/quantization/parity candidate workflow, unexecuted and never auto-promoted.

The Swift extraction was committed as a WIP comparison milestone and moved under `bindings/swift/`; Phase B rebases it onto the C ABI. Its local matching resources are ignored and never distributed. The developer-only generator lives under `tests/dev/`.

## Verified locally

| Check | Result |
|---|---|
| `cargo test --workspace` | 23 tests passed, 0 failed; includes the real ONNX forward test when local model env is set |
| Runtime oracle parity | All 6,236 ayahs: same normalized words, token IDs and word-token boundaries |
| Tokenizer conversion | 77,441 source words, 14,657 unique forms, 0 SentencePiece/HF mismatches |
| Shared Swift/Rust fixtures | 3 tests passed; scorer/alignment agreement within 0.0001 |
| Node | 4 tests passed, including local-model smoke |
| C ABI | Handle creation/feed/stop/string-free/free smoke passed |
| WebSocket helper | Authenticated localhost start/audio/stop, correct noise reply and summary; pass |
| Rust lint/format/release build | Strict clippy and rustfmt checks; release workspace build passed |
| Windows target | `cargo xwin check --target x86_64-pc-windows-msvc --workspace` passed |
| Runtime index cold build | Local release selftest wall time 0.25 s (target <0.4 s on this machine) |
| Embedded runtime | Local release WAV runner worked without ORT_DYLIB_PATH |
| Microphone capture | 44,100 Hz mono; 15.19 s; 0 dropped chunks |
| Node microphone example | Executed successfully; 12.00 s; 0 dropped chunks |

The Windows cross-check used Rust LLVM tools and the SDK managed by cargo-xwin. This is compile validation, not execution on Windows. CI matrices are prepared but cannot be called green before the first authorized push. The retired `macos-13` runner is replaced with `macos-15-intel`; current labels are documented by https://github.com/actions/runner-images.

## Real recording comparison

A privately held recording contains **78:1**, not Fatiha 1:1. It remains outside this repository. Both recognizers matched the actual verse:

```text
Rust: verse_match surah=78 ayah=1 confidence=0.801431 duration_seconds=5.40
Rust: summary verses=1/1 duration=5.60 transcript=عم يتساءلون
Swift reference: verseMatch 78:1 confidence=0.819 duration=5.40
Swift reference: summary verses=1/1 duration=5.60 transcript=عم يتساءلون
```

Intermediate transcripts/progress timing and the confidence margin differ. The reference uses an asynchronous newest-window mailbox and the former confuser graph; Rust is synchronous at the feed boundary, scopes actual emitted spans and builds ayah-level confusers at runtime. No bit-for-bit live-stream equivalence or calibrated confidence claim is made.

The microphone playback test received Quran-like speech and provisional word support but ended **inconclusive**, with no verse acceptance. The capture path worked without overruns; this does not prove live recitation accuracy in that room. The Node microphone example received silence/noise and produced a noise retry. No match was fabricated or threshold loosened to force these tests green.

## Important differences and limits

- The NVIDIA tokenizer is **Unigram**, not the BPE assumed in the brief. Conversion preserves actual pieces/scores and was verified over every source word.
- Al-Fatiha 1:6's actual canonical prefix uses token 142; the former rule only admitted the 117 prototype. Both references now test the correct scoped variant.
- Public canonical units are ayahs/word ranges. Product-specific visual wrapping and its old serialized confuser graph are not part of oracle parity.
- The pure core is generic over an acoustic runner; `qrk-onnx::Recognizer` supplies the requested model-pack constructor. This keeps I/O out of the core and avoids a cyclic dependency.
- Microphone overrun/errors are explicit. Model-derived confidence is uncalibrated; no Tajweed verdict or false-accept-rate guarantee.
- The default model release owner is deliberately unconfigured until the publishing review. The model is not bundled in source or these commits.
- v1 custom preprocessing/export rights remain qualified in the notices. v2 candidate export is prepared but unexecuted; no clean-export or parity success is claimed.
- Optional CoreML/DirectML paths are present; CPU is the tested default. Actual Windows, Linux, Intel Mac and iOS runtime execution remain platform-CI/device verification.

## Publication boundary

No generated normalized corpus index, reciter recording/PCM/spectrogram/embedding, translation, private rights manifest, credentials, device IDs or personal paths are to be staged. Source scans and the staged file list are checked before the Phase A commit. Public binaries/models and remote CI are separate from these local test results.

Dependency notice collection is included. Three platform-only crate/version entries still need a supplemental upstream notice at this milestone (cesu8 and two r-efi versions); the binding/release packaging review continues in Phase B.
