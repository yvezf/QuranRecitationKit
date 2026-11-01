# Architecture

```
 mic / your audio ──► resample ──► 16 kHz mono f32 ──► qrk-onnx (FastConformer CTC) ──► log_probs [T × 1025]
                                                                                   └─► encoder features [T × 512]
 Target (surah / ayahs / words) ──► Corpus (verbatim Tanzil → runtime index) ──► CanonicalWordIndex ──► expected window
                                                                                                        │
                  log_probs + expected window ──► CtcScorer (forced alignment, per word) ──► ExpectedWordAligner
                                                                                                        │
                                              LineAcceptancePolicy (stability, margins, silence gate) ──► Events (JSON)
                                                                                                        │
                                           ┌──────────────┬──────────────┬──────────────┬───────────────┤
                                        qrk-ffi (C)    qrk-cli/serve   Node (napi)   Python (pyo3)   .NET (P/Invoke)
                                           └── Swift ──┘
```

**One engine.** `qrk-core` is pure Rust with no I/O: it takes PCM and returns events. `qrk-onnx` and `qrk-audio` are the only crates that touch hardware. Every binding and the sidecar call the same functions and emit the same JSON, defined once in `protocol/events.schema.json`.

**Why expected-text tracking.** Open-set verse identification needs a search over 6,236 ayahs on every window and is fragile on consumer hardware. Tracking inverts the problem: the host already knows what the reciter intends, so the engine asks the model "how well does this audio explain *these* words, in order?" via CTC forced alignment, and moves a cursor. Repeats, back-tracks and short skips are handled by a bounded window around the cursor; a reciter who is clearly somewhere else triggers `needs_retry(off_target)` rather than a wrong acceptance.

**Runtime corpus index.** Tanzil's text is shipped verbatim (that is what Tanzil permits). At startup the engine normalizes and tokenizes it with NVIDIA's SentencePiece tokenizer (via the `tokenizers` crate) into per-ayah word/token tables plus confuser indices, in well under a second, and caches the result in the user's app cache. Nothing derived from the text is distributed.

**Pronunciation variants.** The base model is general Arabic, so some Qur'anic spellings (fused ra, single-token "ahad", etc.) decode differently from the normalized text. `corpus/variants.json` carries the admitted variants per word; the aligner accepts any of them. This is where most of the accuracy over a naive transcript-diff comes from.

**Live vs terminal evaluation.** Live mode runs a cheap 2-second suffix pass on a latest-only mailbox so a UI can paint progress while the reciter speaks; the terminal pass (up to 12 s) decides acceptance. Both use the same scorer and the same policy, so what the user sees mid-line never disagrees with the final decision.

**Sidecar.** `qrk serve` wraps the engine in a localhost WebSocket (and `--stdio`): `start` JSON → binary PCM frames → JSON events → `stop` → `summary`. It exists so that software in any language, with no native build step, can integrate in an hour.
