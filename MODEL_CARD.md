# Model card — `fastconformer_full_mixed.onnx`

| | |
|---|---|
| **Task** | Arabic speech → CTC log-probabilities over a 1,025-token text vocabulary, used by QuranRecitationKit to track expected Qur'an words |
| **Base model** | NVIDIA `stt_ar_fastconformer_hybrid_large_pcd_v1.0` (FastConformer hybrid RNNT/CTC, Arabic, ~115 M params) — CC BY 4.0 |
| **Shipped artifact** | ONNX, mixed int4/int8 quantized, audio preprocessing embedded, dual output |
| **File size** | 88,880,384 bytes |
| **SHA-256** | `8771deacfa0d7cacc0116d5c4a27222dcfcf52a96e555a7e9d26ab265c7c8f09` |
| **Source checkpoint** | NVIDIA revision `7f32349d952f42a28dce979ba73270aa2bbdfa89`; SHA-256 `d29d19d7c054a5fc010ac6815e9cbb0dd1b21a30e0a7f7f2982e1fecaf0c3e31` |
| **Distribution** | [Model-v2 release](https://github.com/yvezf/QuranRecitationKit/releases/tag/model-v2). Downloads are explicit and verified. A locally supplied model directory works immediately. |

## Inputs

| Name | Shape | Notes |
|---|---|---|
| `audio_signal` | `Float32[1, N]` | raw waveform, 16 kHz, mono, nominal range −1…1; the mel front-end is inside the graph |
| `length` | `Int64[1]` | `N` |

Retained PCM is bounded by configuration (2–12 s, maximum 192,000 samples). The Rust recognizer evaluates buffered windows at feed boundaries and scopes scoring to decoder-supported spans. There is no separate two-second asynchronous inference mailbox in the new core.

## Outputs

| Name | Shape | Notes |
|---|---|---|
| `log_probs` | `Float32[1, T, 1025]` | log-softmaxed CTC posteriors; blank id = 1024; T ≈ N / 1280 |
| `/encoder/layers.16/norm_out/LayerNormalization_output_0` | `Float32[1, T, 512]` | final encoder LayerNorm; same time axis as `log_probs`; exposed by the model but not requested by the current Rust runner |

## Vocabulary

`vocab.json` — 1,025 CTC entries (1,024 SentencePiece Unigram pieces plus blank) (NVIDIA's). SHA-256 `c55877f3bff8bc3aaefc160e8c2fb88cb349088d092513d40210ccfe535e671b`. Generator-side tokenizer `tokenizer.model` SHA-256 `1fcfa104fa448c979cc2537788947c6516827f403ecdc55c4895b77d28630ba4`.

## How the kit uses it

The kit never asks the model "which verse is this?" It knows which words are expected (a surah, an ayah range, or a half-open word range) and scores the audio against that expectation with CTC forced alignment, advancing word by word. This makes it robust to the model's general-Arabic spelling (e.g. fused letters) because expected words carry pronunciation variants, and it makes wrong-verse and noise rejection a policy decision rather than a search problem.

## Limitations

- General Arabic ASR base; not fine-tuned on recitation. Tajweed is not assessed. Pronunciation cues are coarse (word began / did not match), never a verdict on correctness of recitation.
- Expects a reasonably quiet room and a phone-distance microphone. Heavy reverb or music lowers confidence; the kit then reports `needsRetry` rather than guessing.
- Acceptance uses retained heuristic thresholds; no calibrated accuracy, false-accept rate or recitation-style benchmark is supplied. Very fast or heavily melodic recitation may produce retries.
- CPU inference is tested locally on an Apple-silicon Mac. The iOS example builds; live runtime performance on specific iPhones has not been measured for this Rust extraction.

## Provenance chain

NVIDIA's revision- and hash-pinned checkpoint → NVIDIA NeMo 2.4.0 featurizer and encoder/CTC decoder → ONNX export → Microsoft ONNX Runtime dynamic int8 convolution and symmetric int4 constant MatMul (block 128). Log-mel accumulation uses float64; neural layers and public inputs/outputs remain float32. No Cyberistic exporter, preprocessing source or graph is used in v2. No acoustic training, fine-tuning or activation-calibration recordings were used.

NeMo's outer preprocessor coerces input back to float32. The export calls its existing `get_features` method to preserve the declared accumulation precision. The actual restored NeMo reference and ONNX export agree on all 16 source fixtures with maximum log-probability error 0.000187874, below the fixed 0.005 limit. Encoder error is at most 0.000004806. Quantization is independently tested through the native recognizer.

[Model-v1](https://github.com/yvezf/QuranRecitationKit/releases/tag/model-v1) remains available as the previous model: 88,307,457 bytes, SHA-256 `822534428f1ed54eb802a9c43d4ecbabdfd8ba346b4d88d710414b0bbe7b4d69`. Its Cyberistic export qualification remains in THIRD_PARTY_NOTICES; it is not part of v2's export chain. Older SDK versions retain their original model/cache pins.

## Cross-platform delivery status

The Rust core builds its normalized index in memory from verbatim Tanzil Arabic. Only a user-local cache contains that generated index. NVIDIA's tokenizer was converted from SentencePiece Unigram (not BPE) to Hugging Face tokenizer JSON; all 77,441 source words were compared against SentencePiece without mismatches. The optional local parity test additionally compares every numbered ayah's words, token IDs and word boundaries with the prior oracle. Visual line-wrap boundaries are not a canonical engine unit.

Model-v2 is the default starting with SDK v0.2.0. The [validation report](https://github.com/yvezf/QuranRecitationKit/releases/download/model-v2/validation-report.json) records 15/15 public rejection/retry cases on each of Windows, Linux, Apple Silicon Mac and Intel Mac, plus 14/14 local owned-recording cases (78:1 at three gains/three chunk sizes, wrong targets and truncation). No private recording was uploaded. This limited suite is not a population accuracy benchmark.

Raw greedy CTC token sequences on non-speech tones match v1 in 6/12 cases; this is retained as a decoder diagnostic, not relabeled as 12/12. All 15 public non-speech cases reject on all four platforms. Two tone retry subtypes differ (`noise` versus `off_target`), while the rejection decision agrees. No acceptance thresholds changed. See the [method and failure history](model/export/STATUS-2026-11-01.md).

CPU execution is the default. ONNX Runtime 1.24.2 is used locally; the Rust wrapper is ort 2.0.0-rc.12/API 24. Distribution helpers can embed the platform CPU runtime, materializing verified runtime bytes in a user-local cache. Windows Microsoft runtime prerequisites still apply to the chosen ONNX Runtime binary. Native CPU inference tests passed in CI on Windows, Linux and both Mac architectures. This is not a live-microphone accuracy benchmark.
