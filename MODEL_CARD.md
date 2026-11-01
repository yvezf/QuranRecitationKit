# Model card — `fastconformer_full_mixed.onnx`

| | |
|---|---|
| **Task** | Arabic speech → CTC log-probabilities over a 1,025-token BPE vocabulary, used by QuranRecitationKit to track expected Qur'an words |
| **Base model** | NVIDIA `stt_ar_fastconformer_hybrid_large_pcd_v1.0` (FastConformer hybrid RNNT/CTC, Arabic, ~115 M params) — CC BY 4.0 |
| **Shipped artifact** | ONNX, mixed int4/int8 quantized, audio preprocessing embedded, dual output |
| **File size** | 88,307,457 bytes |
| **SHA-256** | `822534428f1ed54eb802a9c43d4ecbabdfd8ba346b4d88d710414b0bbe7b4d69` |
| **Upstream single-output graph** | 88,307,366 bytes, SHA-256 `4767182cd92975869f81a7e32700b14ca2b04e8dc97a15ff220a8697f4639488` (Tilawa v0.2.0 release asset, produced by Cyberistic) |
| **Distribution** | GitHub Release asset of this repository (`model-v1`), downloaded on first use by `ModelPack.download()` and verified against the hash above. Also usable from an app bundle / on-demand resource. |

## Inputs

| Name | Shape | Notes |
|---|---|---|
| `audio_signal` | `Float32[1, N]` | raw waveform, 16 kHz, mono, nominal range −1…1; the mel front-end is inside the graph |
| `length` | `Int64[1]` | `N` |

Maximum window used by the kit: 12 s (192,000 samples) for terminal recovery; 2 s live suffix for provisional tracking.

## Outputs

| Name | Shape | Notes |
|---|---|---|
| `log_probs` | `Float32[1, T, 1025]` | log-softmaxed CTC posteriors; blank id = 1024; T ≈ N / 1280 |
| `/encoder/layers.16/norm_out/LayerNormalization_output_0` | `Float32[1, T, 512]` | final encoder LayerNorm; same time axis as `log_probs`; used for endpoint features |

## Vocabulary

`vocab.json` — 1,025 SentencePiece BPE tokens (NVIDIA's). SHA-256 `c55877f3bff8bc3aaefc160e8c2fb88cb349088d092513d40210ccfe535e671b`. Generator-side tokenizer `tokenizer.model` SHA-256 `1fcfa104fa448c979cc2537788947c6516827f403ecdc55c4895b77d28630ba4`.

## How the kit uses it

The kit never asks the model "which verse is this?" It knows which words are expected (a surah, an ayah range, or a line) and scores the audio against that expectation with CTC forced alignment, advancing word by word. This makes it robust to the model's general-Arabic spelling (e.g. fused letters) because expected words carry pronunciation variants, and it makes wrong-verse and noise rejection a policy decision rather than a search problem.

## Limitations

- General Arabic ASR base; not fine-tuned on recitation. Tajweed is not assessed. Pronunciation cues are coarse (word began / did not match), never a verdict on correctness of recitation.
- Expects a reasonably quiet room and a phone-distance microphone. Heavy reverb or music lowers confidence; the kit then reports `needsRetry` rather than guessing.
- Performance was calibrated on murattal-style recitation. Very fast or heavily melodic (mujawwad) styles may need the lookahead/backtrack limits widened.
- On-device CPU inference. An iPhone 12-class device sustains live tracking; older devices should use the non-live (post-line) evaluation mode.

## Provenance chain

NVIDIA NeMo checkpoint → Cyberistic ONNX export + quantization (distributed by Tilawa v0.2.0, MIT project) → dual-output graph (this project; no node changes). No training or fine-tuning on any recitation audio was performed by this project. Thresholds and window sizes were calibrated privately against licensed recitations that are **not** redistributed.
