# Model card — `fastconformer_full_mixed.onnx`

| | |
|---|---|
| **Task** | Arabic speech → CTC log-probabilities over a 1,025-token text vocabulary, used by QuranRecitationKit to track expected Qur'an words |
| **Base model** | NVIDIA `stt_ar_fastconformer_hybrid_large_pcd_v1.0` (FastConformer hybrid RNNT/CTC, Arabic, ~115 M params) — CC BY 4.0 |
| **Shipped artifact** | ONNX, mixed int4/int8 quantized, audio preprocessing embedded, dual output |
| **File size** | 88,307,457 bytes |
| **SHA-256** | `822534428f1ed54eb802a9c43d4ecbabdfd8ba346b4d88d710414b0bbe7b4d69` |
| **Upstream single-output graph** | 88,307,366 bytes, SHA-256 `4767182cd92975869f81a7e32700b14ca2b04e8dc97a15ff220a8697f4639488` (Tilawa v0.2.0 release asset, produced by Cyberistic) |
| **Distribution** | [Published model-v1 release](https://github.com/yvezf/QuranRecitationKit/releases/tag/model-v1). Downloads are explicit and verified. A locally supplied model directory works immediately. |

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

NVIDIA NeMo checkpoint → Cyberistic ONNX export + quantization (distributed by Tilawa v0.2.0, MIT project) → dual-output graph (this project; no node changes). No training or fine-tuning on any recitation audio was performed by this project. Thresholds and window sizes are inherited heuristics. No calibration dataset, reciter audio or licensed recording is redistributed, and a calibration claim is not made.


## Cross-platform delivery status

The Rust core builds its normalized index in memory from verbatim Tanzil Arabic. Only a user-local cache contains that generated index. NVIDIA's tokenizer was converted from SentencePiece Unigram (not BPE) to Hugging Face tokenizer JSON; all 77,441 source words were compared against SentencePiece without mismatches. The optional local parity test additionally compares every numbered ayah's words, token IDs and word boundaries with the prior oracle. Visual line-wrap boundaries are not a canonical engine unit.

Release v1 is still the pinned model. The public repository and separate model-v1 release were published on 2026-11-01 after maintainer review. Cyberistic's custom preprocessing/export rights remain qualified in THIRD_PARTY_NOTICES.md; integrity verification alone is not a license grant. The clean NVIDIA/NeMo candidate was exported and quantized on 2026-11-01, but failed synthetic decision parity against v1. It was not promoted, and no model-v2 or v0.2.0 release was created. See the [export status and workflow evidence](model/export/STATUS-2026-11-01.md). Synthetic parity is a gate, not evidence of real-recitation accuracy.

CPU execution is the default. ONNX Runtime 1.24.2 is used locally; the Rust wrapper is ort 2.0.0-rc.12/API 24. Distribution helpers can embed the platform CPU runtime, materializing verified runtime bytes in a user-local cache. Windows Microsoft runtime prerequisites still apply to the chosen ONNX Runtime binary. Native CPU inference tests passed in CI on Windows, Linux and both Mac architectures. This is not a live-microphone accuracy benchmark.
