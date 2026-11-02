# Third-party notices

QuranRecitationKit's own source code is MIT-licensed (see `LICENSE`). It builds on the work below. Each item lists what we use, where it came from, its license, and what we changed. Keep this file with any redistribution.

## 1. Tilawa — architecture and tracking algorithms (MIT)

Portions of the engine are ported from or modeled on **Tilawa** by yazinsai — https://github.com/yazinsai/tilawa — specifically the Arabic normalizer (`normalizer.ts`), the greedy text-CTC decoder (`text-ctc-decode.ts`), the expected-word aligner (`tracker.ts`), the CTC rescoring approach (`ctc-rescore.ts`), and the overall recognition architecture.

Two Tilawa references are involved and are different things:
- **Source**: commit `ec5cdc72c1c48ba29866ca2e3197d6b9a0e2e793` (July 9, 2026), which carries Tilawa's MIT `LICENSE` and `packages/core/`.
- **Model assets**: GitHub release `v0.2.0` (June 30, 2026): `fastconformer_full_mixed.onnx`, `vocab.json`, `tokenizer.model` (see §2).

Tilawa later (v0.3.0+) adopted a Zipformer model and phoneme corpus licensed NPL-1.2 (non-commercial, share-alike). **QuranRecitationKit contains none of that material.** It uses only the FastConformer text-CTC path, which Tilawa distributes under MIT with the NVIDIA model under CC BY 4.0.

```
MIT License

Copyright (c) 2026 yazinsai

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## 2. NVIDIA acoustic weights, vocabulary and tokenizer

Base checkpoint: [NVIDIA stt_ar_fastconformer_hybrid_large_pcd_v1.0](https://huggingface.co/nvidia/stt_ar_fastconformer_hybrid_large_pcd_v1.0), licensed [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). NVIDIA also supplies the Unigram vocabulary and SentencePiece tokenizer. The tokenizer is data, not project-authored code.

### Default model-v2: direct NVIDIA export

The ONNX weights are a separate [model-v2 release asset](https://github.com/yvezf/QuranRecitationKit/releases/tag/model-v2), not committed here. The hash-pinned NVIDIA checkpoint in `model/export/source.json` is restored through [NeMo 2.4.0 (Apache-2.0)](https://github.com/NVIDIA/NeMo/blob/v2.4.0/LICENSE). Its existing featurizer runs with float64 accumulation, followed by the original float32 encoder/CTC decoder. PyTorch exports ONNX, then Microsoft's ONNX Runtime applies dynamic int8 convolution and symmetric int4 constant MatMul weights (block 128). Both CTC and encoder outputs are exposed. There is no new training or activation-calibration dataset. V2 does not use Cyberistic exporter/preprocessing source, its ONNX graph, or Tilawa model assets.

Build-time export tools retain their notices: NeMo and ONNX (Apache-2.0), PyTorch (BSD-style upstream notice), ONNXScript and ONNX Runtime (MIT). Complete upstream license texts are in `third-party/NEMO-LICENSE`, `PYTORCH-LICENSE`, `ONNX-LICENSE`, `ONNXSCRIPT-LICENSE` and `ONNXRUNTIME-LICENSE`; the separate model release includes `MODEL-NOTICES.txt`. NVIDIA's CC BY 4.0 model attribution and declared modifications apply to the converted weights.

### Previous model-v1: qualified historical export

[Model-v1](https://github.com/yvezf/QuranRecitationKit/releases/tag/model-v1) remains published for older SDKs. It is the mixed int4/int8 export from [Cyberistic/offline-quran-validation](https://github.com/Cyberistic/offline-quran-validation), distributed with Tilawa's v0.2.0 model release. Preprocessing is embedded in that graph. Exposing one existing encoder tensor by adding an output declaration changes no executable nodes or weights; removing the declaration reproduces the source graph hash.

Cyberistic's repository has no license file. Its exporter contains custom STFT/featurizer code; whether that expression survives in the compiled graph remains unresolved. NVIDIA's weight license does not grant rights to someone else's code, and attribution/integrity verification do not resolve that qualification. This historical warning is retained; the new v2 default was reproduced directly with licensed NVIDIA/NeMo tooling instead of importing that export.

No parties above endorse this project. Contracts and hashes are in [MODEL_CARD.md](MODEL_CARD.md).

## 3. Tanzil Arabic text

Source: [Tanzil Project](https://tanzil.net). License: [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/) together with [Tanzil's additional text conditions](https://tanzil.net/docs/text_license).

`corpus/quran-uthmani.json` preserves every source Arabic string and the full Tanzil notice; no translation is included. The Rust engine normalizes and tokenizes in memory at startup and may cache that index on the user's own machine. No generated normalized Quran index is committed or included in release assets. Host UIs must display verbatim text, indicate Tanzil as source, link to Tanzil and reproduce the notice. The Swift binding now calls the same Rust core and carries no generated matching resources. Its independent scorer/aligner copies exist only as development parity tests.

The full copyright/terms notice is in `corpus/TANZIL-NOTICE.txt` and the corpus attribution block. Numbered-verse projection separates optional unnumbered preambles by slicing the original text; it does not rewrite source Arabic strings. These are the technical distribution choices requested for the package; this document is not a separate permission grant from Tanzil.

## 4. ONNX Runtime

[Microsoft ONNX Runtime](https://github.com/microsoft/onnxruntime) and its [Swift package](https://github.com/microsoft/onnxruntime-swift-package-manager) are MIT-licensed. Apple builds use Microsoft’s 1.24.2 static framework archive, SHA-256 `f7100a992d2a8135168c8afd831e6a58b465349101982aa58b3e11d36e600b54`. Desktop bindings were tested with the official 1.24.2 CPU runtime; Rust uses ort 2.0.0-rc.12/API 24. The original Swift reference used Microsoft’s SwiftPM revision `b7fb7f7dea8a2469e6335d95a61b8f36d0dc83b2`. Dependency distributions retain Microsoft’s notices.

## 4a. Rust and native binding dependencies

Rust dependencies are pinned in core/Cargo.lock and the binding lockfiles. The implementation uses tokenizers (Apache-2.0), ort (MIT/Apache-2.0), cpal/rubato, serde, Tokio/tungstenite, napi-rs and their transitive dependencies under their respective licenses. Native release artifacts must carry the generated dependency notices, alongside `third-party/ONNXRUNTIME-LICENSE` and `third-party/ONNXRUNTIME-NOTICES.txt`. The Node transport dependency ws is MIT. PyO3 and transitive Rust notices are included in `third-party/RUST-DEPENDENCIES.txt` and supplements; Node ws and .NET dependencies have separate collected notice files. Rust’s standard-library copyright inventory is also retained. Supplemental notice URLs identify the resolved crate revisions. The collector reports zero unresolved Rust notice entries. Microsoft.NETCore.Platforms is a build-time runtime-identifier metadata package, not code copied into the SDK binary; its MIT attribution is recorded in the .NET inventory.

## 5. Build-time tooling and platform frameworks

The generator requires [SentencePiece 0.2.1](https://github.com/google/sentencepiece/tree/v0.2.1), Apache-2.0. It is installed separately, not vendored as executable code. Apple's Foundation, AVFoundation, CryptoKit and SDK tools are governed by their respective SDK terms.

## Exclusions and claims

No recitation recording, PCM, spectrogram, embedding, private rights manifest or Quran translation is included. The model is a general Arabic speech checkpoint; no new acoustic fine-tuning is claimed. The numerical completion thresholds are retained heuristics, not a calibrated Tajweed or zero-false-accept claim. There is no trained endpoint classifier in this repository.

For Intel macOS desktop distributions, ONNX Runtime 1.24.2 is linked into a C-API shared library from Microsoft’s checksum-pinned Apple static archive because its PyPI wheel is unavailable for that architecture. Runtime/model sources and weights are unchanged. Build provenance is included in native release archives.

Linux audio capture dynamically uses the host-provided [ALSA library](https://github.com/alsa-project/alsa-lib), LGPL-2.1-or-later. ALSA is not embedded in the release archives. The small MIT CLI probe shim uses its thread-local error-handler API and restores the prior handler after enumeration/setup; it does not redirect global stderr or replace system libraries.
